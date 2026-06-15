//! Search, matching, path, and excerpt helpers shared by explore code.

const std = @import("std");
const nanoregex = @import("nanoregex");
const explore = @import("../explore.zig");

const Language = explore.Language;
const SearchResult = explore.SearchResult;

pub fn extractLines(content: []const u8, start: u32, end: u32, line_numbers: bool, compact: bool, language: Language, allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (line_num < start) continue;
        if (line_num > end) break;
        if (compact and isCommentOrBlank(line, language)) continue;
        if (line_numbers) {
            try w.print("{d:>5} | {s}\n", .{ line_num, line });
        } else {
            try w.print("{s}\n", .{line});
        }
    }
    return aw.toOwnedSlice();
}

/// Returns true if a line is blank or a single-line comment for the given language.
pub fn isCommentOrBlank(line: []const u8, language: Language) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    return switch (language) {
        .zig, .rust, .go_lang => std.mem.startsWith(u8, trimmed, "//"),
        .python, .ruby, .r, .shell => std.mem.startsWith(u8, trimmed, "#"),
        .hcl => std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .javascript, .typescript, .c, .cpp, .dart, .java, .kotlin, .protobuf, .mlir, .tablegen => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .svelte, .vue, .astro => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*") or std.mem.startsWith(u8, trimmed, "<!--"),
        .css => std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .scss => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .sql => std.mem.startsWith(u8, trimmed, "--") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        .fortran => std.mem.startsWith(u8, trimmed, "!"),
        .llvm_ir => std.mem.startsWith(u8, trimmed, ";"),
        else => false,
    };
}

pub fn searchInContent(path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_per_file: usize, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    if (query.len == 0 or content.len == 0 or max_per_file == 0 or max_results == 0 or result_list.items.len >= max_results) return;
    // Issue #431: bail when the query is longer than the file. Without this
    // guard, `content.len - query.len + 1` below underflows usize → integer
    // overflow panic in Debug, SIGBUS in ReleaseFast.
    if (query.len > content.len) return;
    result_list.ensureTotalCapacity(allocator, result_list.items.len + @min(max_per_file, 16)) catch {};
    const first_lower: u8 = if (query[0] >= 'A' and query[0] <= 'Z') query[0] + 32 else query[0];
    const first_upper: u8 = if (query[0] >= 'a' and query[0] <= 'z') query[0] - 32 else query[0];
    var file_hits: usize = 0;
    var pos: usize = 0;
    const end = content.len - query.len + 1;

    // Track line number incrementally.
    var current_line: u32 = 1;
    var current_line_start: usize = 0;

    // SIMD constants — 16-byte NEON/SSE vectors.
    const VW = 16;
    const Vec = @Vector(VW, u8);
    const splat_lo: Vec = @splat(first_lower);
    const splat_hi: Vec = @splat(first_upper);

    scan: while (pos < end) {
        // ── SIMD path: process full 16-byte chunks ──
        if (pos + VW <= end) {
            const chunk: Vec = content[pos..][0..VW].*;
            const eq_lo: @Vector(VW, u1) = @bitCast(chunk == splat_lo);
            const eq_hi: @Vector(VW, u1) = @bitCast(chunk == splat_hi);
            var mask: u16 = @bitCast(eq_lo | eq_hi);

            if (mask == 0) {
                pos += VW;
                continue;
            }

            // Process ALL first-byte candidates in this chunk without reloading.
            while (mask != 0) {
                const offset: usize = @ctz(mask);
                const cand = pos + offset;
                if (cand >= end) break;

                if (matchAtCaseInsensitive(content, cand, query)) {
                    // ── Match found ──
                    while (current_line_start < cand) {
                        if (simdIndexOfNewline(content, current_line_start)) |nl| {
                            if (nl < cand) {
                                current_line += 1;
                                current_line_start = nl + 1;
                            } else break;
                        } else break;
                    }
                    const line_start = current_line_start;
                    const line_end = simdIndexOfNewline(content, cand) orelse content.len;

                    const line_text = try allocator.dupe(u8, content[line_start..line_end]);
                    errdefer allocator.free(line_text);
                    const path_copy = try allocator.dupe(u8, path);
                    errdefer allocator.free(path_copy);
                    try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
                    file_hits += 1;
                    if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

                    current_line += 1;
                    current_line_start = line_end + 1;
                    pos = line_end + 1;
                    if (pos >= end) return;
                    continue :scan;
                }
                mask &= mask - 1; // clear lowest bit, try next candidate in chunk
            }
            pos += VW; // all candidates were false positives
            continue;
        }

        // ── Scalar tail for last <16 bytes ──
        const c = content[pos];
        if ((c == first_lower or c == first_upper) and matchAtCaseInsensitive(content, pos, query)) {
            while (current_line_start < pos) {
                if (simdIndexOfNewline(content, current_line_start)) |nl| {
                    if (nl < pos) {
                        current_line += 1;
                        current_line_start = nl + 1;
                    } else break;
                } else break;
            }
            const line_start = current_line_start;
            const line_end = simdIndexOfNewline(content, pos) orelse content.len;

            const line_text = try allocator.dupe(u8, content[line_start..line_end]);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{ .path = path_copy, .line_num = current_line, .line_text = line_text });
            file_hits += 1;
            if (file_hits >= max_per_file or result_list.items.len >= max_results) return;

            current_line += 1;
            current_line_start = line_end + 1;
            pos = line_end + 1;
            continue;
        }
        pos += 1;
    }
}

