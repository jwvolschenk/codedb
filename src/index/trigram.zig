// Trigram search indexes (in-memory, mmap, and the any-variant union).
// Posting structures live in trigram_posting.zig; regex decomposition in
// regex_query.zig. Re-exported here so callers use a single trigram module.
const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../cio.zig");
const normalizeChar = @import("chars.zig").normalizeChar;

const tg_posting = @import("trigram_posting.zig");
pub const Trigram = tg_posting.Trigram;
pub const packTrigram = tg_posting.packTrigram;
pub const PostingMask = tg_posting.PostingMask;
pub const DocPosting = tg_posting.DocPosting;
pub const PostingList = tg_posting.PostingList;

const regex_query = @import("regex_query.zig");
pub const RegexQuery = regex_query.RegexQuery;
pub const decomposeRegex = regex_query.decomposeRegex;

pub const TrigramIndex = struct {
    /// trigram → posting list with doc IDs
    index: std.AutoHashMap(Trigram, PostingList),
    /// path → list of trigrams contributed (for cleanup)
    file_trigrams: std.StringHashMap(std.ArrayList(Trigram)),
    /// path → doc_id mapping
    path_to_id: std.StringHashMap(u32),
    /// doc_id → path mapping (may contain "" sentinels for freed slots)
    id_to_path: std.ArrayList([]const u8),
    /// freed doc_id slots available for reuse by getOrCreateDocId
    free_ids: std.ArrayList(u32),
    allocator: std.mem.Allocator,
    /// When true, deinit frees the path keys in file_trigrams (set by readFromDisk).
    owns_paths: bool = false,

    /// Maximum entries per posting list — caps memory for common trigrams.
    /// Trigrams appearing in more files than this are poor discriminators anyway.
    const MAX_POSTINGS: usize = 512;

    pub fn init(allocator: std.mem.Allocator) TrigramIndex {
        return .{
            .index = std.AutoHashMap(Trigram, PostingList).init(allocator),
            .file_trigrams = std.StringHashMap(std.ArrayList(Trigram)).init(allocator),
            .path_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_path = .empty,
            .free_ids = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TrigramIndex) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.index.deinit();

        var ft_iter = self.file_trigrams.iterator();
        while (ft_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_trigrams.deinit();

        // When owns_paths=true, paths were dup'd in getOrCreateDocId and stored
        // in id_to_path. Free them here from id_to_path (not file_trigrams),
        // because lean code paths like insertBulkNew never populate file_trigrams,
        // and removeFile clears file_trigrams entries before deinit can see them.
        // id_to_path is the single source of truth for owned path memory.
        // Tombstone slots (empty strings from removeFile) are skipped.
        if (self.owns_paths) {
            for (self.id_to_path.items) |p| {
                if (p.len > 0) self.allocator.free(p);
            }
        }

        self.path_to_id.deinit();
        self.id_to_path.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
    }

    fn getOrCreateDocId(self: *TrigramIndex, path: []const u8) !u32 {
        if (self.path_to_id.get(path)) |id| return id;
        // owns_paths=true stores a dup so callers can free their source memory.
        const stored_path: []const u8 = if (self.owns_paths)
            try self.allocator.dupe(u8, path)
        else
            path;
        errdefer if (self.owns_paths) self.allocator.free(stored_path);
        const id: u32 = if (self.free_ids.items.len > 0) blk: {
            const freed: u32 = self.free_ids.pop() orelse unreachable;
            self.id_to_path.items[@as(usize, freed)] = stored_path;
            break :blk freed;
        } else blk: {
            const new_id: u32 = @intCast(self.id_to_path.items.len);
            try self.id_to_path.append(self.allocator, stored_path);
            break :blk new_id;
        };
        try self.path_to_id.put(stored_path, id);
        return id;
    }

    pub fn removeFile(self: *TrigramIndex, path: []const u8) void {
        const doc_id = self.path_to_id.get(path) orelse {
            const trigrams = self.file_trigrams.getPtr(path) orelse return;
            trigrams.deinit(self.allocator);
            _ = self.file_trigrams.remove(path);
            return;
        };
        // Always clean path_to_id first, regardless of whether file_trigrams has an entry.
        _ = self.path_to_id.remove(path);
        // Free the doc_id slot for reuse on next indexFile call.
        self.free_ids.append(self.allocator, doc_id) catch {};
        if (self.file_trigrams.getPtr(path)) |trigrams| {
            for (trigrams.items) |tri| {
                if (self.index.getPtr(tri)) |posting_list| {
                    posting_list.removeDocId(doc_id);
                    if (posting_list.items.items.len == 0) {
                        posting_list.deinit(self.allocator);
                        _ = self.index.remove(tri);
                    }
                }
            }
            trigrams.deinit(self.allocator);
            _ = self.file_trigrams.remove(path);
        }
        const old_path = self.id_to_path.items[doc_id];
        if (self.owns_paths and old_path.len > 0) self.allocator.free(old_path);
        self.id_to_path.items[doc_id] = "";
    }

    pub fn indexFile(self: *TrigramIndex, path: []const u8, content: []const u8) !void {
        const id_count_before = self.id_to_path.items.len;
        self.removeFile(path);

        const doc_id = try self.getOrCreateDocId(path);
        // If id_to_path grew, this is a brand-new file (doc_id == max), so append
        // maintains sorted PostingList order.  If it did not grow, a freed slot was
        // reused and we must use sorted insert to preserve the invariant.
        const is_new_doc = self.id_to_path.items.len > id_count_before;

        // Phase 1: accumulate masks locally per trigram (no global index writes)
        var local = std.AutoHashMap(Trigram, PostingMask).init(self.allocator);
        defer local.deinit();
        // Pre-size: a file typically has ~content.len/4 unique trigrams
        const estimated_unique = @max(@as(u32, 64), @as(u32, @intCast(@min(content.len / 4, 65536))));
        local.ensureTotalCapacity(estimated_unique) catch {};

        if (content.len >= 3) {
            for (0..content.len - 2) |i| {
                // Skip trigrams that are pure whitespace (terrible filters, ~12% of all occurrences)
                const c0 = content[i];
                const c1 = content[i + 1];
                const c2 = content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;

                const tri = packTrigram(
                    normalizeChar(c0),
                    normalizeChar(c1),
                    normalizeChar(c2),
                );
                const gop = try local.getOrPut(tri);
                if (!gop.found_existing) {
                    gop.value_ptr.* = PostingMask{};
                }
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(normalizeChar(content[i + 3]) % 8);
                }
            }
        }

        // Phase 2: bulk-insert one posting per trigram into global index
        var tri_list: std.ArrayList(Trigram) = .empty;
        errdefer tri_list.deinit(self.allocator);

        var local_iter = local.iterator();
        while (local_iter.next()) |entry| {
            const tri = entry.key_ptr.*;
            const mask = entry.value_ptr.*;

            const idx_gop = try self.index.getOrPut(tri);
            if (!idx_gop.found_existing) {
                idx_gop.value_ptr.* = .{ .path_to_id = &self.path_to_id };
            }
            if (is_new_doc) {
                // New doc_id is always max: append maintains sorted PostingList order.
                try idx_gop.value_ptr.items.append(self.allocator, .{
                    .doc_id = doc_id,
                    .next_mask = mask.next_mask,
                    .loc_mask = mask.loc_mask,
                });
            } else {
                // Reused doc_id: sorted insert to maintain PostingList binary-search invariant.
                const posting = try idx_gop.value_ptr.getOrAddPosting(self.allocator, doc_id);
                posting.next_mask = mask.next_mask;
                posting.loc_mask = mask.loc_mask;
            }

            try tri_list.append(self.allocator, tri);
        }
        const stable_path = self.id_to_path.items[doc_id];
        try self.file_trigrams.put(stable_path, tri_list);
    }

    /// Like indexFile but reuses a caller-provided local HashMap to avoid alloc/free per file.
    pub fn indexFileReuse(self: *TrigramIndex, path: []const u8, content: []const u8, local: *std.AutoHashMap(Trigram, PostingMask)) !void {
        const id_count_before = self.id_to_path.items.len;
        self.removeFile(path);
        const doc_id = try self.getOrCreateDocId(path);
        const is_new_doc = self.id_to_path.items.len > id_count_before;

        // Phase 1: accumulate masks in reusable local map
        local.clearRetainingCapacity();
        if (content.len >= 3) {
            for (0..content.len - 2) |i| {
                const c0 = content[i];
                const c1 = content[i + 1];
                const c2 = content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = packTrigram(normalizeChar(c0), normalizeChar(c1), normalizeChar(c2));
                const gop = try local.getOrPut(tri);
                if (!gop.found_existing) gop.value_ptr.* = PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(normalizeChar(content[i + 3]) % 8);
                }
            }
        }

        // Phase 2: bulk-insert
        var tri_list: std.ArrayList(Trigram) = .empty;
        errdefer tri_list.deinit(self.allocator);
        var local_iter = local.iterator();
        while (local_iter.next()) |entry| {
            const tri = entry.key_ptr.*;
            const mask = entry.value_ptr.*;
            const idx_gop = try self.index.getOrPut(tri);
            if (!idx_gop.found_existing) {
                idx_gop.value_ptr.* = .{ .path_to_id = &self.path_to_id };
            }
            if (is_new_doc) {
                try idx_gop.value_ptr.items.append(self.allocator, .{
                    .doc_id = doc_id,
                    .next_mask = mask.next_mask,
                    .loc_mask = mask.loc_mask,
                });
            } else {
                const posting = try idx_gop.value_ptr.getOrAddPosting(self.allocator, doc_id);
                posting.next_mask = mask.next_mask;
                posting.loc_mask = mask.loc_mask;
            }
            try tri_list.append(self.allocator, tri);
        }
        try self.file_trigrams.put(path, tri_list);
    }

    /// Extract trigrams from content — thread-safe, no shared state.
    pub fn extractTrigrams(content: []const u8, alloc: std.mem.Allocator) std.AutoHashMap(Trigram, PostingMask) {
        var local = std.AutoHashMap(Trigram, PostingMask).init(alloc);
        const estimated = @max(@as(u32, 64), @as(u32, @intCast(@min(content.len / 4, 65536))));
        local.ensureTotalCapacity(estimated) catch {};
        if (content.len >= 3) {
            for (0..content.len - 2) |i| {
                const c0 = content[i];
                const c1 = content[i + 1];
                const c2 = content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = packTrigram(normalizeChar(c0), normalizeChar(c1), normalizeChar(c2));
                const gop = local.getOrPut(tri) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(normalizeChar(content[i + 3]) % 8);
                }
            }
        }
        return local;
    }

    /// Insert pre-extracted trigrams. NOT thread-safe.
    pub fn insertExtracted(self: *TrigramIndex, path: []const u8, local: *std.AutoHashMap(Trigram, PostingMask)) !void {
        self.removeFile(path);
        const doc_id = try self.getOrCreateDocId(path);
        var tri_list: std.ArrayList(Trigram) = .empty;
        errdefer tri_list.deinit(self.allocator);
        var iter = local.iterator();
        while (iter.next()) |entry| {
            const tri = entry.key_ptr.*;
            const mask = entry.value_ptr.*;
            const idx_gop = try self.index.getOrPut(tri);
            if (!idx_gop.found_existing) {
                idx_gop.value_ptr.* = .{ .path_to_id = &self.path_to_id };
            }
            try idx_gop.value_ptr.items.append(self.allocator, .{
                .doc_id = doc_id,
                .next_mask = mask.next_mask,
                .loc_mask = mask.loc_mask,
            });
            try tri_list.append(self.allocator, tri);
        }
        try self.file_trigrams.put(path, tri_list);
    }

    pub const BulkEntry = struct { tri: Trigram, mask: PostingMask };

    /// Lean bulk insert for cold builds: no removeFile, no file_trigrams tracking.
    /// Assumes doc_id is always new (strictly increasing), so uses simple append.
    pub fn insertBulkNew(self: *TrigramIndex, path: []const u8, trigrams: []const BulkEntry) !void {
        const doc_id = try self.getOrCreateDocId(path);
        for (trigrams) |te| {
            const idx_gop = try self.index.getOrPut(te.tri);
            if (!idx_gop.found_existing) {
                idx_gop.value_ptr.* = .{ .path_to_id = &self.path_to_id };
            }
            try idx_gop.value_ptr.items.append(self.allocator, .{
                .doc_id = doc_id,
                .next_mask = te.mask.next_mask,
                .loc_mask = te.mask.loc_mask,
            });
        }
    }

    /// Find candidate files that contain ALL trigrams from the query.
    pub fn candidates(self: *TrigramIndex, query: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (query.len < 3) return null;

        const tri_count = query.len - 2;

        var unique = std.AutoHashMap(Trigram, void).init(allocator);
        defer unique.deinit();
        unique.ensureTotalCapacity(@intCast(tri_count)) catch return null;
        for (0..tri_count) |i| {
            const tri = packTrigram(
                normalizeChar(query[i]),
                normalizeChar(query[i + 1]),
                normalizeChar(query[i + 2]),
            );
            _ = unique.getOrPut(tri) catch return null;
        }

        var sets: std.ArrayList(*PostingList) = .empty;
        defer sets.deinit(allocator);
        sets.ensureTotalCapacity(allocator, unique.count()) catch return null;

        var tri_iter = unique.keyIterator();
        while (tri_iter.next()) |tri_ptr| {
            const posting_list = self.index.getPtr(tri_ptr.*) orelse {
                return allocator.alloc([]const u8, 0) catch null;
            };
            sets.appendAssumeCapacity(posting_list);
        }

        if (sets.items.len == 0) {
            return allocator.alloc([]const u8, 0) catch null;
        }

        // Sort posting lists by size (smallest first) for efficient intersection
        std.mem.sort(*PostingList, sets.items, {}, struct {
            fn lt(_: void, a: *PostingList, b: *PostingList) bool {
                return a.items.items.len < b.items.items.len;
            }
        }.lt);

        // Sorted merge intersection: start with smallest list's doc_ids
        var result_ids: std.ArrayList(u32) = .empty;
        defer result_ids.deinit(allocator);

        // Seed with doc_ids from smallest posting list
        result_ids.ensureTotalCapacity(allocator, sets.items[0].items.items.len) catch return null;
        for (sets.items[0].items.items) |p| {
            result_ids.appendAssumeCapacity(p.doc_id);
        }

        // Intersect with each subsequent list (both sorted → merge O(n+m))
        for (sets.items[1..]) |set| {
            var write: usize = 0;
            var si: usize = 0;
            const set_items = set.items.items;
            for (result_ids.items) |id| {
                // Advance set pointer to >= id
                while (si < set_items.len and set_items[si].doc_id < id) : (si += 1) {}
                if (si < set_items.len and set_items[si].doc_id == id) {
                    result_ids.items[write] = id;
                    write += 1;
                    si += 1;
                }
            }
            result_ids.items.len = write;
            if (write == 0) break; // early exit if intersection is empty
        }

        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        result.ensureTotalCapacity(allocator, result_ids.items.len) catch return null;

        next_cand: for (result_ids.items) |doc_id| {
            // Bloom-filter check for consecutive trigram pairs
            if (tri_count >= 2) {
                for (0..tri_count - 1) |j| {
                    const tri_a = packTrigram(
                        normalizeChar(query[j]),
                        normalizeChar(query[j + 1]),
                        normalizeChar(query[j + 2]),
                    );
                    const tri_b = packTrigram(
                        normalizeChar(query[j + 1]),
                        normalizeChar(query[j + 2]),
                        normalizeChar(query[j + 3]),
                    );
                    const list_a = self.index.getPtr(tri_a) orelse continue;
                    const list_b = self.index.getPtr(tri_b) orelse continue;
                    const mask_a = list_a.getByDocId(doc_id) orelse continue;
                    const mask_b = list_b.getByDocId(doc_id) orelse continue;

                    const next_bit: u8 = @as(u8, 1) << @intCast(normalizeChar(query[j + 3]) % 8);
                    if ((mask_a.next_mask & next_bit) == 0) continue :next_cand;

                    const rotated = (mask_a.loc_mask << 1) | (mask_a.loc_mask >> 7);
                    if ((rotated & mask_b.loc_mask) == 0) continue :next_cand;
                }
            }

            if (doc_id < self.id_to_path.items.len) {
                result.appendAssumeCapacity(self.id_to_path.items[doc_id]);
            }
        }

        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    pub fn candidatesRegex(self: *TrigramIndex, query: *const RegexQuery, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (query.and_trigrams.len == 0 and query.or_groups.len == 0) return null;

        var result_set: ?std.AutoHashMap(u32, void) = null;
        defer if (result_set) |*rs| rs.deinit();

        if (query.and_trigrams.len > 0) {
            for (query.and_trigrams) |tri| {
                const posting_list = self.index.getPtr(tri) orelse {
                    var empty = allocator.alloc([]const u8, 0) catch return null;
                    _ = &empty;
                    return allocator.alloc([]const u8, 0) catch null;
                };
                if (result_set == null) {
                    result_set = std.AutoHashMap(u32, void).init(allocator);
                    for (posting_list.items.items) |p| {
                        result_set.?.put(p.doc_id, {}) catch return null;
                    }
                } else {
                    var to_remove: std.ArrayList(u32) = .empty;
                    defer to_remove.deinit(allocator);
                    var it = result_set.?.keyIterator();
                    while (it.next()) |key| {
                        if (!posting_list.containsDocId(key.*)) {
                            to_remove.append(allocator, key.*) catch return null;
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = result_set.?.remove(key);
                    }
                }
            }
        }

        for (query.or_groups) |group| {
            if (group.len == 0) continue;

            var union_set = std.AutoHashMap(u32, void).init(allocator);
            defer union_set.deinit();
            for (group) |tri| {
                const posting_list = self.index.getPtr(tri) orelse continue;
                for (posting_list.items.items) |p| {
                    union_set.put(p.doc_id, {}) catch return null;
                }
            }

            if (result_set == null) {
                result_set = std.AutoHashMap(u32, void).init(allocator);
                var it = union_set.keyIterator();
                while (it.next()) |key| {
                    result_set.?.put(key.*, {}) catch return null;
                }
            } else {
                var to_remove: std.ArrayList(u32) = .empty;
                defer to_remove.deinit(allocator);
                var it = result_set.?.keyIterator();
                while (it.next()) |key| {
                    if (!union_set.contains(key.*)) {
                        to_remove.append(allocator, key.*) catch return null;
                    }
                }
                for (to_remove.items) |key| {
                    _ = result_set.?.remove(key);
                }
            }
        }

        if (result_set == null) return null;

        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        result.ensureTotalCapacity(allocator, result_set.?.count()) catch return null;
        var it = result_set.?.keyIterator();
        while (it.next()) |id_ptr| {
            const doc_id = id_ptr.*;
            if (doc_id < self.id_to_path.items.len) {
                result.appendAssumeCapacity(self.id_to_path.items[doc_id]);
            }
        }
        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    // ── Disk persistence ────────────────────────────────────

    pub const POSTINGS_MAGIC = [4]u8{ 'C', 'D', 'B', 'T' };
    pub const LOOKUP_MAGIC = [4]u8{ 'C', 'D', 'B', 'L' };
    pub const FORMAT_VERSION: u16 = 3;

    /// Posting entry for v3+: file_id (u32) + next_mask (u8) + loc_mask (u8) + pad (2 bytes) = 8 bytes
    pub const DiskPosting = extern struct {
        file_id: u32,
        next_mask: u8,
        loc_mask: u8,
        _pad: [2]u8 = .{ 0, 0 },
    };

    /// Posting entry for v1/v2 files: file_id (u16) + next_mask (u8) + loc_mask (u8) = 4 bytes
    pub const OldDiskPosting = extern struct {
        file_id: u16,
        next_mask: u8,
        loc_mask: u8,
    };

    /// Lookup entry: trigram (u32 low 24 bits) + offset (u32) + count (u32) = 12 bytes
    pub const LookupEntry = extern struct {
        trigram: u32,
        offset: u32,
        count: u32,
    };

    /// Write the current in-memory index to disk in a two-file format.
    /// Files are written atomically (write to tmp, then rename).
    pub fn writeToDisk(self: *TrigramIndex, io: std.Io, dir_path: []const u8, git_head: ?[40]u8) !void {
        // Step 1: Build file table from path_to_id (reuse existing doc IDs for consistency)
        var file_table: std.ArrayList([]const u8) = .empty;
        defer file_table.deinit(self.allocator);
        var disk_path_to_id = std.StringHashMap(u32).init(self.allocator);
        defer disk_path_to_id.deinit();

        if (self.file_trigrams.count() > 0) {
            var ft_iter = self.file_trigrams.keyIterator();
            while (ft_iter.next()) |path_ptr| {
                const id: u32 = @intCast(file_table.items.len);
                try file_table.append(self.allocator, path_ptr.*);
                try disk_path_to_id.put(path_ptr.*, id);
            }
        } else {
            for (self.id_to_path.items) |path| {
                if (path.len == 0) continue;
                const id: u32 = @intCast(file_table.items.len);
                try file_table.append(self.allocator, path);
                try disk_path_to_id.put(path, id);
            }
        }

        const file_count: u32 = @intCast(file_table.items.len);

        // Step 2: Collect all trigrams, sort them, serialize postings contiguously
        var trigrams_sorted: std.ArrayList(Trigram) = .empty;
        defer trigrams_sorted.deinit(self.allocator);
        {
            var tri_iter = self.index.keyIterator();
            while (tri_iter.next()) |tri_ptr| {
                try trigrams_sorted.append(self.allocator, tri_ptr.*);
            }
        }
        std.mem.sort(Trigram, trigrams_sorted.items, {}, struct {
            fn lt(_: void, a: Trigram, b: Trigram) bool {
                return a < b;
            }
        }.lt);

        // Step 3: Build postings blob and lookup entries
        var postings_buf: std.ArrayList(DiskPosting) = .empty;
        defer postings_buf.deinit(self.allocator);
        var lookup_entries: std.ArrayList(LookupEntry) = .empty;
        defer lookup_entries.deinit(self.allocator);

        for (trigrams_sorted.items) |tri| {
            const posting_list = self.index.getPtr(tri) orelse continue;
            const offset: u32 = @intCast(postings_buf.items.len);
            var count: u32 = 0;
            for (posting_list.items.items) |p| {
                // Map in-memory doc_id to disk file_id via path lookup
                if (p.doc_id >= self.id_to_path.items.len) continue;
                const path = self.id_to_path.items[p.doc_id];
                const fid = disk_path_to_id.get(path) orelse continue;
                try postings_buf.append(self.allocator, .{
                    .file_id = fid,
                    .next_mask = p.next_mask,
                    .loc_mask = p.loc_mask,
                });
                count += 1;
            }
            try lookup_entries.append(self.allocator, .{
                .trigram = @as(u32, tri),
                .offset = offset,
                .count = count,
            });
        }

        // Step 4: Write postings file atomically (random suffix prevents collisions)
        const post_rand: u64 = cio.randU64();
        const postings_tmp = try std.fmt.allocPrint(self.allocator, "{s}/trigram.postings.{x}.tmp", .{ dir_path, post_rand });
        defer self.allocator.free(postings_tmp);
        const postings_final = try std.fmt.allocPrint(self.allocator, "{s}/trigram.postings", .{dir_path});
        defer self.allocator.free(postings_final);

        {
            const file = try std.Io.Dir.cwd().createFile(io, postings_tmp, .{});
            defer file.close(io);

            var pw_buf: [256 * 1024]u8 = undefined;
            var pw = file.writer(io, &pw_buf);

            // Header v3: magic(4) + version(2) + file_count(4) + head_len(1) + head(40) = 51 bytes
            try pw.interface.writeAll(&POSTINGS_MAGIC);
            var ver_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &ver_buf, FORMAT_VERSION, .little);
            try pw.interface.writeAll(&ver_buf);
            var fc_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &fc_buf, file_count, .little);
            try pw.interface.writeAll(&fc_buf);
            // Git HEAD: head_len (1 byte) + head (40 bytes)
            if (git_head) |head| {
                try pw.interface.writeAll(&.{40});
                try pw.interface.writeAll(&head);
            } else {
                try pw.interface.writeAll(&.{0});
                try pw.interface.writeAll(&([_]u8{0} ** 40));
            }

            // File table: for each file, path_len(u16) + path bytes
            for (file_table.items) |path| {
                var pl_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
                try pw.interface.writeAll(&pl_buf);
                try pw.interface.writeAll(path);
            }

            // Postings data
            const postings_bytes = std.mem.sliceAsBytes(postings_buf.items);
            try pw.interface.writeAll(postings_bytes);
            try pw.interface.flush();
        }
        try std.Io.Dir.cwd().rename(postings_tmp, std.Io.Dir.cwd(), postings_final, io);

        // Step 5: Write lookup file atomically (random suffix prevents collisions)
        const lk_rand: u64 = cio.randU64();
        const lookup_tmp = try std.fmt.allocPrint(self.allocator, "{s}/trigram.lookup.{x}.tmp", .{ dir_path, lk_rand });
        defer self.allocator.free(lookup_tmp);
        const lookup_final = try std.fmt.allocPrint(self.allocator, "{s}/trigram.lookup", .{dir_path});
        defer self.allocator.free(lookup_final);

        {
            const file = try std.Io.Dir.cwd().createFile(io, lookup_tmp, .{});
            defer file.close(io);

            var lw_buf: [64 * 1024]u8 = undefined;
            var lw = file.writer(io, &lw_buf);

            // Header: magic(4) + version(2) + pad(2) + entry_count(4) = 12 bytes
            try lw.interface.writeAll(&LOOKUP_MAGIC);
            var ver_buf2: [2]u8 = undefined;
            std.mem.writeInt(u16, &ver_buf2, FORMAT_VERSION, .little);
            try lw.interface.writeAll(&ver_buf2);
            var pad_buf: [2]u8 = .{ 0, 0 };
            try lw.interface.writeAll(&pad_buf);
            var ec_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &ec_buf, @intCast(lookup_entries.items.len), .little);
            try lw.interface.writeAll(&ec_buf);

            // Entries (already aligned at 12 bytes each)
            const entry_bytes = std.mem.sliceAsBytes(lookup_entries.items);
            try lw.interface.writeAll(entry_bytes);
            try lw.interface.flush();
        }
        try std.Io.Dir.cwd().rename(lookup_tmp, std.Io.Dir.cwd(), lookup_final, io);
    }

    /// Load index from disk files into a fresh TrigramIndex.
    /// Returns null if files don't exist or are corrupt/stale.
    pub fn readFromDisk(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) ?TrigramIndex {
        return readFromDiskInner(io, dir_path, allocator) catch null;
    }

    fn readFromDiskInner(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?TrigramIndex {
        const postings_path = try std.fmt.allocPrint(allocator, "{s}/trigram.postings", .{dir_path});
        defer allocator.free(postings_path);
        const lookup_path = try std.fmt.allocPrint(allocator, "{s}/trigram.lookup", .{dir_path});
        defer allocator.free(lookup_path);

        // Read both files
        const postings_data = std.Io.Dir.cwd().readFileAlloc(io, postings_path, allocator, .limited(64 * 1024 * 1024)) catch return null;
        defer allocator.free(postings_data);
        const lookup_data = std.Io.Dir.cwd().readFileAlloc(io, lookup_path, allocator, .limited(64 * 1024 * 1024)) catch return null;
        defer allocator.free(lookup_data);

        // Validate postings header (v1: 8 bytes, v2: 49 bytes, v3: 51 bytes)
        if (postings_data.len < 8) return null;
        if (!std.mem.eql(u8, postings_data[0..4], &POSTINGS_MAGIC)) return null;
        const post_version = std.mem.readInt(u16, postings_data[4..6], .little);
        if (post_version < 1 or post_version > FORMAT_VERSION) return null;
        const file_count: u32 = if (post_version >= 3)
            std.mem.readInt(u32, postings_data[6..10], .little)
        else
            std.mem.readInt(u16, postings_data[6..8], .little);

        const file_table_start: usize = if (post_version >= 3) blk: {
            if (postings_data.len < 51) return null;
            break :blk 51;
        } else if (post_version >= 2) blk: {
            if (postings_data.len < 49) return null;
            break :blk 49;
        } else 8;

        // Parse file table
        var file_paths = try allocator.alloc([]u8, file_count);
        var parsed_files: u32 = 0;
        defer {
            for (0..parsed_files) |i| allocator.free(file_paths[i]);
            allocator.free(file_paths);
        }
        var pos: usize = file_table_start;
        for (0..file_count) |i| {
            if (pos + 2 > postings_data.len) return null;
            const path_len = std.mem.readInt(u16, postings_data[pos..][0..2], .little);
            pos += 2;
            if (pos + path_len > postings_data.len) return null;
            file_paths[i] = try allocator.dupe(u8, postings_data[pos .. pos + path_len]);
            parsed_files += 1;
            pos += path_len;
        }

        // Remaining bytes are DiskPosting entries
        const postings_start = pos;
        const postings_byte_len = postings_data.len - postings_start;
        const posting_size: usize = if (post_version >= 3) @sizeOf(DiskPosting) else @sizeOf(OldDiskPosting);
        if (postings_byte_len % posting_size != 0) return null;
        const total_postings = postings_byte_len / posting_size;

        // Validate lookup header
        if (lookup_data.len < 12) return null;
        if (!std.mem.eql(u8, lookup_data[0..4], &LOOKUP_MAGIC)) return null;
        const lk_version = std.mem.readInt(u16, lookup_data[4..6], .little);
        if (lk_version < 1 or lk_version > FORMAT_VERSION) return null;
        const entry_count = std.mem.readInt(u32, lookup_data[8..12], .little);
        if (lookup_data.len < 12 + entry_count * @sizeOf(LookupEntry)) return null;

        // Build in-memory index
        var result = TrigramIndex.init(allocator);
        result.owns_paths = true;
        errdefer result.deinit();

        // Allocate stable path strings owned by the index and build doc ID mappings
        var stable_paths = try allocator.alloc([]const u8, file_count);
        defer allocator.free(stable_paths);
        for (0..file_count) |i| {
            const duped = try allocator.dupe(u8, file_paths[i]);
            errdefer allocator.free(duped);
            stable_paths[i] = duped;
            try result.file_trigrams.put(duped, .empty);
            try result.path_to_id.put(duped, @intCast(i));
            try result.id_to_path.append(allocator, duped);
        }

        // Parse lookup entries and populate index + file_trigrams
        for (0..entry_count) |e| {
            const entry_off = 12 + e * @sizeOf(LookupEntry);
            const raw = lookup_data[entry_off..][0..@sizeOf(LookupEntry)];
            const entry: *align(1) const LookupEntry = @ptrCast(raw.ptr);

            const tri: Trigram = @intCast(entry.trigram);
            const p_off = entry.offset;
            const p_count = entry.count;

            if (@as(u64, p_off) + @as(u64, p_count) > @as(u64, total_postings)) return error.InvalidData;

            var posting_list: PostingList = .{ .path_to_id = &result.path_to_id };
            errdefer posting_list.deinit(allocator);

            for (0..p_count) |pi| {
                const pb_off = postings_start + (p_off + pi) * posting_size;
                const raw_posting = postings_data[pb_off..][0..posting_size];
                const file_id: u32 = if (post_version >= 3)
                    std.mem.readInt(u32, raw_posting[0..4], .little)
                else
                    std.mem.readInt(u16, raw_posting[0..2], .little);
                const next_mask = raw_posting[if (post_version >= 3) 4 else 2];
                const loc_mask = raw_posting[if (post_version >= 3) 5 else 3];

                if (file_id >= file_count) return error.InvalidData;

                const doc_id: u32 = file_id;
                const posting = try posting_list.getOrAddPosting(allocator, doc_id);
                posting.next_mask |= next_mask;
                posting.loc_mask |= loc_mask;

                // Track trigram in file_trigrams
                const path = stable_paths[file_id];
                if (result.file_trigrams.getPtr(path)) |tri_list| {
                    var found = false;
                    for (tri_list.items) |existing| {
                        if (existing == tri) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try tri_list.append(allocator, tri);
                }
            }

            try result.index.put(tri, posting_list);
        }

        return result;
    }

    /// Returns the number of indexed files (for staleness checks).
    pub fn fileCount(self: *const TrigramIndex) u32 {
        return @intCast(self.file_trigrams.count());
    }

    /// Shrink all posting lists to their actual length, releasing excess capacity.
    /// Call after bulk indexing to reclaim ArrayList over-allocation (~50% savings).
    pub fn shrinkPostingLists(self: *TrigramIndex) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.items.capacity > entry.value_ptr.items.items.len) {
                entry.value_ptr.items.shrinkAndFree(self.allocator, entry.value_ptr.items.items.len);
            }
        }
        // Also shrink file_trigrams lists
        var ft_iter = self.file_trigrams.iterator();
        while (ft_iter.next()) |entry| {
            if (entry.value_ptr.capacity > entry.value_ptr.items.len) {
                entry.value_ptr.shrinkAndFree(self.allocator, entry.value_ptr.items.len);
            }
        }
    }

    /// Header info that can be read without loading the full index.
    pub const DiskHeader = struct {
        file_count: u32,
        git_head: ?[40]u8,
    };

    /// Read just the postings file header — fast, no full file load.
    /// Returns null if the file doesn't exist or has an unrecognised format.
    pub fn readDiskHeader(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?DiskHeader {
        const postings_path = try std.fmt.allocPrint(allocator, "{s}/trigram.postings", .{dir_path});
        defer allocator.free(postings_path);

        const file = std.Io.Dir.cwd().openFile(io, postings_path, .{}) catch return null;
        defer file.close(io);

        var buf: [51]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return null;
        if (n < 8) return null;
        if (!std.mem.eql(u8, buf[0..4], &POSTINGS_MAGIC)) return null;
        const version = std.mem.readInt(u16, buf[4..6], .little);
        if (version < 1 or version > FORMAT_VERSION) return null;
        const file_count: u32 = if (version >= 3)
            std.mem.readInt(u32, buf[6..10], .little)
        else
            std.mem.readInt(u16, buf[6..8], .little);

        var git_head: ?[40]u8 = null;
        if (version >= 3 and n >= 51) {
            const head_len = buf[10];
            if (head_len == 40) {
                var head: [40]u8 = undefined;
                @memcpy(&head, buf[11..51]);
                git_head = head;
            }
        } else if (version >= 2 and n >= 49) {
            const head_len = buf[8];
            if (head_len == 40) {
                var head: [40]u8 = undefined;
                @memcpy(&head, buf[9..49]);
                git_head = head;
            }
        }
        return DiskHeader{ .file_count = file_count, .git_head = git_head };
    }

    /// Read the git HEAD stored in the disk index header.
    /// Returns null if no git HEAD is stored or the file doesn't exist.
    pub fn readGitHead(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?[40]u8 {
        const header = try readDiskHeader(io, dir_path, allocator) orelse return null;
        return header.git_head;
    }
};

// ── mmap-backed trigram index ───────────────────────────────
// Zero-copy: binary search on mmap'd lookup table, read postings directly.
// Replaces heap-based TrigramIndex after writeToDisk for O(log n) lookups
// with ~0 RSS (data lives in OS page cache).

pub const MmapTrigramIndex = struct {
    const mmap_align = std.heap.page_size_min;
    postings_data: []align(mmap_align) const u8,
    lookup_data: []align(mmap_align) const u8,
    file_table: []const []const u8,
    file_set: std.StringHashMap(void),
    postings_start: usize,
    lookup_entries: usize,
    post_version: u16,
    allocator: std.mem.Allocator,

    pub fn initFromDisk(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) ?MmapTrigramIndex {
        return initFromDiskInner(io, dir_path, allocator) catch null;
    }

    fn initFromDiskInner(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?MmapTrigramIndex {
        // Windows: POSIX mmap not available; fall back to in-memory trigram.
        // Wrapped in comptime if so the mmap calls are never analyzed on Windows.
        if (comptime builtin.os.tag == .windows) return null;
        return initFromDiskMmap(io, dir_path, allocator);
    }

    fn initFromDiskMmap(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?MmapTrigramIndex {
        const postings_path = try std.fmt.allocPrint(allocator, "{s}/trigram.postings", .{dir_path});
        defer allocator.free(postings_path);
        const lookup_path = try std.fmt.allocPrint(allocator, "{s}/trigram.lookup", .{dir_path});
        defer allocator.free(lookup_path);

        // mmap postings file
        const post_file = std.Io.Dir.cwd().openFile(io, postings_path, .{}) catch return null;
        defer post_file.close(io);
        const post_size = post_file.length(io) catch return null;
        if (post_size < 8) return null;
        const postings_data = std.posix.mmap(
            null,
            post_size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            post_file.handle,
            0,
        ) catch return null;
        errdefer std.posix.munmap(postings_data);

        // mmap lookup file
        const lk_file = std.Io.Dir.cwd().openFile(io, lookup_path, .{}) catch {
            std.posix.munmap(postings_data);
            return null;
        };
        defer lk_file.close(io);
        const lk_size = lk_file.length(io) catch {
            std.posix.munmap(postings_data);
            return null;
        };
        if (lk_size < 12) {
            std.posix.munmap(postings_data);
            return null;
        }
        const lookup_data = std.posix.mmap(
            null,
            lk_size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            lk_file.handle,
            0,
        ) catch {
            std.posix.munmap(postings_data);
            return null;
        };
        errdefer std.posix.munmap(lookup_data);

        // Validate postings header
        if (!std.mem.eql(u8, postings_data[0..4], &TrigramIndex.POSTINGS_MAGIC)) return null;
        const post_version = std.mem.readInt(u16, postings_data[4..6], .little);
        if (post_version < 1 or post_version > TrigramIndex.FORMAT_VERSION) return null;
        const file_count: u32 = if (post_version >= 3)
            std.mem.readInt(u32, postings_data[6..10], .little)
        else
            std.mem.readInt(u16, postings_data[6..8], .little);

        const file_table_start: usize = if (post_version >= 3) blk: {
            if (postings_data.len < 51) return null;
            break :blk 51;
        } else if (post_version >= 2) blk: {
            if (postings_data.len < 49) return null;
            break :blk 49;
        } else 8;

        // Parse file table (we need owned path strings for lookups)
        var file_table = try allocator.alloc([]const u8, file_count);
        var parsed: u32 = 0;
        errdefer {
            for (0..parsed) |i| allocator.free(file_table[i]);
            allocator.free(file_table);
        }
        var pos: usize = file_table_start;
        for (0..file_count) |i| {
            if (pos + 2 > postings_data.len) return null;
            const path_len = std.mem.readInt(u16, postings_data[pos..][0..2], .little);
            pos += 2;
            if (pos + path_len > postings_data.len) return null;
            file_table[i] = try allocator.dupe(u8, postings_data[pos .. pos + path_len]);
            parsed += 1;
            pos += path_len;
        }

        // Build file_set for containsFile queries
        var file_set = std.StringHashMap(void).init(allocator);
        errdefer file_set.deinit();
        for (file_table[0..parsed]) |p| {
            try file_set.put(p, {});
        }

        const postings_start = pos;

        // Validate lookup header
        if (!std.mem.eql(u8, lookup_data[0..4], &TrigramIndex.LOOKUP_MAGIC)) return null;
        const lk_version = std.mem.readInt(u16, lookup_data[4..6], .little);
        if (lk_version < 1 or lk_version > TrigramIndex.FORMAT_VERSION) return null;
        const entry_count = std.mem.readInt(u32, lookup_data[8..12], .little);
        if (lookup_data.len < 12 + entry_count * @sizeOf(TrigramIndex.LookupEntry)) return null;

        return MmapTrigramIndex{
            .postings_data = postings_data,
            .lookup_data = lookup_data,
            .file_table = file_table,
            .file_set = file_set,
            .postings_start = postings_start,
            .lookup_entries = entry_count,
            .post_version = post_version,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MmapTrigramIndex) void {
        for (self.file_table) |p| self.allocator.free(p);
        self.allocator.free(self.file_table);
        self.file_set.deinit();
        // Windows: MmapTrigramIndex is never created (initFromDiskInner returns
        // null), but the linker still resolves symbols. Guard munmap calls.
        if (comptime builtin.os.tag != .windows) {
            std.posix.munmap(self.postings_data);
            std.posix.munmap(self.lookup_data);
        }
    }

    pub fn fileCount(self: *const MmapTrigramIndex) u32 {
        return @intCast(self.file_table.len);
    }

    pub fn containsFile(self: *const MmapTrigramIndex, path: []const u8) bool {
        return self.file_set.contains(path);
    }

    fn lookupTrigram(self: *const MmapTrigramIndex, tri_val: u32) ?struct { offset: u32, count: u32 } {
        const entries = self.lookup_entries;
        if (entries == 0) return null;
        var lo: usize = 0;
        var hi: usize = entries;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry_off = 12 + mid * @sizeOf(TrigramIndex.LookupEntry);
            const entry_tri = std.mem.readInt(u32, self.lookup_data[entry_off..][0..4], .little);
            if (entry_tri == tri_val) {
                const offset = std.mem.readInt(u32, self.lookup_data[entry_off + 4 ..][0..4], .little);
                const count = std.mem.readInt(u32, self.lookup_data[entry_off + 8 ..][0..4], .little);
                return .{ .offset = offset, .count = count };
            }
            if (entry_tri < tri_val) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    fn readPosting(self: *const MmapTrigramIndex, index: usize) ?struct { file_id: u32, next_mask: u8, loc_mask: u8 } {
        const posting_size: usize = if (self.post_version >= 3) @sizeOf(TrigramIndex.DiskPosting) else @sizeOf(TrigramIndex.OldDiskPosting);
        const pb_off = self.postings_start + index * posting_size;
        if (pb_off + posting_size > self.postings_data.len) return null;
        const raw = self.postings_data[pb_off..][0..posting_size];
        const file_id: u32 = if (self.post_version >= 3)
            std.mem.readInt(u32, raw[0..4], .little)
        else
            std.mem.readInt(u16, raw[0..2], .little);
        const next_mask = raw[if (self.post_version >= 3) 4 else 2];
        const loc_mask = raw[if (self.post_version >= 3) 5 else 3];
        return .{ .file_id = file_id, .next_mask = next_mask, .loc_mask = loc_mask };
    }

    pub fn candidates(self: *const MmapTrigramIndex, query: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (query.len < 3) return null;

        const tri_count = query.len - 2;

        // Collect unique trigrams
        var unique = std.AutoHashMap(Trigram, void).init(allocator);
        defer unique.deinit();
        unique.ensureTotalCapacity(@intCast(tri_count)) catch return null;
        for (0..tri_count) |i| {
            const tri = packTrigram(
                normalizeChar(query[i]),
                normalizeChar(query[i + 1]),
                normalizeChar(query[i + 2]),
            );
            _ = unique.getOrPut(tri) catch return null;
        }

        // Collect posting ranges for each trigram, sorted by count (smallest first)
        const Range = struct { offset: u32, count: u32 };
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(allocator);
        ranges.ensureTotalCapacity(allocator, unique.count()) catch return null;

        var tri_iter = unique.keyIterator();
        while (tri_iter.next()) |tri_ptr| {
            const r = self.lookupTrigram(@as(u32, tri_ptr.*)) orelse {
                return allocator.alloc([]const u8, 0) catch null;
            };
            ranges.appendAssumeCapacity(.{ .offset = r.offset, .count = r.count });
        }

        if (ranges.items.len == 0) {
            return allocator.alloc([]const u8, 0) catch null;
        }

        std.mem.sort(Range, ranges.items, {}, struct {
            fn lt(_: void, a: Range, b: Range) bool {
                return a.count < b.count;
            }
        }.lt);

        // Seed with file_ids from smallest posting range
        var result_ids: std.ArrayList(u32) = .empty;
        defer result_ids.deinit(allocator);
        result_ids.ensureTotalCapacity(allocator, ranges.items[0].count) catch return null;
        for (0..ranges.items[0].count) |pi| {
            const p = self.readPosting(ranges.items[0].offset + pi) orelse continue;
            result_ids.appendAssumeCapacity(p.file_id);
        }

        // Intersect with subsequent ranges (sorted merge)
        for (ranges.items[1..]) |range| {
            var write: usize = 0;
            var si: usize = 0;
            for (result_ids.items) |id| {
                while (si < range.count) {
                    const p = self.readPosting(range.offset + si) orelse break;
                    if (p.file_id >= id) {
                        if (p.file_id == id) {
                            result_ids.items[write] = id;
                            write += 1;
                            si += 1;
                        }
                        break;
                    }
                    si += 1;
                }
            }
            result_ids.items.len = write;
            if (write == 0) break;
        }

        // Bloom filter verification for consecutive trigram pairs
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        result.ensureTotalCapacity(allocator, result_ids.items.len) catch return null;

        next_cand: for (result_ids.items) |file_id| {
            if (tri_count >= 2) {
                for (0..tri_count - 1) |j| {
                    const tri_a_val = @as(u32, packTrigram(
                        normalizeChar(query[j]),
                        normalizeChar(query[j + 1]),
                        normalizeChar(query[j + 2]),
                    ));
                    const tri_b_val = @as(u32, packTrigram(
                        normalizeChar(query[j + 1]),
                        normalizeChar(query[j + 2]),
                        normalizeChar(query[j + 3]),
                    ));
                    const range_a = self.lookupTrigram(tri_a_val) orelse continue;
                    const range_b = self.lookupTrigram(tri_b_val) orelse continue;
                    const mask_a = self.findPostingMask(range_a.offset, range_a.count, file_id) orelse continue;
                    const mask_b = self.findPostingMask(range_b.offset, range_b.count, file_id) orelse continue;

                    const next_bit: u8 = @as(u8, 1) << @intCast(normalizeChar(query[j + 3]) % 8);
                    if ((mask_a.next_mask & next_bit) == 0) continue :next_cand;

                    const rotated = (mask_a.loc_mask << 1) | (mask_a.loc_mask >> 7);
                    if ((rotated & mask_b.loc_mask) == 0) continue :next_cand;
                }
            }

            if (file_id < self.file_table.len) {
                result.appendAssumeCapacity(self.file_table[file_id]);
            }
        }

        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    fn findPostingMask(self: *const MmapTrigramIndex, offset: u32, count: u32, file_id: u32) ?PostingMask {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const p = self.readPosting(offset + mid) orelse return null;
            if (p.file_id == file_id) return PostingMask{ .next_mask = p.next_mask, .loc_mask = p.loc_mask };
            if (p.file_id < file_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    pub fn candidatesRegex(self: *const MmapTrigramIndex, query: *const RegexQuery, allocator: std.mem.Allocator) ?[]const []const u8 {
        if (query.and_trigrams.len == 0 and query.or_groups.len == 0) return null;

        var result_set: ?std.AutoHashMap(u32, void) = null;
        defer if (result_set) |*rs| rs.deinit();

        if (query.and_trigrams.len > 0) {
            for (query.and_trigrams) |tri| {
                const range = self.lookupTrigram(@as(u32, tri)) orelse {
                    return allocator.alloc([]const u8, 0) catch null;
                };
                if (result_set == null) {
                    result_set = std.AutoHashMap(u32, void).init(allocator);
                    for (0..range.count) |pi| {
                        const p = self.readPosting(range.offset + pi) orelse continue;
                        result_set.?.put(p.file_id, {}) catch return null;
                    }
                } else {
                    var to_remove: std.ArrayList(u32) = .empty;
                    defer to_remove.deinit(allocator);
                    var it = result_set.?.keyIterator();
                    while (it.next()) |key| {
                        if (self.findPostingMask(range.offset, range.count, key.*) == null) {
                            to_remove.append(allocator, key.*) catch return null;
                        }
                    }
                    for (to_remove.items) |key| {
                        _ = result_set.?.remove(key);
                    }
                }
            }
        }

        for (query.or_groups) |group| {
            if (group.len == 0) continue;

            var union_set = std.AutoHashMap(u32, void).init(allocator);
            defer union_set.deinit();
            for (group) |tri| {
                const range = self.lookupTrigram(@as(u32, tri)) orelse continue;
                for (0..range.count) |pi| {
                    const p = self.readPosting(range.offset + pi) orelse continue;
                    union_set.put(p.file_id, {}) catch return null;
                }
            }

            if (result_set == null) {
                result_set = std.AutoHashMap(u32, void).init(allocator);
                var it = union_set.keyIterator();
                while (it.next()) |key| {
                    result_set.?.put(key.*, {}) catch return null;
                }
            } else {
                var to_remove: std.ArrayList(u32) = .empty;
                defer to_remove.deinit(allocator);
                var it = result_set.?.keyIterator();
                while (it.next()) |key| {
                    if (!union_set.contains(key.*)) {
                        to_remove.append(allocator, key.*) catch return null;
                    }
                }
                for (to_remove.items) |key| {
                    _ = result_set.?.remove(key);
                }
            }
        }

        if (result_set == null) return null;

        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        result.ensureTotalCapacity(allocator, result_set.?.count()) catch return null;
        var it = result_set.?.keyIterator();
        while (it.next()) |id_ptr| {
            const doc_id = id_ptr.*;
            if (doc_id < self.file_table.len) {
                result.appendAssumeCapacity(self.file_table[doc_id]);
            }
        }
        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }
};

pub const AnyTrigramIndex = union(enum) {
    heap: TrigramIndex,
    mmap: MmapTrigramIndex,
    mmap_overlay: MmapOverlay,

    pub const MmapOverlay = struct {
        base: MmapTrigramIndex,
        overlay: TrigramIndex,

        pub fn deinit(self: *MmapOverlay) void {
            self.base.deinit();
            self.overlay.deinit();
        }
    };

    pub fn deinit(self: *AnyTrigramIndex) void {
        switch (self.*) {
            .heap => |*h| h.deinit(),
            .mmap => |*m| m.deinit(),
            .mmap_overlay => |*mo| mo.deinit(),
        }
    }

    pub fn candidates(self: *AnyTrigramIndex, query: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        return switch (self.*) {
            .heap => |*h| h.candidates(query, allocator),
            .mmap => |*m| m.candidates(query, allocator),
            .mmap_overlay => |*mo| blk: {
                const base = mo.base.candidates(query, allocator);
                const over = mo.overlay.candidates(query, allocator);
                if (base == null and over == null) break :blk null;
                if (base == null) break :blk over;
                if (over == null) break :blk base;
                // Merge and dedup — return null on alloc failure (triggers full scan fallback)
                var merged = std.StringHashMap(void).init(allocator);
                defer merged.deinit();
                for (base.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                for (over.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                allocator.free(base.?);
                allocator.free(over.?);
                var result: std.ArrayList([]const u8) = .empty;
                result.ensureTotalCapacity(allocator, merged.count()) catch break :blk null;
                var it = merged.keyIterator();
                while (it.next()) |k| result.appendAssumeCapacity(k.*);
                break :blk result.toOwnedSlice(allocator) catch {
                    result.deinit(allocator);
                    break :blk null;
                };
            },
        };
    }

    pub fn candidatesRegex(self: *AnyTrigramIndex, query: *const RegexQuery, allocator: std.mem.Allocator) ?[]const []const u8 {
        return switch (self.*) {
            .heap => |*h| h.candidatesRegex(query, allocator),
            .mmap => |*m| m.candidatesRegex(query, allocator),
            .mmap_overlay => |*mo| blk: {
                const base = mo.base.candidatesRegex(query, allocator);
                const over = mo.overlay.candidatesRegex(query, allocator);
                if (base == null and over == null) break :blk null;
                if (base == null) break :blk over;
                if (over == null) break :blk base;
                var merged = std.StringHashMap(void).init(allocator);
                defer merged.deinit();
                for (base.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                for (over.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                allocator.free(base.?);
                allocator.free(over.?);
                var result: std.ArrayList([]const u8) = .empty;
                result.ensureTotalCapacity(allocator, merged.count()) catch break :blk null;
                var it = merged.keyIterator();
                while (it.next()) |k| result.appendAssumeCapacity(k.*);
                break :blk result.toOwnedSlice(allocator) catch {
                    result.deinit(allocator);
                    break :blk null;
                };
            },
        };
    }

    pub fn containsFile(self: *const AnyTrigramIndex, path: []const u8) bool {
        return switch (self.*) {
            .heap => |*h| h.file_trigrams.contains(path),
            .mmap => |*m| m.containsFile(path),
            .mmap_overlay => |*mo| mo.base.containsFile(path) or mo.overlay.file_trigrams.contains(path),
        };
    }

    pub fn indexFile(self: *AnyTrigramIndex, path: []const u8, content: []const u8) !void {
        switch (self.*) {
            .heap => |*h| try h.indexFile(path, content),
            .mmap => |*m| {
                // Promote to mmap_overlay: keep mmap base, add heap overlay
                const alloc = m.allocator;
                const base = self.mmap;
                self.* = .{ .mmap_overlay = .{
                    .base = base,
                    .overlay = TrigramIndex.init(alloc),
                } };
                try self.mmap_overlay.overlay.indexFile(path, content);
            },
            .mmap_overlay => |*mo| try mo.overlay.indexFile(path, content),
        }
    }

    pub fn removeFile(self: *AnyTrigramIndex, path: []const u8) void {
        switch (self.*) {
            .heap => |*h| h.removeFile(path),
            .mmap => {},
            .mmap_overlay => |*mo| mo.overlay.removeFile(path),
        }
    }

    pub fn writeToDisk(self: *AnyTrigramIndex, io: std.Io, dir_path: []const u8, git_head: ?[40]u8) !void {
        switch (self.*) {
            .heap => |*h| try h.writeToDisk(io, dir_path, git_head),
            .mmap => {},
            .mmap_overlay => {},
        }
    }

    pub fn fileCount(self: *const AnyTrigramIndex) u32 {
        return switch (self.*) {
            .heap => |*h| h.fileCount(),
            .mmap => |*m| m.fileCount(),
            .mmap_overlay => |*mo| mo.base.fileCount() + mo.overlay.fileCount(),
        };
    }

    pub fn asHeap(self: *AnyTrigramIndex) ?*TrigramIndex {
        return switch (self.*) {
            .heap => |*h| h,
            .mmap => null,
            .mmap_overlay => |*mo| &mo.overlay,
        };
    }
};
// ── Regex decomposition ─────────────────────────────────────
