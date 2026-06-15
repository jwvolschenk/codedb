const std = @import("std");
const ident = @import("explore/ident_utils.zig");

pub const Kind = enum {
    class_def,
    interface_def,
    enum_def,
    struct_def,
    function,
    method,
    variable,
    constant,
    type_alias,
};

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
};

pub const ParsedLine = union(enum) {
    none,
    import: []const u8,
    symbol: Symbol,
};

pub fn parseLine(raw_line: []const u8) ParsedLine {
    const line_without_trailing = stripLineComment(raw_line);
    var line = std.mem.trim(u8, line_without_trailing, " \t");
    
    // Strip leading block comments
    while (startsWith(line, "(*")) {
        if (std.mem.indexOf(u8, line, "*)")) |end| {
            line = std.mem.trimStart(u8, line[end + 2 ..], " \t");
        } else break;
    }

    const final_line = stripAttributePrefix(line) orelse return .none;
    if (final_line.len == 0 or startsWith(final_line, "#")) return .none;
    if (startsWith(final_line, "|")) return .none; // union cases are nested details

    if (parseOpen(final_line)) |imp| return .{ .import = imp };
    if (extractNamespace(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .type_alias } };
    if (extractModule(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .type_alias } };
    if (extractTypeName(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .type_alias } };
    if (extractLetName(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .function } };
    if (extractAndName(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .function } };
    if (extractMemberName(final_line)) |member| return .{ .symbol = member };
    if (extractValName(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .variable } };
    if (extractAbstractName(final_line)) |name| return .{ .symbol = .{ .name = name, .kind = .method } };

    return .none;
}

pub fn updateFSharpState(line: []const u8, comment_depth: *usize) void {
    var i: usize = 0;
    var in_string = false;
    var in_verbatim = false;
    var triple_quote = false;

    while (i < line.len) : (i += 1) {
        const ch = line[i];
        
        if (triple_quote) {
            if (ch == '"' and i + 2 < line.len and line[i+1] == '"' and line[i+2] == '"') {
                triple_quote = false;
                i += 2;
            }
            continue;
        }

        if (in_string) {
            if (in_verbatim) {
                if (ch == '"' and i + 1 < line.len and line[i+1] == '"') {
                    i += 1;
                    continue;
                }
                if (ch == '"') {
                    in_string = false;
                    in_verbatim = false;
                }
            } else {
                if (ch == '\\' and i + 1 < line.len) {
                    i += 1;
                    continue;
                }
                if (ch == '"') in_string = false;
            }
            continue;
        }

        if (comment_depth.* > 0) {
            if (ch == '(' and i + 1 < line.len and line[i+1] == '*') {
                comment_depth.* += 1;
                i += 1;
            } else if (ch == '*' and i + 1 < line.len and line[i+1] == ')') {
                comment_depth.* -= 1;
                i += 1;
            }
            continue;
        }

        if (ch == '/' and i + 1 < line.len and line[i+1] == '/') return;

        if (ch == '(' and i + 1 < line.len and line[i+1] == '*') {
            comment_depth.* += 1;
            i += 1;
            continue;
        }

        if (ch == '"' and i + 2 < line.len and line[i+1] == '"' and line[i+2] == '"') {
            triple_quote = true;
            i += 2;
            continue;
        }

        if (ch == '@' and i + 1 < line.len and line[i+1] == '"') {
            in_string = true;
            in_verbatim = true;
            i += 1;
            continue;
        }

        if (ch == '"') {
            in_string = true;
            continue;
        }
    }
}

pub fn stripAttributeLine(line: []const u8, in_attribute_block: *bool) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    if (in_attribute_block.*) {
        if (std.mem.indexOf(u8, rest, ">]")) |end| {
            in_attribute_block.* = false;
            rest = std.mem.trimStart(u8, rest[end + 2 ..], " \t");
            if (rest.len == 0) return null;
        } else return null;
    }
    while (startsWith(rest, "[<")) {
        if (std.mem.indexOf(u8, rest, ">]")) |end| {
            rest = std.mem.trimStart(u8, rest[end + 2 ..], " \t");
            if (rest.len == 0) return null;
        } else {
            in_attribute_block.* = true;
            return null;
        }
    }
    return rest;
}

fn stripAttributePrefix(line: []const u8) ?[]const u8 {
    var in_block = false;
    return stripAttributeLine(line, &in_block);
}