/// SIMD-accelerated newline search from `start` in `content`.
/// Returns index of first '\n' at or after `start`, or null.
inline fn simdIndexOfNewline(content: []const u8, start: usize) ?usize {
    const VW = 16;
    const Vec = @Vector(VW, u8);
    const splat_nl: Vec = @splat('\n');
    var pos = start;

    while (pos + VW <= content.len) {
        const chunk: Vec = content[pos..][0..VW].*;
        const eq: @Vector(VW, u1) = @bitCast(chunk == splat_nl);
        const mask: u16 = @bitCast(eq);
        if (mask != 0) return pos + @ctz(mask);
        pos += VW;
    }
    while (pos < content.len) {
        if (content[pos] == '\n') return pos;
        pos += 1;
    }
    return null;
}

pub fn extractLineByNumber(content: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0) return null;
    var line_num: u32 = 1;
    var start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            if (line_num == target_line) return content[start..i];
            line_num += 1;
            start = i + 1;
        }
    }
    if (line_num == target_line and start <= content.len) return content[start..];
    return null;
}

pub fn matchAtCaseInsensitive(content: []const u8, pos: usize, query: []const u8) bool {
    if (pos + query.len > content.len) return false;
    for (0..query.len) |j| {
        const hc = if (content[pos + j] >= 'A' and content[pos + j] <= 'Z') content[pos + j] + 32 else content[pos + j];
        const nc = if (query[j] >= 'A' and query[j] <= 'Z') query[j] + 32 else query[j];
        if (hc != nc) return false;
    }
    return true;
}

pub fn searchInContentRegex(path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    var rx = nanoregex.Regex.compile(allocator, pattern) catch return;
    defer rx.deinit();
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (rx.search(allocator, line) catch null) |m| {
            @constCast(&m).deinit(allocator);
            const line_text = try allocator.dupe(u8, line);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{
                .path = path_copy,
                .line_num = line_num,
                .line_text = line_text,
            });
            if (result_list.items.len >= max_results) return;
        }
    }
}

pub fn regexMatch(haystack: []const u8, pattern: []const u8) bool {
    var rx = nanoregex.Regex.compile(std.heap.smp_allocator, pattern) catch return false;
    defer rx.deinit();
    if (rx.search(std.heap.smp_allocator, haystack) catch null) |m| {
        @constCast(&m).deinit(std.heap.smp_allocator);
        return true;
    }
    return false;
}

