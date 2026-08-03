const std = @import("std");
const cio = @import("../cio.zig");
const tokenizer = @import("word_tokenizer.zig");
const WordTokenizer = tokenizer.WordTokenizer;
const splitIdentifier = tokenizer.splitIdentifier;
const normalizeChar = @import("chars.zig").normalizeChar;

pub const WordHit = struct {
    doc_id: u32,
    line_num: u32,
};

pub const WordIndex = struct {
    /// word → hits
    index: std.StringHashMap(std.ArrayList(WordHit)),
    /// path → set of words contributed (for efficient re-index cleanup).
    /// WordIndex owns these path keys.
    file_words: std.StringHashMap([]const []const u8),
    allocator: std.mem.Allocator,
    skip_file_words: bool = false,
    enabled: bool = true,
    path_to_id: std.StringHashMap(u32),
    id_to_path: std.ArrayList([]const u8),
    /// freed doc_id slots available for reuse by getOrCreateDocId (#606)
    free_ids: std.ArrayList(u32) = .empty,
    /// doc_id → number of tokens indexed for that doc (BM25 length normalization).
    doc_lengths: std.AutoHashMap(u32, u32),
    /// Sum of all values in doc_lengths.
    total_tokens: u64 = 0,

    pub fn hitPath(self: *const WordIndex, hit: WordHit) []const u8 {
        if (hit.doc_id < self.id_to_path.items.len) return self.id_to_path.items[hit.doc_id];
        return "";
    }

    fn getOrCreateDocId(self: *WordIndex, path: []const u8) !u32 {
        if (self.path_to_id.get(path)) |id| return id;
        // #606: reuse a freed doc_id slot if one is available. put first so a
        // failed put leaves the free list and the slot untouched (no dangling
        // id_to_path entry pointing at a path that isn't in path_to_id).
        if (self.free_ids.items.len > 0) {
            const freed = self.free_ids.items[self.free_ids.items.len - 1];
            try self.path_to_id.put(path, freed);
            _ = self.free_ids.pop();
            self.id_to_path.items[@as(usize, freed)] = path;
            return freed;
        }
        const id: u32 = @intCast(self.id_to_path.items.len);
        try self.id_to_path.append(self.allocator, path);
        self.path_to_id.put(path, id) catch |err| {
            _ = self.id_to_path.pop();
            return err;
        };
        return id;
    }

    pub fn init(allocator: std.mem.Allocator) WordIndex {
        return .{
            .index = std.StringHashMap(std.ArrayList(WordHit)).init(allocator),
            .file_words = std.StringHashMap([]const []const u8).init(allocator),
            .allocator = allocator,
            .path_to_id = std.StringHashMap(u32).init(allocator),
            .id_to_path = .empty,
            .doc_lengths = std.AutoHashMap(u32, u32).init(allocator),
            .total_tokens = 0,
        };
    }

    pub fn deinit(self: *WordIndex) void {
        // Free hit lists and duped word keys
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.index.deinit();

        // Free per-file word sets
        var fw_iter = self.file_words.iterator();
        while (fw_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.file_words.deinit();

        if (self.skip_file_words) {
            for (self.id_to_path.items) |path| {
                if (path.len > 0) self.allocator.free(path);
            }
        }

        self.path_to_id.deinit();
        self.id_to_path.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
        self.doc_lengths.deinit();
    }

    /// Remove all index entries for a file (call before re-indexing).
    pub fn removeFile(self: *WordIndex, path: []const u8) void {
        if (self.file_words.fetchRemove(path)) |removed| {
            const stable_path = removed.key;
            const words_slice = removed.value;

            const doc_id = self.path_to_id.get(stable_path) orelse {
                self.allocator.free(words_slice);
                self.allocator.free(stable_path);
                return;
            };
            _ = self.path_to_id.remove(stable_path);
            if (doc_id < self.id_to_path.items.len) {
                self.id_to_path.items[doc_id] = "";
                // #606: recycle the slot so getOrCreateDocId can reuse it, keeping
                // id_to_path bounded in long-lived daemons instead of growing on
                // every re-index.
                self.free_ids.append(self.allocator, doc_id) catch {};
            }
            if (self.doc_lengths.fetchRemove(doc_id)) |kv| {
                self.total_tokens -= kv.value;
            }
            defer {
                self.allocator.free(words_slice);
                self.allocator.free(stable_path);
            }

            // For each word this file contributed, remove hits with this doc_id.
            // Prune empty buckets so churn does not leak key/list entries.
            for (words_slice) |word| {
                const word_ptr = &word;
                if (self.index.getEntry(word_ptr.*)) |entry| {
                    const hits = entry.value_ptr;
                    var i: usize = 0;
                    while (i < hits.items.len) {
                        if (hits.items[i].doc_id == doc_id) {
                            _ = hits.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    if (hits.items.len == 0) {
                        const owned_word = entry.key_ptr.*;
                        hits.deinit(self.allocator);
                        _ = self.index.remove(word_ptr.*);
                        self.allocator.free(owned_word);
                    }
                }
            }
            return;
        }

        // No per-file word list: `path` was indexed while skip_file_words was
        // set (the bulk-scan memory optimization, commands/mod.zig), which
        // never populates file_words. Pre-fix this was a silent no-op, so a
        // file edited after a cold-started long-running process (e.g. `codedb
        // serve` starting from no snapshot) accumulated ghost postings at
        // stale lines and doubled BM25 term frequency forever. Sweep every
        // posting list for the doc_id instead — the caller-visible cost is an
        // O(index) scan on a path that would otherwise have wrong results.
        const doc_id = self.path_to_id.get(path) orelse return;
        _ = self.path_to_id.remove(path);
        if (self.doc_lengths.fetchRemove(doc_id)) |kv| {
            self.total_tokens -= kv.value;
        }
        var freed_path: ?[]const u8 = null;
        if (doc_id < self.id_to_path.items.len) {
            freed_path = self.id_to_path.items[doc_id];
            self.id_to_path.items[doc_id] = "";
            self.free_ids.append(self.allocator, doc_id) catch {};
        }
        // id_to_path owns this string when skip_file_words populated it
        // (mirrors the ownership rule already applied in deinit()).
        defer if (freed_path) |p| {
            if (p.len > 0) self.allocator.free(@constCast(p));
        };

        var empty_words: std.ArrayList([]const u8) = .empty;
        defer empty_words.deinit(self.allocator);
        var it = self.index.iterator();
        while (it.next()) |entry| {
            const hits = entry.value_ptr;
            var i: usize = 0;
            while (i < hits.items.len) {
                if (hits.items[i].doc_id == doc_id) {
                    _ = hits.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (hits.items.len == 0) {
                empty_words.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (empty_words.items) |word| {
            if (self.index.fetchRemove(word)) |kv| {
                var hits = kv.value;
                hits.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
        }
    }
    fn indexOneToken(
        self: *WordIndex,
        token: []const u8,
        doc_id: u32,
        line_num: u32,
        words_set: *std.StringHashMap(void),
    ) !void {
        const gop = try self.index.getOrPut(token);
        if (!gop.found_existing) {
            const duped = try self.allocator.dupe(u8, token);
            gop.key_ptr.* = duped;
            gop.value_ptr.* = .empty;
        }
        if (gop.value_ptr.items.len > 0) {
            const last = gop.value_ptr.items[gop.value_ptr.items.len - 1];
            if (last.doc_id == doc_id and last.line_num == line_num) {
                const wgop = try words_set.getOrPut(gop.key_ptr.*);
                if (!wgop.found_existing) wgop.key_ptr.* = gop.key_ptr.*;
                return;
            }
        }
        try gop.value_ptr.append(self.allocator, .{
            .doc_id = doc_id,
            .line_num = line_num,
        });
        const wgop = try words_set.getOrPut(gop.key_ptr.*);
        if (!wgop.found_existing) wgop.key_ptr.* = gop.key_ptr.*;
    }

    pub fn indexFile(self: *WordIndex, path: []const u8, content: []const u8) !void {
        if (!self.enabled) return;
        // Clean up old entries first
        self.removeFile(path);

        // If the path is already tracked (e.g. skip_file_words=true and removeFile
        // early-exited), reuse the existing stable copy rather than leaking a new dup.
        const stable_path = if (self.path_to_id.contains(path))
            path
        else
            try self.allocator.dupe(u8, path);
        const owned_path = stable_path.ptr != path.ptr;
        errdefer if (owned_path) self.allocator.free(stable_path);

        const doc_id = try self.getOrCreateDocId(stable_path);

        // Use page_allocator-backed arena for words_set — pages are returned
        // to the OS immediately when the arena is deinitialized, instead of
        // being retained by the GPA (which caused ~1GB of page retention
        // across 14K files of alloc/free churn).
        var words_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer words_arena.deinit();
        var words_set = std.StringHashMap(void).init(words_arena.allocator());
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var doc_token_count: u32 = 0;

        while (lines.next()) |line| {
            line_num += 1;
            var tok = WordTokenizer{ .buf = line };
            while (tok.next()) |word| {
                if (word.len < 2) continue;
                doc_token_count +|= 1;

                const aa = words_arena.allocator();

                // Fast path: lowercase into a stack buffer (avoids one alloc per word).
                // Most identifiers fit in 256 bytes; rare longer ones fall through
                // to the arena path.
                var stack_buf: [256]u8 = undefined;
                const lower_word: []const u8 = if (word.len <= stack_buf.len) blk: {
                    for (word, 0..) |c, j| stack_buf[j] = normalizeChar(c);
                    // Check if the lowercase form differs from the original;
                    // if identical (already lowercase) and word is the actual
                    // source token, we can use `word` directly — but we'd need
                    // the string to outlive the stack frame when stored, so
                    // dup only at the insert-key boundary below.
                    break :blk stack_buf[0..word.len];
                } else blk: {
                    const buf = aa.alloc(u8, word.len) catch continue;
                    for (word, 0..) |c, j| buf[j] = normalizeChar(c);
                    break :blk buf;
                };

                // Index the lowercase form.
                try indexOneToken(self, lower_word, doc_id, line_num, &words_set);

                // Sub-tokens from identifier splitting (camelCase, snake_case, etc.).
                // Skip the alloc'd ArrayList when the word is too short or all-lower
                // (no split possible).
                var needs_split: bool = false;
                if (word.len >= 4) {
                    for (word) |c| {
                        if (c == '_' or (c >= 'A' and c <= 'Z')) {
                            needs_split = true;
                            break;
                        }
                    }
                }
                if (needs_split) {
                    var sub_toks: std.ArrayList([]const u8) = .empty;
                    defer sub_toks.deinit(aa);
                    splitIdentifier(word, &sub_toks, aa) catch continue;
                    for (sub_toks.items) |sub| {
                        try indexOneToken(self, sub, doc_id, line_num, &words_set);
                    }
                }
            }
        }

        if (!self.skip_file_words) {
            // Compact the HashMap to a simple slice — saves ~70KB per file
            const compact = try self.allocator.alloc([]const u8, words_set.count());
            var ki: usize = 0;
            var wk_iter = words_set.keyIterator();
            while (wk_iter.next()) |k| : (ki += 1) {
                compact[ki] = k.*;
            }
            try self.file_words.put(stable_path, compact);
        }
        words_set.deinit();

        if (self.doc_lengths.get(doc_id)) |old_len| {
            self.total_tokens -%= old_len;
        }
        try self.doc_lengths.put(doc_id, doc_token_count);
        self.total_tokens += doc_token_count;
    }

    /// Look up all hits for a word. O(1) lookup + O(hits) iteration.
    /// Query is normalized to lowercase (all index keys are stored lowercase).
    pub fn search(self: *WordIndex, word: []const u8) []const WordHit {
        var buf: [512]u8 = undefined;
        const lower = if (word.len <= buf.len) blk: {
            for (word, 0..) |c, i| buf[i] = normalizeChar(c);
            break :blk buf[0..word.len];
        } else word;
        if (self.index.get(lower)) |hits| return hits.items;
        return &.{};
    }

    /// Look up hits, returning results allocated by the caller.
    /// Deduplicates by (path, line_num).
    pub fn searchDeduped(self: *WordIndex, word: []const u8, allocator: std.mem.Allocator) ![]const WordHit {
        const hits = self.search(word);
        if (hits.len == 0) return try allocator.alloc(WordHit, 0);
        if (hits.len == 1) {
            var out = try allocator.alloc(WordHit, 1);
            out[0] = hits[0];
            return out;
        }

        const DedupKey = struct { doc_id: u32, line_num: u32 };
        var seen = std.AutoHashMap(DedupKey, void).init(allocator);
        defer seen.deinit();
        try seen.ensureTotalCapacity(@intCast(hits.len));

        var result: std.ArrayList(WordHit) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, hits.len);

        for (hits) |hit| {
            const key = DedupKey{ .doc_id = hit.doc_id, .line_num = hit.line_num };
            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) {
                result.appendAssumeCapacity(hit);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Collect all hits for index keys that begin with `prefix_raw` (normalized internally to
    /// lowercase). Only keys strictly longer than the normalized prefix are considered —
    /// exact-match keys are already handled by Tier 0 (`search`).
    /// Results are deduplicated by (doc_id, line_num), capped at `max_results`, and returned as an owned slice.
    pub fn searchPrefix(self: *WordIndex, prefix_raw: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const WordHit {
        if (prefix_raw.len == 0 or max_results == 0) return try allocator.alloc(WordHit, 0);
        var buf: [512]u8 = undefined;
        const prefix = if (prefix_raw.len <= buf.len) blk: {
            for (prefix_raw, 0..) |c, i| buf[i] = normalizeChar(c);
            break :blk buf[0..prefix_raw.len];
        } else prefix_raw;

        var result: std.ArrayList(WordHit) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, max_results);
        const DedupKey = struct { doc_id: u32, line_num: u32 };
        var seen = std.AutoHashMap(DedupKey, void).init(allocator);
        defer seen.deinit();
        try seen.ensureTotalCapacity(@intCast(max_results));

        var key_iter = self.index.keyIterator();
        outer: while (key_iter.next()) |k| {
            if (k.len <= prefix.len) continue; // strictly longer: exact match is Tier 0
            if (!std.mem.startsWith(u8, k.*, prefix)) continue;
            const hits = self.index.get(k.*) orelse continue;
            for (hits.items) |hit| {
                const dk = DedupKey{ .doc_id = hit.doc_id, .line_num = hit.line_num };
                const gop = try seen.getOrPut(dk);
                if (!gop.found_existing) {
                    result.appendAssumeCapacity(hit);
                    if (result.items.len >= max_results) break :outer;
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn fileCount(self: *WordIndex) u32 {
        return @intCast(self.file_words.count());
    }

    /// BM25 helper: number of docs the ranker can see (source of truth regardless of skip_file_words).
    pub fn rankedDocCount(self: *const WordIndex) u32 {
        return @intCast(self.doc_lengths.count());
    }

    /// BM25 helper: number of indexed tokens in a doc, or 0 if unknown.
    pub fn docLength(self: *const WordIndex, doc_id: u32) u32 {
        return self.doc_lengths.get(doc_id) orelse 0;
    }

    /// BM25 helper: average doc length over docs that have a recorded length.
    /// Returns 1.0 when no docs are tracked, so callers can divide safely.
    pub fn avgDocLength(self: *const WordIndex) f32 {
        const n = self.doc_lengths.count();
        if (n == 0) return 1.0;
        return @as(f32, @floatFromInt(self.total_tokens)) / @as(f32, @floatFromInt(n));
    }

    /// Shrink all hit lists and per-file word sets to release excess capacity.
    pub fn shrinkAllocations(self: *WordIndex) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.capacity > entry.value_ptr.items.len) {
                entry.value_ptr.shrinkAndFree(self.allocator, entry.value_ptr.items.len);
            }
        }
    }

    pub const DiskHeader = struct {
        file_count: u32,
        git_head: ?[40]u8,
    };

    const DISK_MAGIC = [4]u8{ 'C', 'D', 'B', 'W' };
    const DISK_FORMAT_VERSION: u16 = 3;

    pub fn writeToDisk(self: *WordIndex, io: std.Io, dir_path: []const u8, git_head: ?[40]u8) !void {
        var file_table: std.ArrayList([]const u8) = .empty;
        defer file_table.deinit(self.allocator);
        var disk_path_to_id = std.StringHashMap(u32).init(self.allocator);
        defer disk_path_to_id.deinit();

        if (self.file_words.count() > 0) {
            var file_iter = self.file_words.iterator();
            while (file_iter.next()) |entry| {
                const path = entry.key_ptr.*;
                if (path.len > std.math.maxInt(u16)) return error.NameTooLong;
                const id: u32 = @intCast(file_table.items.len);
                try file_table.append(self.allocator, path);
                try disk_path_to_id.put(path, id);
            }
        } else {
            for (self.id_to_path.items) |path| {
                if (path.len == 0) continue;
                if (path.len > std.math.maxInt(u16)) return error.NameTooLong;
                const id: u32 = @intCast(file_table.items.len);
                try file_table.append(self.allocator, path);
                try disk_path_to_id.put(path, id);
            }
        }

        var words_sorted: std.ArrayList([]const u8) = .empty;
        defer words_sorted.deinit(self.allocator);
        try words_sorted.ensureTotalCapacity(self.allocator, self.index.count());
        var word_iter = self.index.keyIterator();
        while (word_iter.next()) |word_ptr| {
            if (word_ptr.*.len > std.math.maxInt(u16)) return error.NameTooLong;
            words_sorted.appendAssumeCapacity(word_ptr.*);
        }
        std.mem.sort([]const u8, words_sorted.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        const rand_suffix = cio.randU64();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/word.index.{x}.tmp", .{ dir_path, rand_suffix });
        defer self.allocator.free(tmp_path);
        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/word.index", .{dir_path});
        defer self.allocator.free(final_path);

        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);

        var file_buf: [256 * 1024]u8 = undefined;
        var writer = file.writer(io, &file_buf);

        var header_buf: [51]u8 = [_]u8{0} ** 51;
        @memcpy(header_buf[0..4], &DISK_MAGIC);
        std.mem.writeInt(u16, header_buf[4..6], DISK_FORMAT_VERSION, .little);
        std.mem.writeInt(u32, header_buf[6..10], @intCast(file_table.items.len), .little);
        if (git_head) |head| {
            header_buf[10] = 40;
            @memcpy(header_buf[11..51], &head);
        }
        try writer.interface.writeAll(&header_buf);

        for (file_table.items) |path| {
            var pl_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &pl_buf, @intCast(path.len), .little);
            try writer.interface.writeAll(&pl_buf);
            try writer.interface.writeAll(path);
        }

        var wc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &wc_buf, @intCast(words_sorted.items.len), .little);
        try writer.interface.writeAll(&wc_buf);

        for (words_sorted.items) |word| {
            const hits = self.index.get(word) orelse return error.InvalidData;
            var wl_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &wl_buf, @intCast(word.len), .little);
            try writer.interface.writeAll(&wl_buf);
            try writer.interface.writeAll(word);

            var hc_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &hc_buf, @intCast(hits.items.len), .little);
            try writer.interface.writeAll(&hc_buf);
            for (hits.items) |hit| {
                const hit_path = self.id_to_path.items[hit.doc_id];
                const file_id = disk_path_to_id.get(hit_path) orelse return error.InvalidData;
                var hit_buf: [8]u8 = undefined;
                std.mem.writeInt(u32, hit_buf[0..4], file_id, .little);
                std.mem.writeInt(u32, hit_buf[4..8], hit.line_num, .little);
                try writer.interface.writeAll(&hit_buf);
            }
        }

        // v3 trailer: per-doc length table for BM25.
        // file_id (u32 disk-id) → length (u32). Total tokens follows as u64.
        var dl_count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &dl_count_buf, @intCast(file_table.items.len), .little);
        try writer.interface.writeAll(&dl_count_buf);
        for (file_table.items) |path| {
            const in_mem_id = self.path_to_id.get(path) orelse {
                var z: [4]u8 = .{ 0, 0, 0, 0 };
                try writer.interface.writeAll(&z);
                continue;
            };
            const len = self.doc_lengths.get(in_mem_id) orelse 0;
            var lb: [4]u8 = undefined;
            std.mem.writeInt(u32, &lb, len, .little);
            try writer.interface.writeAll(&lb);
        }
        var tt_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &tt_buf, self.total_tokens, .little);
        try writer.interface.writeAll(&tt_buf);

        try writer.interface.flush();

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
    }

    pub fn readFromDisk(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) ?WordIndex {
        return readFromDiskInner(io, dir_path, allocator) catch null;
    }

    fn readFromDiskInner(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?WordIndex {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/word.index", .{dir_path});
        defer allocator.free(index_path);

        const data = std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(512 * 1024 * 1024)) catch return null;
        defer allocator.free(data);

        if (data.len < 51) return null;
        if (!std.mem.eql(u8, data[0..4], &DISK_MAGIC)) return null;
        const version = std.mem.readInt(u16, data[4..6], .little);
        if (version != DISK_FORMAT_VERSION) return null;
        const file_count = std.mem.readInt(u32, data[6..10], .little);

        var file_paths = try allocator.alloc([]u8, file_count);
        defer allocator.free(file_paths);
        var used_paths = try allocator.alloc(bool, file_count);
        defer allocator.free(used_paths);
        @memset(used_paths, false);
        var parsed_files: u32 = 0;
        defer {
            for (0..parsed_files) |i| {
                if (!used_paths[i]) allocator.free(file_paths[i]);
            }
        }

        var pos: usize = 51;
        for (0..file_count) |i| {
            if (pos + 2 > data.len) return null;
            const path_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (path_len == 0 or pos + path_len > data.len) return null;
            file_paths[i] = try allocator.dupe(u8, data[pos .. pos + path_len]);
            pos += path_len;
            parsed_files += 1;
        }

        if (pos + 4 > data.len) return null;
        const word_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var result = WordIndex.init(allocator);
        errdefer result.deinit();

        // Temporary HashMap for accumulating file_words during load
        // (compacted to slices below)
        var tmp_file_words = std.StringHashMap(std.StringHashMap(void)).init(allocator);
        defer {
            var tfw_iter = tmp_file_words.iterator();
            while (tfw_iter.next()) |entry| entry.value_ptr.deinit();
            tmp_file_words.deinit();
        }

        for (0..word_count) |_| {
            if (pos + 2 > data.len) return null;
            const word_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (word_len == 0 or pos + word_len > data.len) return null;
            const word = try allocator.dupe(u8, data[pos .. pos + word_len]);
            pos += word_len;
            errdefer allocator.free(word);

            if (pos + 4 > data.len) return null;
            const hit_count = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            var hits: std.ArrayList(WordHit) = .empty;
            errdefer hits.deinit(allocator);
            try hits.ensureTotalCapacity(allocator, hit_count);

            var last_file_id: ?u32 = null;
            for (0..hit_count) |_| {
                if (pos + 8 > data.len) return null;
                const file_id = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
                if (file_id >= file_count) return null;
                const line_num = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;

                hits.appendAssumeCapacity(.{
                    .doc_id = file_id,
                    .line_num = line_num,
                });

                if (last_file_id == null or last_file_id.? != file_id) {
                    const fw_gop = try tmp_file_words.getOrPut(file_paths[file_id]);
                    if (!fw_gop.found_existing) {
                        fw_gop.key_ptr.* = file_paths[file_id];
                        fw_gop.value_ptr.* = std.StringHashMap(void).init(allocator);
                        used_paths[file_id] = true;
                    }
                    const wgop = try fw_gop.value_ptr.getOrPut(word);
                    if (!wgop.found_existing) wgop.key_ptr.* = word;
                    last_file_id = file_id;
                }
            }

            const gop = try result.index.getOrPut(word);
            if (gop.found_existing) return error.InvalidData;
            gop.key_ptr.* = word;
            gop.value_ptr.* = hits;
        }

        // v3 trailer: per-doc length table.
        if (pos + 4 > data.len) return null;
        const dl_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (dl_count != file_count) return null;
        if (pos + dl_count * 4 + 8 > data.len) return null;
        var dl_values = try allocator.alloc(u32, dl_count);
        defer allocator.free(dl_values);
        for (0..dl_count) |i| {
            dl_values[i] = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
        }
        const total_tokens_loaded = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        if (pos != data.len) return null;

        // Populate path_to_id and id_to_path from file_paths
        try result.id_to_path.ensureTotalCapacity(allocator, file_count);
        for (0..file_count) |i| {
            result.id_to_path.appendAssumeCapacity(file_paths[i]);
            try result.path_to_id.put(file_paths[i], @intCast(i));
            if (dl_values[i] > 0) {
                try result.doc_lengths.put(@intCast(i), dl_values[i]);
            }
        }
        result.total_tokens = total_tokens_loaded;

        // Compact tmp_file_words HashMaps into slices for result.file_words
        var tfw_iter = tmp_file_words.iterator();
        while (tfw_iter.next()) |entry| {
            const compact = try allocator.alloc([]const u8, entry.value_ptr.count());
            var ki2: usize = 0;
            var wk_iter2 = entry.value_ptr.keyIterator();
            while (wk_iter2.next()) |k| : (ki2 += 1) {
                compact[ki2] = k.*;
            }
            try result.file_words.put(entry.key_ptr.*, compact);
        }

        return result;
    }

    pub fn readDiskHeader(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?DiskHeader {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/word.index", .{dir_path});
        defer allocator.free(index_path);

        const file = std.Io.Dir.cwd().openFile(io, index_path, .{}) catch return null;
        defer file.close(io);

        var buf: [51]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return null;
        if (n < 51) return null;
        if (!std.mem.eql(u8, buf[0..4], &DISK_MAGIC)) return null;
        const version = std.mem.readInt(u16, buf[4..6], .little);
        if (version < 1 or version > DISK_FORMAT_VERSION) return null;

        const file_count = std.mem.readInt(u32, buf[6..10], .little);
        var git_head: ?[40]u8 = null;
        if (buf[10] == 40) {
            var head: [40]u8 = undefined;
            @memcpy(&head, buf[11..51]);
            git_head = head;
        }
        return DiskHeader{
            .file_count = file_count,
            .git_head = git_head,
        };
    }

    pub fn readGitHead(io: std.Io, dir_path: []const u8, allocator: std.mem.Allocator) !?[40]u8 {
        const header = try readDiskHeader(io, dir_path, allocator) orelse return null;
        return header.git_head;
    }
};
