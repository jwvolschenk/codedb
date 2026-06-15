//! C, C++, Objective-C, and related brace/name parsing helpers.

const std = @import("std");
const explore = @import("../../explore.zig");
const ident_utils = @import("../ident_utils.zig");
const misc = @import("misc.zig");

const SymbolKind = explore.SymbolKind;
const extractIdent = ident_utils.extractIdent;
const extractLastIdent = ident_utils.extractLastIdent;
const extractLastIdentSpan = ident_utils.extractLastIdentSpan;
const extractStringLiteral = misc.extractStringLiteral;
const startsWith = ident_utils.startsWith;

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
