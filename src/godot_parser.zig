// codedb — line parsers for Godot projects: GDScript (.gd), scenes (.tscn),
// resources (.tres), and project.godot. Zero-dependency and line-based, in
// the style of t4_parser.zig / tsql_parser.zig. Returned slices point into
// the input line; callers dupe what they keep.
const std = @import("std");

/// Godot-specific symbol kinds, mapped to generic SymbolKind in lifecycle.zig.
pub const Kind = enum {
    class_name_decl, // class_name Foo
    inner_class, // class Foo: (nested in a script)
    function_def, // func foo(): at script top level
    method_def, // func foo(): inside an inner class
    signal_decl, // signal foo(a, b)
    variable_decl, // var x / @export var x
    constant_decl, // const X = 1
    enum_decl, // enum Foo { A, B }
    node_def, // [node name="Main" type="Node2D" ...]
    connection, // [connection signal="pressed" from=... to=... method=...]
    resource_def, // [gd_resource ... script_class="CardData"]
    input_action, // project.godot [input] action key
    section_header, // project.godot [section]
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    import: struct {
        path: []const u8,
    },
    annotation: struct {
        name: []const u8, // standalone @annotation line, e.g. "@export"
    },
};

/// Per-file parse state for GDScript.
pub const GdState = struct {
    in_multiline_string: bool = false,
    inner_class_indent: ?usize = null,
};

/// project.godot section tracking.
pub const ProjectSection = enum { none, autoload, input, other };

// ── GDScript ───────────────────────────────────────────────────────────────

pub fn parseGdLine(raw_line: []const u8, trimmed: []const u8, state: *GdState) ParsedLine {
    if (trimmed.len == 0) return .none;

    // Multiline ("""/''') string tracking: an odd number of markers on a
    // line toggles the state. Inside one, nothing is a declaration.
    if (state.in_multiline_string) {
        if (countTripleQuotes(trimmed) % 2 == 1) state.in_multiline_string = false;
        return .none;
    }

    const line = stripGdComment(trimmed);
    if (line.len == 0) return .none;
    if (countTripleQuotes(line) % 2 == 1) state.in_multiline_string = true;

    const indent = leadingIndent(raw_line);
    // Any declaration at or below the inner class's own indent leaves its scope.
    if (state.inner_class_indent) |ci| {
        if (indent <= ci) state.inner_class_indent = null;
    }

    if (line[0] == '@') {
        const rest = skipAnnotations(line);
        if (rest.len == 0) return .{ .annotation = .{ .name = firstAnnotationName(line) } };
        return parseGdDecl(rest, indent, state);
    }
    return parseGdDecl(line, indent, state);
}