fn stripLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    var i: usize = 0;
    var comment_depth: usize = 0;
    var in_string = false;
    var in_verbatim = false;
    var triple_quote = false;

    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];

        if (triple_quote) {
            if (ch == '"' and i + 2 < trimmed.len and trimmed[i+1] == '"' and trimmed[i+2] == '"') {
                triple_quote = false;
                i += 2;
            }
            continue;
        }

        if (in_string) {
            if (in_verbatim) {
                if (ch == '"' and i + 1 < trimmed.len and trimmed[i+1] == '"') {
                    i += 1;
                    continue;
                }
                if (ch == '"') {
                    in_string = false;
                    in_verbatim = false;
                }
            } else {
                if (ch == '\\' and i + 1 < trimmed.len) {
                    i += 1;
                    continue;
                }
                if (ch == '"') in_string = false;
            }
            continue;
        }

        if (comment_depth > 0) {
            if (ch == '(' and i + 1 < trimmed.len and trimmed[i+1] == '*') {
                comment_depth += 1;
                i += 1;
            } else if (ch == '*' and i + 1 < trimmed.len and trimmed[i+1] == ')') {
                comment_depth -= 1;
                i += 1;
            }
            continue;
        }

        if (ch == '/' and i + 1 < trimmed.len and trimmed[i+1] == '/') {
            return std.mem.trimEnd(u8, trimmed[0..i], " \t");
        }

        if (ch == '(' and i + 1 < trimmed.len and trimmed[i+1] == '*') {
            comment_depth += 1;
            i += 1;
            continue;
        }

        if (ch == '"' and i + 2 < trimmed.len and trimmed[i+1] == '"' and trimmed[i+2] == '"') {
            triple_quote = true;
            i += 2;
            continue;
        }

        if (ch == '@' and i + 1 < trimmed.len and trimmed[i+1] == '"') {
            in_string = true;
            in_verbatim = true;
            i += 1;
            continue;
        }

        if (ch == '"') {
            in_string = true;
            continue;
        }
    }
    return trimmed;
}

fn parseOpen(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "open ")) return null;
    const body = std.mem.trim(u8, line["open ".len..], " \t");
    if (body.len == 0) return null;
    return body;
}

fn extractNamespace(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "namespace ")) return null;
    var rest = std.mem.trimStart(u8, line["namespace ".len..], " \t");
    if (startsWith(rest, "rec ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
    return extractQualifiedIdent(rest);
}

fn extractModule(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "module ")) return null;
    var rest = std.mem.trimStart(u8, line["module ".len..], " \t");
    if (startsWith(rest, "rec ")) rest = std.mem.trimStart(u8, rest[4..], " \t");
    return extractQualifiedIdent(rest);
}

fn extractTypeName(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "type ", "and " };
    for (prefixes) |prefix| {
        if (startsWith(line, prefix)) {
            return extractIdent(stripModifiers(line[prefix.len..]));
        }
    }
    return null;
}

fn extractLetName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "let ")) return null;
    return extractIdent(stripModifiers(line["let ".len..]));
}

fn extractAndName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "and ")) return null;
    return extractIdent(stripModifiers(line["and ".len..]));
}

fn extractMemberName(line: []const u8) ?Symbol {
    const prefixes = [_]struct { prefix: []const u8, kind: Kind }{
        .{ .prefix = "static member ", .kind = .method },
        .{ .prefix = "override ", .kind = .method },
        .{ .prefix = "default ", .kind = .method },
        .{ .prefix = "member ", .kind = .method },
    };
    for (prefixes) |p| {
        if (startsWith(line, p.prefix)) {
            var rest = stripModifiers(line[p.prefix.len..]);
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                rest = std.mem.trimStart(u8, rest[dot + 1 ..], " \t");
            }
            if (extractIdent(rest)) |name| return .{ .name = name, .kind = p.kind };
        }
    }
    return null;
}

fn extractValName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "val ")) return null;
    return extractIdent(stripModifiers(line["val ".len..]));
}

fn extractAbstractName(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "abstract ")) return null;
    var rest = std.mem.trimStart(u8, line["abstract ".len..], " \t");
    if (startsWith(rest, "member ")) rest = std.mem.trimStart(u8, rest["member ".len..], " \t");
    return extractIdent(stripModifiers(rest));
}

fn stripModifiers(s: []const u8) []const u8 {
    var rest = std.mem.trimStart(u8, s, " \t");
    while (true) {
        const before = rest;
        const modifiers = [_][]const u8{ "private ", "public ", "internal ", "inline ", "rec ", "mutable ", "static " };
        for (modifiers) |modifier| {
            if (startsWith(rest, modifier)) {
                rest = std.mem.trimStart(u8, rest[modifier.len..], " \t");
                break;
            }
        }
        if (rest.ptr == before.ptr and rest.len == before.len) return rest;
    }
}

fn extractIdent(s: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, s, " \t");
    if (startsWith(rest, "``")) {
        if (std.mem.indexOf(u8, rest[2..], "``")) |end| {
            return rest[0 .. end + 4];
        }
    }
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const ch = rest[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '\'')) break;
    }
    return if (end > 0) rest[0..end] else null;
}

fn extractQualifiedIdent(s: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, s, " \t");
    var total_end: usize = 0;
    while (total_end < rest.len) {
        if (startsWith(rest[total_end..], "``")) {
            if (std.mem.indexOf(u8, rest[total_end + 2 ..], "``")) |end| {
                total_end += end + 4;
            } else break;
        } else {
            const start = total_end;
            while (total_end < rest.len) : (total_end += 1) {
                const ch = rest[total_end];
                if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '\'')) break;
            }
            if (total_end == start) break;
        }
        if (total_end < rest.len and rest[total_end] == '.') {
            total_end += 1;
        } else break;
    }
    while (total_end > 0 and rest[total_end - 1] == '.') total_end -= 1;
    return if (total_end > 0) rest[0..total_end] else null;
}

const startsWith = ident.startsWith;
