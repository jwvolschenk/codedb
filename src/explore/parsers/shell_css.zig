//! Shell and CSS parser helper routines.

const std = @import("std");
const ident_utils = @import("../ident_utils.zig");

const extractIdent = ident_utils.extractIdent;
const startsWith = ident_utils.startsWith;

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