pub fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Pre-compute lowered first byte + second byte for fast skip.
    const first_lower: u8 = if (needle[0] >= 'A' and needle[0] <= 'Z') needle[0] + 32 else needle[0];
    const first_upper: u8 = if (needle[0] >= 'a' and needle[0] <= 'z') needle[0] - 32 else needle[0];
    const end = haystack.len - needle.len + 1;

    if (needle.len == 1) {
        // Single-char: use std.mem.indexOfAny for speed.
        const chars = [2]u8{ first_lower, first_upper };
        return std.mem.indexOfAny(u8, haystack, &chars);
    }

    const second_lower: u8 = if (needle[1] >= 'A' and needle[1] <= 'Z') needle[1] + 32 else needle[1];

    var i: usize = 0;
    while (i < end) : (i += 1) {
        // Fast reject: check first byte, then second byte before full compare.
        const c0 = haystack[i];
        if (c0 != first_lower and c0 != first_upper) continue;
        const c1 = haystack[i + 1];
        const c1_lower = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
        if (c1_lower != second_lower) continue;

        // First two bytes match — verify the rest.
        var match = true;
        for (2..needle.len) |j| {
            const hc = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const nc = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (hc != nc) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Count non-overlapping case-insensitive occurrences of `needle` in `text`.
pub fn countOccurrences(text: []const u8, needle: []const u8) f32 {
    if (needle.len == 0 or needle.len > text.len) return 0;
    var count: f32 = 0;
    var pos: usize = 0;
    while (pos + needle.len <= text.len) {
        if (indexOfCaseInsensitive(text[pos..], needle)) |off| {
            count += 1;
            pos += off + needle.len;
        } else break;
    }
    return count;
}

/// Minimal JSON string escaper for the rerank-trace logger. Writes escaped
/// bytes into `out`, returns bytes written. Stops cleanly when `out` is full.
pub fn writeJsonEscaped(out: []u8, input: []const u8) usize {
    var w: usize = 0;
    for (input) |c| {
        if (w >= out.len) break;
        switch (c) {
            '"' => {
                if (w + 2 > out.len) break;
                out[w] = '\\';
                out[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                if (w + 2 > out.len) break;
                out[w] = '\\';
                out[w + 1] = '\\';
                w += 2;
            },
            '\n', '\r', '\t' => {
                out[w] = ' ';
                w += 1;
            },
            else => {
                if (c < 0x20) continue;
                out[w] = c;
                w += 1;
            },
        }
    }
    return w;
}

pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

pub fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) continue :outer;
        }
        return true;
    }
    return false;
}

pub fn pathHasSegment(path: []const u8, segment: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, segment)) return true;
    }
    return false;
}

pub fn pathHasSegmentIgnoreCase(path: []const u8, segment: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |seg| {
        if (asciiEqlIgnoreCase(seg, segment)) return true;
    }
    return false;
}

pub fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn isWordBoundary(path: []const u8, pi: usize) bool {
    if (pi == 0) return true;
    const prev = path[pi - 1];
    return prev == '/' or prev == '_' or prev == '-' or prev == '.' or prev == '\\';
}

pub fn isSpecialEntryPoint(filename: []const u8) bool {
    const specials = [_][]const u8{
        "main.zig",     "lib.zig",     "root.zig",
        "main.rs",      "lib.rs",      "mod.rs",
        "main.go",      "main.c",      "main.cpp",
        "index.ts",     "index.tsx",   "index.js",
        "index.jsx",    "index.mjs",   "index.cjs",
        "index.vue",    "index.php",   "main.rb",
        "index.rb",     "__init__.py", "__main__.py",
        "Makefile",     "build.zig",   "Cargo.toml",
        "package.json",
    };
    for (specials) |s| {
        if (std.mem.eql(u8, filename, s)) return true;
    }
    return false;
}

pub fn getFilename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

