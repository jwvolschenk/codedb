const std = @import("std");
const normalizeChar = @import("chars.zig").normalizeChar;
const freq = @import("frequency.zig");
const MAX_NGRAM_LEN = freq.MAX_NGRAM_LEN;
const pairWeight = freq.pairWeight;

/// A single sparse n-gram extracted from a string.
pub const SparseNgram = struct {
    hash: u64, // Wyhash of the normalized (lowercased) n-gram bytes
    pos: usize, // byte offset in the source string
    len: usize, // byte length of the n-gram
};

fn makeNgram(content: []const u8, pos: usize, len: usize) SparseNgram {
    var buf: [MAX_NGRAM_LEN]u8 = undefined;
    for (0..len) |k| buf[k] = normalizeChar(content[pos + k]);
    return .{
        .hash = std.hash.Wyhash.hash(0, buf[0..len]),
        .pos = pos,
        .len = len,
    };
}

/// Extract sparse n-grams from `content` using content-defined boundaries.
///
/// Boundaries are placed at strict local maxima of pairWeight over the
/// normalized character pairs.  N-grams span consecutive boundaries; spans
/// wider than MAX_NGRAM_LEN are force-split into MAX_NGRAM_LEN chunks.
/// Minimum n-gram length is 3 (same as a trigram).
///
/// Caller owns the returned slice.
pub fn extractSparseNgrams(content: []const u8, allocator: std.mem.Allocator) ![]SparseNgram {
    const MIN_LEN = 3;
    if (content.len < MIN_LEN) return try allocator.alloc(SparseNgram, 0);

    const pair_count = content.len - 1;

    // Compute pair weights.
    const weights = try allocator.alloc(u16, pair_count);
    defer allocator.free(weights);
    for (0..pair_count) |i| {
        weights[i] = pairWeight(normalizeChar(content[i]), normalizeChar(content[i + 1]));
    }

    // Collect boundary pair-positions: always include 0 and pair_count-1,
    // plus any interior strict local maximum.
    var bounds: std.ArrayList(usize) = .empty;
    defer bounds.deinit(allocator);

    try bounds.append(allocator, 0);
    if (pair_count >= 3) {
        for (1..pair_count - 1) |i| {
            if (weights[i] > weights[i - 1] and weights[i] > weights[i + 1]) {
                try bounds.append(allocator, i);
            }
        }
    }
    try bounds.append(allocator, pair_count - 1);

    // Emit n-grams spanning consecutive boundary positions.
    // N-gram for boundary pair at position p covers content[p .. p+2].
    var result: std.ArrayList(SparseNgram) = .empty;
    errdefer result.deinit(allocator);

    var b: usize = 0;
    while (b + 1 < bounds.items.len) : (b += 1) {
        const start = bounds.items[b];
        const end_pair = bounds.items[b + 1];
        // The right-hand boundary pair covers content[end_pair .. end_pair+2].
        const ngram_end = end_pair + 2;
        const ngram_len = ngram_end - start;

        if (ngram_len < MIN_LEN) continue;

        if (ngram_len <= MAX_NGRAM_LEN) {
            try result.append(allocator, makeNgram(content, start, ngram_len));
        } else {
            // Force-split into MAX_NGRAM_LEN-sized chunks.
            var off = start;
            while (off + MAX_NGRAM_LEN <= ngram_end) {
                try result.append(allocator, makeNgram(content, off, MAX_NGRAM_LEN));
                off += MAX_NGRAM_LEN;
            }
            const rem = ngram_end - off;
            if (rem >= MIN_LEN) {
                try result.append(allocator, makeNgram(content, off, rem));
            } else if (rem > 0) {
                // Tail is too short for its own ngram.  Overlap with the
                // previous chunk by backing up to ngram_end - MIN_LEN so
                // every byte in the span is covered.
                try result.append(allocator, makeNgram(content, ngram_end - MIN_LEN, MIN_LEN));
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Build the covering set of n-gram hashes for a query using a sliding window.
/// Extracts every substring of the query with length in [3, MAX_NGRAM_LEN] so
/// that file boundary-based n-grams overlapping the query are matched regardless
/// of where content-defined boundaries fall in the indexed file.
/// Caller owns the returned slice.
pub fn buildCoveringSet(query: []const u8, allocator: std.mem.Allocator) ![]SparseNgram {
    const MIN_LEN = 3;
    if (query.len < MIN_LEN) return try allocator.alloc(SparseNgram, 0);

    var result: std.ArrayList(SparseNgram) = .empty;
    errdefer result.deinit(allocator);

    // Slide a window of every length [MIN_LEN, MAX_NGRAM_LEN] across the query.
    // This avoids boundary-misalignment false negatives when a query substring
    // appears in the indexed file as a content-defined boundary n-gram.
    var len: usize = MIN_LEN;
    while (len <= @min(MAX_NGRAM_LEN, query.len)) : (len += 1) {
        var pos: usize = 0;
        while (pos + len <= query.len) : (pos += 1) {
            try result.append(allocator, makeNgram(query, pos, len));
        }
    }

    return result.toOwnedSlice(allocator);
}

/// In-memory sparse n-gram index.  Mirrors the TrigramIndex API so it can
/// be used as a drop-in acceleration layer alongside the trigram index.
pub const SparseNgramIndex = struct {
    /// ngram hash → set of file paths that contain the n-gram
    index: std.AutoHashMap(u64, std.StringHashMap(void)),
    /// path → list of ngram hashes contributed (for cleanup on re-index)
    file_ngrams: std.StringHashMap(std.ArrayList(u64)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SparseNgramIndex {
        return .{
            .index = std.AutoHashMap(u64, std.StringHashMap(void)).init(allocator),
            .file_ngrams = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SparseNgramIndex) void {
        var iter = self.index.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.index.deinit();

        var fn_iter = self.file_ngrams.iterator();
        while (fn_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_ngrams.deinit();
    }

    pub fn removeFile(self: *SparseNgramIndex, path: []const u8) void {
        const ngrams = self.file_ngrams.getPtr(path) orelse return;
        for (ngrams.items) |hash| {
            if (self.index.getPtr(hash)) |file_set| {
                _ = file_set.remove(path);
                if (file_set.count() == 0) {
                    file_set.deinit();
                    _ = self.index.remove(hash);
                }
            }
        }
        ngrams.deinit(self.allocator);
        _ = self.file_ngrams.remove(path);
    }

    pub fn indexFile(self: *SparseNgramIndex, path: []const u8, content: []const u8) !void {
        self.removeFile(path);

        const ngrams = try extractSparseNgrams(content, self.allocator);
        defer self.allocator.free(ngrams);

        // Deduplicate hashes so the cleanup list stays compact.
        var seen = std.AutoHashMap(u64, void).init(self.allocator);
        defer seen.deinit();

        for (ngrams) |ng| {
            const gop = try self.index.getOrPut(ng.hash);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            _ = try gop.value_ptr.getOrPut(path);
            _ = try seen.getOrPut(ng.hash);
        }

        var hash_list: std.ArrayList(u64) = .empty;
        errdefer hash_list.deinit(self.allocator);
        var seen_iter = seen.keyIterator();
        while (seen_iter.next()) |h| {
            try hash_list.append(self.allocator, h.*);
        }
        try self.file_ngrams.put(path, hash_list);
    }

    /// Find candidate files that may contain the query string.
    /// Uses the sliding-window covering set from buildCoveringSet and returns
    /// the UNION of all matching posting lists — a superset of true matches,
    /// to be verified by content search.  Returns null when the query is too
    /// short.  Caller must free the returned slice.
    pub fn candidates(self: *SparseNgramIndex, query: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        const ngrams = buildCoveringSet(query, allocator) catch return null;
        defer allocator.free(ngrams);

        if (ngrams.len == 0) return null;

        // Union posting sets for all sliding-window n-gram hashes.
        // A file is a candidate if it shares any substring with the query.
        var seen_files = std.StringHashMap(void).init(allocator);
        defer seen_files.deinit();

        for (ngrams) |ng| {
            const file_set = self.index.getPtr(ng.hash) orelse continue;
            var it = file_set.keyIterator();
            while (it.next()) |path_ptr| {
                seen_files.put(path_ptr.*, {}) catch return null;
            }
        }

        if (seen_files.count() == 0) {
            return allocator.alloc([]const u8, 0) catch null;
        }

        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(allocator);
        result.ensureTotalCapacity(allocator, seen_files.count()) catch return null;

        var file_it = seen_files.keyIterator();
        while (file_it.next()) |path_ptr| {
            result.appendAssumeCapacity(path_ptr.*);
        }

        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    pub fn fileCount(self: *SparseNgramIndex) u32 {
        return @intCast(self.file_ngrams.count());
    }
};
