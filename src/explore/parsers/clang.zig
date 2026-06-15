const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendImportSymbol = parse_utils.appendImportSymbol;
const extractIdentAfterKeyword = parse_utils.extractIdentAfterKeyword;
const parseDelimitedImport = parse_utils.parseDelimitedImport;
const stripLineComment = parse_utils.stripLineComment;
const extractCIncludePath = parse_utils.extractCIncludePath;
const parseObjCType = parse_utils.parseObjCType;
const extractObjCMethodName = parse_utils.extractObjCMethodName;
const parseCNamedType = parse_utils.parseCNamedType;
const extractIdent = parse_utils.extractIdent;
const extractCFunctionName = parse_utils.extractCFunctionName;
const applyBraceDelta = parse_utils.applyBraceDelta;
const countBracesDelta = parse_utils.countBracesDelta;

pub fn parseSwiftLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0 or startsWith(line, "@") or startsWith(line, "/*") or startsWith(line, "*")) return;

    if (parseDelimitedImport(line, "import ", "")) |imp| {
        try appendImportSymbol(a, outline, imp, line_num, line);
        return;
    }

    if (extractIdentAfterKeyword(line, "struct ")) |name| {
        try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "protocol ")) |name| {
        try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "class ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
        try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "func ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    }
}

pub fn parseCLine(self: *Explorer, raw_line: []const u8, trimmed: []const u8, line_num: u32, outline: *FileOutline, prev_trimmed: []const u8, brace_depth: *u32) !void {
    const a = self.allocator;
    const line = stripLineComment(trimmed);
    if (line.len == 0) return;

    if (startsWith(line, "#include") or startsWith(line, "#import")) {
        if (extractCIncludePath(line)) |path| {
            const import_copy = try a.dupe(u8, path);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        }
        try appendOutlineSymbol(a, outline, line, .import, line_num, line);
        return;
    }

    if (startsWith(line, "#define")) {
        const rest = std.mem.trimStart(u8, line["#define".len..], " \t");
        if (extractIdent(rest)) |name| {
            try appendOutlineSymbol(a, outline, name, .macro_def, line_num, line);
        }
        return;
    }

    if (parseObjCType(line)) |type_sym| {
        try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
        applyBraceDelta(brace_depth, countBracesDelta(line));
        return;
    }

    if (extractObjCMethodName(line)) |name| {
        try appendOutlineSymbol(a, outline, name, .method, line_num, line);
        applyBraceDelta(brace_depth, countBracesDelta(line));
        return;
    }

    if (parseCNamedType(line)) |type_sym| {
        try appendOutlineSymbol(a, outline, type_sym.name, type_sym.kind, line_num, line);
        applyBraceDelta(brace_depth, countBracesDelta(line));
        return;
    }

    const at_col0 = raw_line.len > 0 and raw_line[0] != ' ' and raw_line[0] != '\t';
    if (extractCFunctionName(line, at_col0, prev_trimmed, brace_depth.*, outline.language == .cpp)) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    }

    applyBraceDelta(brace_depth, countBracesDelta(line));
}