pub fn fuzzyScore(query: []const u8, path: []const u8) ?f32 {
    if (query.len == 0 or path.len == 0) return null;
    if (query.len > 128 or path.len > 512) return null;

    const MATCH_SCORE: f32 = 16.0;
    const MISMATCH_PENALTY: f32 = -8.0;
    const GAP_OPEN: f32 = -3.0;
    const GAP_EXTEND: f32 = -1.0;
    const DELIMITER_BONUS: f32 = 8.0;
    const FILENAME_BONUS: f32 = 6.0;
    const CONSECUTIVE_BONUS: f32 = 4.0;
    const CASE_BONUS: f32 = 2.0;
    const PREFIX_BONUS: f32 = 6.0;

    // Find filename start
    var fname_start: usize = 0;
    for (0..path.len) |i| {
        if (path[path.len - 1 - i] == '/') {
            fname_start = path.len - i;
            break;
        }
    }

    // Smith-Waterman-style DP with affine gaps
    // H[i][j] = best alignment score ending with query[0..i] aligned to path[0..j]
    // We use two rows to save memory: prev and curr
    const MAX_PATH = 512;
    var prev_h: [MAX_PATH + 1]f32 = undefined;
    var curr_h: [MAX_PATH + 1]f32 = undefined;
    var prev_gap: [MAX_PATH + 1]f32 = undefined; // gap in query (deletion from path)
    var curr_gap: [MAX_PATH + 1]f32 = undefined;

    // Init
    for (0..path.len + 1) |j| {
        prev_h[j] = 0;
        prev_gap[j] = GAP_OPEN;
    }

    var best_score: f32 = 0;
    var matched_chars: usize = 0;

    for (0..query.len) |i| {
        curr_h[0] = 0;
        curr_gap[0] = GAP_OPEN;
        var query_gap: f32 = GAP_OPEN; // gap in path (deletion from query)

        for (0..path.len) |j| {
            const qc = toLowerByte(query[i]);
            const pc = toLowerByte(path[j]);

            // Match/mismatch score
            var match_score: f32 = if (qc == pc) MATCH_SCORE else MISMATCH_PENALTY;

            // Bonuses for matches
            if (qc == pc) {
                // Exact case bonus
                if (query[i] == path[j]) match_score += CASE_BONUS;
                // Word boundary bonus
                if (isWordBoundary(path, j)) match_score += DELIMITER_BONUS;
                // Filename bonus
                if (j >= fname_start) match_score += FILENAME_BONUS;
                // Prefix bonus (match at start of path or filename)
                if (j == 0 or j == fname_start) match_score += PREFIX_BONUS;
                // Consecutive match bonus
                if (i > 0 and j > 0 and prev_h[j] > prev_h[j + 1] * 0.5) {
                    match_score += CONSECUTIVE_BONUS;
                }
            }

            const diag = prev_h[j] + match_score;

            // Affine gap penalties
            curr_gap[j + 1] = @max(prev_h[j + 1] + GAP_OPEN, prev_gap[j + 1] + GAP_EXTEND);
            query_gap = @max(curr_h[j] + GAP_OPEN, query_gap + GAP_EXTEND);

            // Smith-Waterman: take max of all options, floor at 0
            curr_h[j + 1] = @max(0, @max(diag, @max(curr_gap[j + 1], query_gap)));

            if (i == query.len - 1 and curr_h[j + 1] > best_score) {
                best_score = curr_h[j + 1];
            }
        }

        // Count matched chars (check if any cell in this row is positive)
        for (1..path.len + 1) |j| {
            if (curr_h[j] > 0) {
                matched_chars = i + 1;
                break;
            }
        }

        // Swap rows
        @memcpy(prev_h[0 .. path.len + 1], curr_h[0 .. path.len + 1]);
        @memcpy(prev_gap[0 .. path.len + 1], curr_gap[0 .. path.len + 1]);
    }

    // Require at least 60% of query chars to contribute to score
    if (best_score <= 0 or matched_chars < (query.len + 1) / 2) return null;

    // Minimum score threshold based on query length
    const min_threshold = @as(f32, @floatFromInt(query.len)) * MATCH_SCORE * 0.3;
    if (best_score < min_threshold) return null;

    // Special entry point bonus (like fff: main.go, index.ts, lib.rs rank higher)
    const fname = getFilename(path);
    if (isSpecialEntryPoint(fname)) best_score += best_score * 0.05;

    // Issue #363b: an exact basename match must rank above fuzzy matches in
    // the same tree. Without this, a query of `cli.rs` against a workspace
    // containing several `lib.rs` files returned the `lib.rs` files first
    // because the special-entry-point bonus + length normalization outweighed
    // the imperfect fuzzy alignment of `cli.rs` against `lib.rs`.
    if (std.ascii.eqlIgnoreCase(query, fname)) {
        best_score *= 4.0;
    } else {
        // Boost exact substring matches in the filename. This makes "portolio"
        // rank mycredopro.portolio.marketdata.js above Portfolio.cs, because
        // the fuzzy aligner prefers the shorter "Portfolio" match but the user
        // typed the exact substring that appears in the longer filename.
        if (fname.len >= query.len and containsAsciiIgnoreCase(fname, query)) {
            best_score *= 2.5;
        }
    }

    // Normalize by path length (shorter paths rank higher)
    const len_factor = @sqrt(@as(f32, @floatFromInt(path.len)));
    return best_score / len_factor;
}

/// Case-insensitive substring search. Returns true if `needle` appears in `haystack`.
fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
