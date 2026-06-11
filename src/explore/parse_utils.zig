// codedb — language-agnostic parsing / string / path / fuzzy helpers.
// Free functions split out of explore.zig (Explorer methods stay there).

const std = @import("std");
const nanoregex = @import("nanoregex");
const csharp_parser = @import("../csharp_parser.zig");
const fsharp_parser = @import("../fsharp_parser.zig");
const explore = @import("../explore.zig");
const SymbolKind = explore.SymbolKind;
const Symbol = explore.Symbol;
const Language = explore.Language;
const FileOutline = explore.FileOutline;
const SearchResult = explore.SearchResult;

pub fn phpNamespaceToPath(allocator: std.mem.Allocator, ns: []const u8) ![]u8 {
    var parts: std.ArrayList(u8) = .empty;
    errdefer parts.deinit(allocator);

    var first_segment = true;
    var iter = std.mem.splitScalar(u8, ns, '\\');
    while (iter.next()) |segment| {
        if (parts.items.len > 0) {
            try parts.append(allocator, '/');
        }
        if (first_segment) {
            for (segment) |ch| {
                try parts.append(allocator, std.ascii.toLower(ch));
            }
            first_segment = false;
        } else {
            try parts.appendSlice(allocator, segment);
        }
    }
    try parts.appendSlice(allocator, ".php");
    return try parts.toOwnedSlice(allocator);
}

/// Extract lines from content string as a range [start..end] (1-indexed, inclusive).
/// When line_numbers is true, prepends "{d:>5} | " prefix. When compact is true,
/// skips comment/blank lines based on language.
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
pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

pub fn appendOutlineSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_num: u32,
    detail: []const u8,
) !void {
    return appendOutlineSymbolWithTypes(allocator, outline, name, kind, line_num, detail, null, &.{});
}

pub fn appendOutlineSymbolWithTypes(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_num: u32,
    detail: []const u8,
    return_type: ?[]const u8,
    param_types: []const []const u8,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const detail_copy = try allocator.dupe(u8, detail);
    errdefer allocator.free(detail_copy);
    const rt_copy: ?[]const u8 = if (return_type) |rt| try allocator.dupe(u8, rt) else null;
    errdefer if (rt_copy) |rt| allocator.free(rt);
    const pt_copy = try allocator.dupe([]const u8, param_types);
    errdefer allocator.free(pt_copy);
    for (param_types, 0..) |pt, i| {
        pt_copy[i] = try allocator.dupe(u8, pt);
        errdefer for (pt_copy[0..i]) |p| allocator.free(p);
    }
    try outline.symbols.append(allocator, .{
        .name = name_copy,
        .kind = kind,
        .line_start = line_num,
        .line_end = line_num,
        .detail = detail_copy,
        .return_type = rt_copy,
        .param_types = pt_copy,
    });
}

pub fn appendImportSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    import_path: []const u8,
    line_num: u32,
    detail: []const u8,
) !void {
    try appendOutlineSymbol(allocator, outline, import_path, .import, line_num, detail);
    const import_copy = try allocator.dupe(u8, import_path);
    errdefer allocator.free(import_copy);
    try outline.imports.append(allocator, import_copy);
}

pub fn cSharpSymbolKind(kind: csharp_parser.Kind) SymbolKind {
    return switch (kind) {
        .class_def => .class_def,
        .interface_def => .interface_def,
        .enum_def => .enum_def,
        .struct_def => .struct_def,
        .function => .function,
        .method => .method,
        .variable => .variable,
        .constant => .constant,
        .type_alias => .type_alias,
    };
}

pub fn fSharpSymbolKind(kind: fsharp_parser.Kind) SymbolKind {
    return switch (kind) {
        .class_def => .class_def,
        .interface_def => .interface_def,
        .enum_def => .enum_def,
        .struct_def => .struct_def,
        .function => .function,
        .method => .method,
        .variable => .variable,
        .constant => .constant,
        .type_alias => .type_alias,
    };
}

pub fn extractIdent(s: []const u8) ?[]const u8 {
    const max_ident_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_ident_len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    return if (end > 0) s[0..end] else null;
}

pub fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

