//! Miscellaneous language parser helpers.

const std = @import("std");
const ident_utils = @import("../ident_utils.zig");

const startsWith = ident_utils.startsWith;
const startsWithIgnoreCase = ident_utils.startsWithIgnoreCase;
const extractIdent = ident_utils.extractIdent;
const extractLastIdentSpan = ident_utils.extractLastIdentSpan;
const isControlKeyword = ident_utils.isControlKeyword;

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
