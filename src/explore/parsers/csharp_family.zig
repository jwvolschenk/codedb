const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;

const csharp_parser = @import("../../csharp_parser.zig");
const fsharp_parser = @import("../../fsharp_parser.zig");

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendOutlineSymbolWithTypes = parse_utils.appendOutlineSymbolWithTypes;
const appendImportSymbol = parse_utils.appendImportSymbol;
const cSharpSymbolKind = parse_utils.cSharpSymbolKind;
const fSharpSymbolKind = parse_utils.fSharpSymbolKind;

pub fn parseCSharpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    return parseCSharpLineWithOptions(self, raw_line, line_num, outline, .{});
}

pub fn parseCSharpLineWithOptions(
    self: *Explorer,
    raw_line: []const u8,
    line_num: u32,
    outline: *FileOutline,
    options: csharp_parser.ParseOptions,
) !void {
    const a = self.allocator;
    // Multi-declarator fields (`private int a, b, c;`) emit one symbol per
    // name. Initializer lists bail to the single-field path below.
    var field_names: [csharp_parser.max_field_names][]const u8 = undefined;
    const field_count = if (options.allow_field_declarations)
        csharp_parser.extractFieldNames(raw_line, &field_names)
    else
        0;
    if (field_count > 1) {
        for (field_names[0..field_count]) |nm| {
            try appendOutlineSymbol(a, outline, nm, .variable, line_num, raw_line);
        }
        return;
    }
    switch (csharp_parser.parseLineWithOptions(raw_line, options)) {
        .none => {},
        .import => |imp| try appendImportSymbol(a, outline, imp, line_num, raw_line),
        .symbol => |sym| {
            const mapped_kind = cSharpSymbolKind(sym.kind);
            // Convert C# parser's ParamTypesResult to a slice for the outline
            const pt_slice = sym.param_types.slice();
            // For enum members (constant kind from C# parser), extract `= value` as detail
            if (mapped_kind == .constant) {
                const detail = extractCSharpEnumValue(raw_line);
                try appendOutlineSymbol(a, outline, sym.name, mapped_kind, line_num, detail);
            } else {
                try appendOutlineSymbolWithTypes(a, outline, sym.name, mapped_kind, line_num, raw_line, sym.return_type, pt_slice);
            }
        },
    }
}

/// Extract the `= value` portion from a C# enum member line.
/// Returns the trimmed value string, or the raw_line if no value found.
pub fn extractCSharpEnumValue(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
        const after_eq = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t,");
        if (after_eq.len > 0) return after_eq;
    }
    return raw_line;
}

pub fn parseFSharpLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    switch (fsharp_parser.parseLine(line)) {
        .none => {},
        .import => |imp| try appendImportSymbol(a, outline, imp, line_num, line),
        .symbol => |sym| try appendOutlineSymbol(a, outline, sym.name, fSharpSymbolKind(sym.kind), line_num, line),
    }
}