pub fn extractIdentAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, keyword)) |pos| {
        if (pos > 0 and isIdentChar(line[pos - 1])) {
            start = pos + 1;
            continue;
        }
        return extractIdent(std.mem.trimStart(u8, line[pos + keyword.len ..], " \t"));
    }
    return null;
}

pub fn extractIdentAfterKeywordIgnoreCase(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (indexOfCaseInsensitive(line, keyword)) |pos| {
        if (pos > 0 and isIdentChar(line[pos - 1])) return null;
        return extractIdent(std.mem.trimStart(u8, line[pos + keyword.len ..], " \t"));
    }
    return null;
}

pub fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(p)) return false;
    }
    return true;
}

pub fn parseDelimitedImport(line: []const u8, prefix: []const u8, delimiter: []const u8) ?[]const u8 {
    if (!startsWith(line, prefix)) return null;
    var body = std.mem.trim(u8, line[prefix.len..], " \t;");
    if (startsWith(body, "static ")) body = std.mem.trimStart(u8, body["static ".len..], " \t");
    if (delimiter.len > 0) {
        if (std.mem.indexOf(u8, body, delimiter)) |end| body = body[0..end];
    }
    body = std.mem.trim(u8, body, " \t;");
    return if (body.len > 0) body else null;
}

pub fn extractJvmMethodName(line: []const u8) ?[]const u8 {
    if (startsWith(line, "import ") or startsWith(line, "package ") or startsWith(line, "return ") or
        startsWith(line, "throw ") or startsWith(line, "new "))
        return null;
    if (std.mem.indexOf(u8, line, " class ") != null or std.mem.indexOf(u8, line, " interface ") != null or
        std.mem.indexOf(u8, line, " enum ") != null or std.mem.indexOf(u8, line, " record ") != null)
        return null;
    const open = std.mem.lastIndexOfScalar(u8, line, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, line[open..], ')') == null) return null;
    const before = std.mem.trimEnd(u8, line[0..open], " \t");
    const span = extractLastIdentSpan(before) orelse return null;
    const name = span.text;
    if (isControlKeyword(name)) return null;
    const before_name = std.mem.trim(u8, before[0..span.start], " \t");
    if (before_name.len == 0) return null;
    if (std.mem.endsWith(u8, before_name, ".") or std.mem.endsWith(u8, before_name, "->") or
        std.mem.endsWith(u8, before_name, "="))
        return null;
    return name;
}

pub fn isControlKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{ "if", "for", "while", "switch", "catch", "return", "throw", "new", "when" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

pub fn firstShellWord(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != ';') : (end += 1) {}
    return if (end > 0) trimmed[0..end] else null;
}

pub fn parseShellAssignment(line: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (eq == 0 or std.mem.indexOfAny(u8, line[0..eq], " \t$") != null) return null;
    return extractIdent(line[0..eq]);
}

pub fn parseCssVariable(line: []const u8) ?[]const u8 {
    if (startsWith(line, "$")) {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| return line[0..colon];
    }
    if (startsWith(line, "--")) {
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| return line[0..colon];
    }
    return null;
}

pub fn parseCssSelector(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    if (line.len < 2 or (line[0] != '.' and line[0] != '#')) return null;
    var end: usize = 1;
    while (end < line.len) : (end += 1) {
        const ch = line[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) break;
    }
    return if (end > 1) line[0..end] else null;
}

pub fn stripSqlLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "--")) return "";
    if (std.mem.indexOf(u8, trimmed, "--")) |pos| return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    return trimmed;
}

pub const SqlSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
};

pub fn parseSqlCreate(line: []const u8) ?SqlSymbol {
    if (!startsWithIgnoreCase(line, "create ")) return null;
    var rest = std.mem.trimStart(u8, line["create ".len..], " \t");
    if (startsWithIgnoreCase(rest, "or replace ")) rest = std.mem.trimStart(u8, rest["or replace ".len..], " \t");
    if (parseSqlCreateKind(rest, "table ", .struct_def)) |sym| return sym;
    if (parseSqlCreateKind(rest, "view ", .struct_def)) |sym| return sym;
    if (parseSqlCreateKind(rest, "index ", .constant)) |sym| return sym;
    if (parseSqlCreateKind(rest, "function ", .function)) |sym| return sym;
    if (parseSqlCreateKind(rest, "procedure ", .function)) |sym| return sym;
    if (parseSqlCreateKind(rest, "trigger ", .method)) |sym| return sym;
    if (parseSqlCreateKind(rest, "type ", .type_alias)) |sym| return sym;
    return null;
}