fn parseGdDecl(line: []const u8, indent: usize, state: *GdState) ParsedLine {
    if (std.mem.startsWith(u8, line, "class_name ")) {
        const name = extractIdent(line["class_name ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .class_name_decl } };
    }
    if (std.mem.startsWith(u8, line, "extends ")) {
        const target = std.mem.trim(u8, line["extends ".len..], " \t");
        if (target.len >= 2 and target[0] == '"') {
            // extends "res://base.gd"
            const inner = target[1..];
            const end = std.mem.indexOfScalar(u8, inner, '"') orelse return .none;
            return .{ .import = .{ .path = stripResPrefix(inner[0..end]) } };
        }
        const name = extractIdent(target) orelse return .none;
        return .{ .import = .{ .path = name } };
    }
    if (std.mem.startsWith(u8, line, "class ")) {
        const name = extractIdent(line["class ".len..]) orelse return .none;
        state.inner_class_indent = indent;
        return .{ .symbol = .{ .name = name, .kind = .inner_class } };
    }
    var rest = line;
    if (std.mem.startsWith(u8, rest, "static ")) rest = rest["static ".len..];
    if (std.mem.startsWith(u8, rest, "func ")) {
        const name = extractIdent(rest["func ".len..]) orelse return .none;
        const kind: Kind = if (state.inner_class_indent) |ci|
            (if (indent > ci) .method_def else .function_def)
        else
            .function_def;
        return .{ .symbol = .{ .name = name, .kind = kind } };
    }
    if (std.mem.startsWith(u8, rest, "signal ")) {
        const name = extractIdent(rest["signal ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .signal_decl } };
    }
    if (std.mem.startsWith(u8, rest, "var ")) {
        const name = extractIdent(rest["var ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable_decl } };
    }
    if (std.mem.startsWith(u8, rest, "const ")) {
        const name = extractIdent(rest["const ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .constant_decl } };
    }
    if (std.mem.startsWith(u8, rest, "enum ")) {
        const name = extractIdent(rest["enum ".len..]) orelse "enum";
        return .{ .symbol = .{ .name = name, .kind = .enum_decl } };
    }
    return .none;
}

/// Find a preload("res://...") or load("res://...") reference on a line.
/// Returns the project-relative path (res:// stripped), or null. Only
/// res:// paths count — user:// and absolute paths are runtime-only.
pub fn extractResPath(line: []const u8) ?[]const u8 {
    const keywords = [_][]const u8{ "preload(\"", "load(\"" };
    for (keywords) |kw| {
        const pos = std.mem.indexOf(u8, line, kw) orelse continue;
        const rest = line[pos + kw.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const path = rest[0..end];
        if (std.mem.startsWith(u8, path, "res://")) return path["res://".len..];
    }
    return null;
}

/// Strip a trailing `#` comment, respecting single/double-quoted strings.
/// Public: the lifecycle dispatch also strips comments before scanning for
/// preload()/load() imports, so commented-out code can't create dep edges.
pub fn stripGdComment(line: []const u8) []const u8 {
    var in_str: u8 = 0; // 0 = outside strings, else the active quote char
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 1; // skip escaped char
            } else if (ch == in_str) {
                in_str = 0;
            }
        } else if (ch == '"' or ch == '\'') {
            in_str = ch;
        } else if (ch == '#') {
            return std.mem.trimEnd(u8, line[0..i], " \t");
        }
    }
    return line;
}

fn countTripleQuotes(line: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= line.len) {
        if (std.mem.eql(u8, line[i .. i + 3], "\"\"\"") or
            std.mem.eql(u8, line[i .. i + 3], "'''"))
        {
            count += 1;
            i += 3;
        } else {
            i += 1;
        }
    }
    return count;
}

/// Leading whitespace count. Tabs and spaces each count as one — enough to
/// order nesting levels within one file; mixed indentation degrades but
/// never crashes.
fn leadingIndent(raw_line: []const u8) usize {
    var i: usize = 0;
    while (i < raw_line.len and (raw_line[i] == ' ' or raw_line[i] == '\t')) i += 1;
    return i;
}

/// Skip leading @annotations (with optional (args)); returns the rest, trimmed.
fn skipAnnotations(line: []const u8) []const u8 {
    var rest = line;
    while (rest.len > 0 and rest[0] == '@') {
        var i: usize = 1;
        while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_')) i += 1;
        if (i < rest.len and rest[i] == '(') {
            var depth: usize = 0;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '(') depth += 1;
                if (rest[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
        }
        rest = std.mem.trimStart(u8, rest[i..], " \t");
    }
    return rest;
}

/// "@export_range(0, 10) ..." -> "@export_range"
fn firstAnnotationName(line: []const u8) []const u8 {
    var i: usize = 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
    return line[0..i];
}

fn extractIdent(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return null;
    var i: usize = 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    return text[0..i];
}

/// Strip Godot resource-path prefixes: leading autoload '*' and res://.
fn stripResPrefix(path: []const u8) []const u8 {
    var p = path;
    if (p.len > 0 and p[0] == '*') p = p[1..];
    if (std.mem.startsWith(u8, p, "res://")) return p["res://".len..];
    return p;
}
