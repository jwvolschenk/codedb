//! SQL parser helper routines.

const std = @import("std");
const explore = @import("../../explore.zig");
const ident_utils = @import("../ident_utils.zig");

const SymbolKind = explore.SymbolKind;
const startsWith = ident_utils.startsWith;
const startsWithIgnoreCase = ident_utils.startsWithIgnoreCase;

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