pub fn parseSqlCreateKind(rest: []const u8, keyword: []const u8, kind: SymbolKind) ?SqlSymbol {
    if (!startsWithIgnoreCase(rest, keyword)) return null;
    var body = std.mem.trimStart(u8, rest[keyword.len..], " \t");
    if (startsWithIgnoreCase(body, "if not exists ")) body = std.mem.trimStart(u8, body["if not exists ".len..], " \t");
    const name = firstSqlIdent(body) orelse return null;
    return .{ .name = name, .kind = kind };
}

pub fn firstSqlIdent(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t\"`[");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and
        trimmed[end] != '(' and trimmed[end] != ';' and trimmed[end] != '"' and
        trimmed[end] != '`' and trimmed[end] != ']') : (end += 1)
    {}
    if (end == 0) return null;
    const raw = trimmed[0..end];
    if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| {
        if (dot + 1 < raw.len) return raw[dot + 1 ..];
    }
    return raw;
}

pub fn stripFortranComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "!")) return "";
    if (std.mem.indexOfScalar(u8, trimmed, '!')) |pos| return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    return trimmed;
}

pub fn parseFortranUse(line: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, "use ")) return null;
    var rest = std.mem.trimStart(u8, line[4..], " \t");
    if (startsWithIgnoreCase(rest, "intrinsic")) return null;
    if (std.mem.indexOf(u8, rest, "::")) |pos| rest = std.mem.trimStart(u8, rest[pos + 2 ..], " \t");
    return extractIdent(rest);
}

pub fn parseFortranTypeName(line: []const u8) ?[]const u8 {
    if (!startsWithIgnoreCase(line, "type")) return null;
    const sep = std.mem.indexOf(u8, line, "::") orelse return null;
    return extractIdent(std.mem.trimStart(u8, line[sep + 2 ..], " \t"));
}

pub fn extractAtName(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, line, '@') orelse return null;
    return extractLlvmLikeName(line[at + 1 ..]);
}

pub fn extractLlvmGlobalName(line: []const u8) ?[]const u8 {
    if (line.len == 0 or (line[0] != '@' and line[0] != '%')) return null;
    return extractLlvmLikeName(line[1..]);
}

pub fn extractLlvmLikeName(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s[0] == '"') {
        if (std.mem.indexOfScalar(u8, s[1..], '"')) |end| return s[1 .. end + 1];
        return null;
    }
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const ch = s[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.' or ch == '$')) break;
    }
    return if (end > 0) s[0..end] else null;
}

pub const IdentSpan = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

pub fn extractLastIdentSpan(s: []const u8) ?IdentSpan {
    if (s.len == 0) return null;

    var end = s.len;
    while (end > 0) {
        const ch = s[end - 1];
        if (std.ascii.isAlphanumeric(ch) or ch == '_') break;
        end -= 1;
    }
    if (end == 0) return null;

    var start = end;
    while (start > 0) {
        const ch = s[start - 1];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
        start -= 1;
    }
    return .{ .text = s[start..end], .start = start, .end = end };
}

pub fn extractLastIdent(s: []const u8) ?[]const u8 {
    return if (extractLastIdentSpan(s)) |span| span.text else null;
}

pub fn stripLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (startsWith(trimmed, "//")) return "";
    if (std.mem.indexOf(u8, trimmed, "//")) |pos| {
        return std.mem.trimEnd(u8, trimmed[0..pos], " \t");
    }
    return trimmed;
}

pub fn extractCIncludePath(line: []const u8) ?[]const u8 {
    const keyword = if (startsWith(line, "#include"))
        "#include"
    else if (startsWith(line, "#import"))
        "#import"
    else
        return null;
    const rest = std.mem.trimStart(u8, line[keyword.len..], " \t");
    if (rest.len >= 2 and rest[0] == '<') {
        if (std.mem.indexOfScalar(u8, rest[1..], '>')) |end| {
            if (end == 0) return null;
            return rest[1 .. end + 1];
        }
    }
    return extractStringLiteral(rest);
}

