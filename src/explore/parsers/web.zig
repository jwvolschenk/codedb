const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;
const SymbolKind = types.SymbolKind;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendImportSymbol = parse_utils.appendImportSymbol;
const extractIdentAfterKeyword = parse_utils.extractIdentAfterKeyword;
const extractIdent = parse_utils.extractIdent;
const extractStringLiteral = parse_utils.extractStringLiteral;
const containsAny = parse_utils.containsAny;
const skipKeywords = parse_utils.skipKeywords;
const firstShellWord = parse_utils.firstShellWord;
const parseShellAssignment = parse_utils.parseShellAssignment;
const parseCssVariable = parse_utils.parseCssVariable;
const parseCssSelector = parse_utils.parseCssSelector;

pub fn parseTsLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    if (containsAny(line, &.{ "function ", "const ", "let ", "var ", "class ", "interface ", "enum ", "type " })) {
        const kind: SymbolKind = if (std.mem.indexOf(u8, line, "function") != null)
            .function
        else if (std.mem.indexOf(u8, line, "class ") != null)
            .class_def
        else if (std.mem.indexOf(u8, line, "interface ") != null)
            .interface_def
        else if (std.mem.indexOf(u8, line, "enum ") != null)
            .enum_def
        else if (std.mem.indexOf(u8, line, "type ") != null)
            .type_alias
        else
            .constant;
        const trimmed = skipKeywords(line);
        if (extractIdent(trimmed)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);

            // Extract return type and param types for functions
            var return_type: ?[]const u8 = null;
            var param_types: []const []const u8 = &.{};
            if (kind == .function) {
                var ts_param_buf: [16][]const u8 = undefined;
                const ts_types = Explorer.extractTsFunctionTypes(line, &ts_param_buf);
                return_type = ts_types.ret;
                param_types = ts_param_buf[0..ts_types.param_count];
            }

            const rt_copy: ?[]const u8 = if (return_type) |rt| try a.dupe(u8, rt) else null;
            errdefer if (rt_copy) |rt| a.free(rt);
            const pt_copy = try a.dupe([]const u8, param_types);
            errdefer a.free(pt_copy);
            for (param_types, 0..) |pt, i| {
                pt_copy[i] = try a.dupe(u8, pt);
                errdefer for (pt_copy[0..i]) |p| a.free(p);
            }

            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
                .return_type = rt_copy,
                .param_types = pt_copy,
            });
        }
    }
    if (containsAny(line, &.{ "import ", "require(" })) {
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
        if (extractStringLiteral(line)) |path| {
            const import_copy = try a.dupe(u8, path);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        }
    }
}

pub fn parseComponentLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const line = std.mem.trim(u8, raw_line, " \t");
    if (line.len == 0 or startsWith(line, "<!--") or startsWith(line, "<script") or startsWith(line, "</script") or
        startsWith(line, "<style") or startsWith(line, "</style"))
        return;
    if (startsWith(line, ".") or startsWith(line, "#") or startsWith(line, "@keyframes") or startsWith(line, "$") or startsWith(line, "--")) {
        try self.parseStyleLine(line, line_num, outline);
        return;
    }
    try self.parseTsLine(line, line_num, outline);
}

pub fn parseShellLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = std.mem.trim(u8, raw_line, " \t");
    if (line.len == 0 or startsWith(line, "#")) return;

    if (startsWith(line, "source ")) {
        const imp = firstShellWord(line["source ".len..]) orelse return;
        try appendImportSymbol(a, outline, imp, line_num, line);
        return;
    }
    if (startsWith(line, ". ")) {
        const imp = firstShellWord(line[2..]) orelse return;
        try appendImportSymbol(a, outline, imp, line_num, line);
        return;
    }
    if (extractIdentAfterKeyword(line, "function ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        return;
    }
    if (std.mem.indexOf(u8, line, "()")) |pos| {
        const before = std.mem.trim(u8, line[0..pos], " \t");
        if (extractIdent(before)) |name| {
            if (name.len == before.len) try appendOutlineSymbol(a, outline, name, .function, line_num, line);
        }
        return;
    }
    if (parseShellAssignment(line)) |name| {
        try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
    }
}

pub fn parseStyleLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = std.mem.trim(u8, raw_line, " \t");
    if (line.len == 0 or startsWith(line, "/*") or startsWith(line, "*")) return;

    if (extractIdentAfterKeyword(line, "@keyframes ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (extractIdentAfterKeyword(line, "@mixin ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (extractIdentAfterKeyword(line, "@function ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (parseCssVariable(line)) |name| {
        try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
    } else if (parseCssSelector(line)) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    }
}