/// Parse a Razor/cshtml line. Tracks @functions/@code blocks and delegates
/// their contents to the C# parser. Outside code blocks, extracts Razor
/// directives (@model, @using, @inject, @inherits, @implements, @page,
/// @namespace, @layout, @typeparam, @section, @attribute).
pub fn parseRazorLine(
    self: *Explorer,
    raw_line: []const u8,
    line_num: u32,
    outline: *FileOutline,
    in_code_block: *bool,
    brace_depth: *u32,
) !void {
    const a = self.allocator;
    const trimmed = std.mem.trim(u8, raw_line, " \t");

    // Inside a @functions/@code block — delegate to C# parser and track braces
    if (in_code_block.*) {
        // Count braces to know when the block ends
        for (trimmed) |ch| {
            if (ch == '{') brace_depth.* += 1;
            if (ch == '}') {
                if (brace_depth.* > 0) brace_depth.* -= 1;
                if (brace_depth.* == 0) {
                    in_code_block.* = false;
                    return;
                }
            }
        }
        try self.parseCSharpLine(trimmed, line_num, outline);
        return;
    }

    // Not a directive line — skip HTML content
    if (trimmed.len == 0 or trimmed[0] != '@') return;

    // Handle @@escape (literal @) — skip
    if (trimmed.len >= 2 and trimmed[1] == '@') return;

    // Skip @-prefixed control flow that doesn't declare symbols:
    // @if, @else, @for, @foreach, @while, @switch, @case, @default,
    // @try, @catch, @finally, @lock, @using (statement, not directive),
    // @do, @return, @throw, @break, @continue
    if (razorIsControlFlow(trimmed)) return;

    // Skip HTML helper / attribute directives that aren't declarations
    if (startsWith(trimmed, "@rendermode") or startsWith(trimmed, "@ref ") or
        startsWith(trimmed, "@bind") or startsWith(trimmed, "@onclick") or
        startsWith(trimmed, "@onchange") or startsWith(trimmed, "@oninput") or
        startsWith(trimmed, "@onfocus") or startsWith(trimmed, "@onblur") or
        startsWith(trimmed, "@onkeydown") or startsWith(trimmed, "@onkeyup") or
        startsWith(trimmed, "@onmouseover") or startsWith(trimmed, "@onmouseout") or
        startsWith(trimmed, "@ondrop") or startsWith(trimmed, "@ondrag") or
        startsWith(trimmed, "@onsubmit") or startsWith(trimmed, "@onscroll") or
        startsWith(trimmed, "@onpaste") or startsWith(trimmed, "@oncut") or
        startsWith(trimmed, "@oncopy") or startsWith(trimmed, "@oninput"))
        return;

    // @functions { or @code { — enter code block
    if (startsWith(trimmed, "@functions") or startsWith(trimmed, "@code")) {
        in_code_block.* = true;
        brace_depth.* = 1; // the opening { may be on this line or the next
        // If { is on this line, it's already counted
        var found_open = false;
        for (trimmed) |ch| {
            if (ch == '{') found_open = true;
        }
        if (!found_open) brace_depth.* = 0; // will open on next line
        try appendOutlineSymbol(a, outline, if (startsWith(trimmed, "@functions")) "@functions" else "@code", .type_alias, line_num, trimmed);
        return;
    }

    // @model TypeName → type_alias
    if (startsWith(trimmed, "@model ")) {
        const rest = std.mem.trim(u8, trimmed["@model ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
        }
        return;
    }

    // @using Namespace → import
    if (startsWith(trimmed, "@using ")) {
        const rest = std.mem.trim(u8, trimmed["@using ".len..], " \t");
        if (rest.len > 0) {
            try appendImportSymbol(a, outline, rest, line_num, trimmed);
        }
        return;
    }

    // @inject Type Name → import (tracks the type dependency)
    if (startsWith(trimmed, "@inject ")) {
        const rest = std.mem.trim(u8, trimmed["@inject ".len..], " \t");
        if (rest.len > 0) {
            // Extract just the type name (first token, possibly with generics)
            // Syntax: @inject TypeName ParameterName
            const type_name = extractRazorInjectType(rest);
            if (type_name.len > 0) {
                try appendImportSymbol(a, outline, type_name, line_num, trimmed);
            }
        }
        return;
    }

    // @inherits TypeName → type_alias (base class)
    if (startsWith(trimmed, "@inherits ")) {
        const rest = std.mem.trim(u8, trimmed["@inherits ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
        }
        return;
    }

    // @implements TypeName → interface_def
    if (startsWith(trimmed, "@implements ")) {
        const rest = std.mem.trim(u8, trimmed["@implements ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .interface_def, line_num, trimmed);
        }
        return;
    }

    // @namespace Namespace → type_alias
    if (startsWith(trimmed, "@namespace ")) {
        const rest = std.mem.trim(u8, trimmed["@namespace ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
        }
        return;
    }

    // @page "/route" → variable (route metadata)
    if (startsWith(trimmed, "@page")) {
        const rest = std.mem.trim(u8, trimmed["@page".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .variable, line_num, trimmed);
        }
        return;
    }

    // @layout TypeName → type_alias
    if (startsWith(trimmed, "@layout ")) {
        const rest = std.mem.trim(u8, trimmed["@layout ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
        }
        return;
    }

    // @typeparam T → type_alias
    if (startsWith(trimmed, "@typeparam ")) {
        const rest = std.mem.trim(u8, trimmed["@typeparam ".len..], " \t");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .type_alias, line_num, trimmed);
        }
        return;
    }

    // @section Name { → class_def (structural block)
    if (startsWith(trimmed, "@section ")) {
        const rest = std.mem.trim(u8, trimmed["@section ".len..], " \t{");
        if (rest.len > 0) {
            try appendOutlineSymbol(a, outline, rest, .class_def, line_num, trimmed);
        }
        return;
    }

    // @attribute [Attr] → skip (like C# attributes, metadata only)
    if (startsWith(trimmed, "@attribute ")) return;
}

/// Returns true for Razor @-prefixed control flow keywords that don't
/// declare symbols (if, else, for, foreach, while, switch, etc.).
pub fn razorIsControlFlow(line: []const u8) bool {
    const keywords = [_][]const u8{
        "@if",       "@else",   "@for",     "@foreach",
        "@while",    "@switch", "@case",    "@default",
        "@try",      "@catch",  "@finally", "@lock",
        "@do",       "@return", "@throw",   "@break",
        "@continue", "@using(", "@{",
    };
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, line, kw)) {
            // Make sure it's a whole-word match (next char is not alphanumeric)
            if (line.len == kw.len) return true;
            const next = line[kw.len];
            if (next == ' ' or next == '\t' or next == '(' or next == '{' or next == ';')
                return true;
        }
    }
    return false;
}

/// Extract the type name from a Razor @inject line.
/// Syntax: @inject TypeName ParameterName
/// TypeName may include generics like `ILogger<MyClass>`.
/// Returns just the type portion, stopping before the parameter name.
pub fn extractRazorInjectType(line: []const u8) []const u8 {
    var depth: usize = 0;
    var end: usize = 0;
    for (line, 0..) |ch, i| {
        if (ch == '<') {
            depth += 1;
        } else if (ch == '>') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and (ch == ' ' or ch == '\t')) {
            end = i;
            break;
        }
        end = i + 1;
    }
    return std.mem.trim(u8, line[0..end], " \t");
}
