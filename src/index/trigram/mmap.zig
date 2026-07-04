// Trigram index — mmap-backed, read-only variant.
//
// Extracted from the former trigram.zig monolith. Reads the on-disk format
// produced by heap.zig's TrigramIndex.writeToDisk. Magic constants and disk
// structs (DiskPosting, LookupEntry, etc.) live on the TrigramIndex namespace
// in heap.zig.

const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../../cio.zig");
const normalizeChar = @import("../chars.zig").normalizeChar;

const heap = @import("heap.zig");
const TrigramIndex = heap.TrigramIndex;

const tg_posting = @import("../trigram_posting.zig");
const Trigram = tg_posting.Trigram;
const packTrigram = tg_posting.packTrigram;
const PostingMask = tg_posting.PostingMask;
const DocPosting = tg_posting.DocPosting;
const PostingList = tg_posting.PostingList;

const regex_query = @import("../regex_query.zig");
const RegexQuery = regex_query.RegexQuery;
const decomposeRegex = regex_query.decomposeRegex;

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

    /// Read lookup entry `idx` directly from the mmapped lookup table. Used by
    /// materializeOverlay to walk every (trigram, posting) pair when persisting
    /// an mmap_overlay to disk. (#600)
    pub fn lookupEntryAt(self: *const MmapTrigramIndex, idx: usize) TrigramIndex.LookupEntry {
        const entry_off = 12 + idx * @sizeOf(TrigramIndex.LookupEntry);
        return .{
            .trigram = std.mem.readInt(u32, self.lookup_data[entry_off..][0..4], .little),
            .offset = std.mem.readInt(u32, self.lookup_data[entry_off + 4 ..][0..4], .little),
            .count = std.mem.readInt(u32, self.lookup_data[entry_off + 8 ..][0..4], .little),
        };
    }

    pub fn readPosting(self: *const MmapTrigramIndex, index: usize) ?struct { file_id: u32, next_mask: u8, loc_mask: u8 } {
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