pub const CTypeSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
};

pub fn parseCNamedType(line: []const u8) ?CTypeSymbol {
    const stripped = stripCAttributesPrefix(line);
    if (startsWith(stripped, "typedef ")) {
        const rest = std.mem.trimStart(u8, stripped["typedef ".len..], " \t");
        if (parseCBraceType(rest)) |sym| return sym;
        if (std.mem.indexOf(u8, rest, "(*") != null) return null;
        if (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
            const before_semi = rest[0..semi];
            if (extractLastIdent(before_semi)) |name| {
                if (!isCKeyword(name)) return .{ .name = name, .kind = .type_alias };
            }
        }
        return null;
    }
    return parseCBraceType(stripped);
}

pub fn parseCBraceType(line: []const u8) ?CTypeSymbol {
    if (std.mem.indexOfScalar(u8, line, '{') == null) return null;
    if (startsWith(line, "class ")) {
        return parseCTypeAfterKeyword(line["class ".len..], .class_def);
    }
    if (startsWith(line, "struct ")) {
        return parseCTypeAfterKeyword(line["struct ".len..], .struct_def);
    }
    if (startsWith(line, "enum ")) {
        return parseCTypeAfterKeyword(line["enum ".len..], .enum_def);
    }
    if (startsWith(line, "union ")) {
        return parseCTypeAfterKeyword(line["union ".len..], .union_def);
    }
    return null;
}

pub fn parseCTypeAfterKeyword(rest: []const u8, kind: SymbolKind) ?CTypeSymbol {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len == 0 or trimmed[0] == '{') return null;
    if (extractIdent(trimmed)) |name| {
        if (!isCKeyword(name)) return .{ .name = name, .kind = kind };
    }
    return null;
}

pub fn parseObjCType(line: []const u8) ?CTypeSymbol {
    if (startsWith(line, "@interface ")) {
        return parseCTypeAfterKeyword(line["@interface ".len..], .class_def);
    }
    if (startsWith(line, "@implementation ")) {
        return parseCTypeAfterKeyword(line["@implementation ".len..], .class_def);
    }
    if (startsWith(line, "@protocol ")) {
        return parseCTypeAfterKeyword(line["@protocol ".len..], .interface_def);
    }
    return null;
}

pub fn extractObjCMethodName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "- (") and !startsWith(line, "+ (")) return null;
    const close = std.mem.indexOfScalar(u8, line, ')') orelse return null;
    const rest = std.mem.trimStart(u8, line[close + 1 ..], " \t*");
    return extractIdent(rest);
}

