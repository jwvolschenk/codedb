//! Identifier, keyword, and small string helpers shared by parsers.

const std = @import("std");
const search_utils = @import("search_utils.zig");

const indexOfCaseInsensitive = search_utils.indexOfCaseInsensitive;

pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
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

pub fn isControlKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{ "if", "for", "while", "switch", "catch", "return", "throw", "new", "when" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
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