pub fn extractCFunctionName(line: []const u8, at_col0: bool, prev_trimmed: []const u8, brace_depth: u32, is_cpp: bool) ?[]const u8 {
    // Anything inside a function body is a call site, not a definition.
    // C: depth 0 = file scope. Any depth >= 1 means inside a function body.
    // C++: depth 0 = file scope, depth 1 = class/struct body (methods allowed).
    //      Depth >= 2 means inside a function body.
    const max_depth: u32 = if (is_cpp) 1 else 0;
    if (brace_depth > max_depth) return null;

    const stripped = stripCAttributesPrefix(line);
    if (stripped.len == 0 or stripped[0] == '#') return null;
    if (startsWith(stripped, "typedef ")) return null;
    if (std.mem.indexOfScalar(u8, stripped, ';') != null) return null;

    const search_end = std.mem.indexOfScalar(u8, stripped, '{') orelse stripped.len;
    if (search_end == 0) return null;
    const signature = std.mem.trimEnd(u8, stripped[0..search_end], " \t");
    const open_paren = std.mem.lastIndexOfScalar(u8, signature, '(') orelse return null;
    if (std.mem.indexOfScalar(u8, signature[open_paren..], ')') == null) return null;
    if (std.mem.indexOf(u8, signature, "(*") != null) return null;

    const before_paren = std.mem.trimEnd(u8, signature[0..open_paren], " \t");
    const span = extractLastIdentSpan(before_paren) orelse return null;
    const name = span.text;
    if (isCKeyword(name)) return null;

    const before_name = std.mem.trim(u8, before_paren[0..span.start], " \t*(&");
    if (before_name.len == 0) {
        // nginx-style: return type on previous line, function name starts this line.
        // Accept only if at column 0 and prev line looks like a type (identifier,
        // optionally preceded by storage qualifiers), not a statement or brace.
        if (!at_col0) return null;
        if (prev_trimmed.len == 0) return null;
        if (prev_trimmed[0] == '{' or prev_trimmed[0] == '}' or
            prev_trimmed[0] == '(' or prev_trimmed[0] == ')')
            return null;
        if (std.mem.indexOfScalar(u8, prev_trimmed, ';') != null) return null;
        if (std.mem.indexOfScalar(u8, prev_trimmed, '(') != null) return null;
        if (isCForbiddenFunctionPrefix(prev_trimmed)) return null;
        // prev line must start with an identifier (a type name or qualifier)
        if (extractIdent(std.mem.trimStart(u8, prev_trimmed, " \t*")) == null) return null;
        return name;
    }
    if (!at_col0 and !looksLikeCMethodDef(before_name)) return null;
    if (hasCAssignmentBeforeName(before_name)) return null;
    if (isCForbiddenFunctionPrefix(before_name)) return null;
    if (std.mem.endsWith(u8, before_name, ".") or std.mem.endsWith(u8, before_name, "->")) return null;

    return name;
}

pub fn countChar(s: []const u8, ch: u8) u32 {
    var n: u32 = 0;
    for (s) |c| if (c == ch) {
        n += 1;
    };
    return n;
}

pub fn applyBraceDelta(depth: *u32, delta: i32) void {
    if (delta >= 0) {
        depth.* +|= @intCast(delta);
    } else {
        const sub: u32 = @intCast(-delta);
        depth.* -|= sub;
    }
}

pub fn countBracesDelta(line: []const u8) i32 {
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' or ch == '\'') {
            const q = ch;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (line[i] == q) break;
            }
        } else if (ch == '{') {
            delta += 1;
        } else if (ch == '}') {
            delta -= 1;
        }
    }
    return delta;
}

pub fn looksLikeCMethodDef(before_name: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, before_name, " \t*(&");
    const first = extractIdent(trimmed) orelse return false;
    return !isCKeyword(first) and !std.mem.eql(u8, first, "return") and
        !std.mem.eql(u8, first, "case");
}

pub fn stripCAttributesPrefix(line: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (startsWith(rest, "__attribute__((")) {
        if (std.mem.indexOf(u8, rest, "))")) |end| {
            rest = std.mem.trimStart(u8, rest[end + 2 ..], " \t");
        } else break;
    }
    return rest;
}

pub fn hasCAssignmentBeforeName(prefix: []const u8) bool {
    for (prefix, 0..) |ch, i| {
        if (ch != '=') continue;
        const prev = if (i > 0) prefix[i - 1] else 0;
        const next = if (i + 1 < prefix.len) prefix[i + 1] else 0;
        if (prev == '=' or prev == '!' or prev == '<' or prev == '>' or next == '=') continue;
        return true;
    }
    return false;
}

pub fn isCForbiddenFunctionPrefix(prefix: []const u8) bool {
    const first = extractIdent(std.mem.trimStart(u8, prefix, " \t*(&")) orelse return false;
    return std.mem.eql(u8, first, "return") or
        std.mem.eql(u8, first, "case") or
        std.mem.eql(u8, first, "sizeof") or
        std.mem.eql(u8, first, "if") or
        std.mem.eql(u8, first, "for") or
        std.mem.eql(u8, first, "while") or
        std.mem.eql(u8, first, "switch");
}

pub fn isCKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{
        "if",       "for",      "while",  "switch", "return",   "sizeof",
        "case",     "do",       "else",   "struct", "enum",     "union",
        "typedef",  "static",   "extern", "inline", "const",    "volatile",
        "register", "restrict", "auto",   "break",  "continue",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, s, kw)) return true;
    }
    return false;
}

pub fn firstIndexOfAny(s: []const u8, chars: []const u8) ?usize {
    for (s, 0..) |ch, pos| {
        for (chars) |needle| {
            if (ch == needle) return pos;
        }
    }
    return null;
}

/// Extract a Ruby method name — supports trailing ?, !, = characters
pub fn extractRubyMethodName(s: []const u8) ?[]const u8 {
    const max_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    if (end > 0 and end < s.len) {
        const suffix = s[end];
        if (suffix == '?' or suffix == '!' or suffix == '=') end += 1;
    }
    return if (end > 0) s[0..end] else null;
}

pub fn extractHclQuotedName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"') return null;
    if (std.mem.indexOfScalar(u8, trimmed[1..], '"')) |end| {
        if (end == 0) return null;
        return trimmed[1 .. end + 1];
    }
    return null;
}

pub fn extractHclBlockName(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"') return null;
    // Skip first quoted string
    if (std.mem.indexOfScalar(u8, trimmed[1..], '"')) |end1| {
        const after_first = trimmed[end1 + 2 ..];
        const rest = std.mem.trimStart(u8, after_first, " \t");
        // Extract second quoted string (the name)
        if (rest.len >= 2 and rest[0] == '"') {
            if (std.mem.indexOfScalar(u8, rest[1..], '"')) |end2| {
                if (end2 == 0) return null;
                return rest[1 .. end2 + 1];
            }
        }
    }
    return null;
}

pub fn extractStringLiteral(s: []const u8) ?[]const u8 {
    const quote_chars = [_]u8{ '"', '\'' };
    for (quote_chars) |q| {
        if (std.mem.indexOfScalar(u8, s, q)) |start_pos| {
            if (std.mem.indexOfScalarPos(u8, s, start_pos + 1, q)) |end_pos| {
                return s[start_pos + 1 .. end_pos];
            }
        }
    }
    return null;
}

pub fn normalizePath(path: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitSequence(u8, path, "/");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else {
                return null;
            }
        } else {
            parts.append(allocator, part) catch return null;
        }
    }

    if (parts.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) buf.append(allocator, '/') catch return null;
        buf.appendSlice(allocator, part) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

pub fn resolveDartImport(raw: []const u8, file_path: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (std.mem.startsWith(u8, raw, "dart:")) return null;

    if (std.mem.startsWith(u8, raw, "package:")) {
        return allocator.dupe(u8, raw) catch null;
    }

    const dir = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |sep|
        file_path[0..sep]
    else
        ".";
    const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, raw }) catch return null;
    const result = normalizePath(joined, allocator);
    allocator.free(joined);
    return result;
}

pub fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, s, needle) != null) return true;
    }
    return false;
}

pub fn skipKeywords(s: []const u8) []const u8 {
    const keywords = [_][]const u8{ "export ", "default ", "async ", "abstract ", "function ", "class ", "interface ", "enum ", "type ", "const ", "let ", "var " };
    var result = s;
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, result, kw)) {
            result = result[kw.len..];
        }
    }
    return result;
}

/// Extract the module path from a Python import line.
/// "from mypackage.utils.helpers import X" → "mypackage.utils.helpers"
/// "import os.path" → "os.path"
/// "from . import foo" / "from .rel import bar" → null (relative imports too ambiguous)
pub fn extractPythonModulePath(line: []const u8) ?[]const u8 {
    if (startsWith(line, "from ")) {
        const rest = std.mem.trimStart(u8, line[5..], " \t");
        // Skip relative imports (start with dot)
        if (rest.len > 0 and rest[0] == '.') return null;
        // "from module.path import ..." — extract up to " import"
        if (std.mem.indexOf(u8, rest, " import")) |imp_pos| {
            const mod = std.mem.trimEnd(u8, rest[0..imp_pos], " \t");
            if (mod.len > 0) return mod;
        }
        return null;
    } else if (startsWith(line, "import ")) {
        const rest = std.mem.trimStart(u8, line[7..], " \t");
        // "import os.path" or "import foo" — take up to comma or space
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != ',' and rest[end] != '\t') : (end += 1) {}
        if (end > 0) return rest[0..end];
        return null;
    }
    return null;
}

// ── Fuzzy file matching ─────────────────────────────────────────

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
