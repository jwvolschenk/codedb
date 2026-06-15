const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendOutlineSymbolWithTypes = parse_utils.appendOutlineSymbolWithTypes;
const appendImportSymbol = parse_utils.appendImportSymbol;
const extractIdentAfterKeyword = parse_utils.extractIdentAfterKeyword;
const parseDelimitedImport = parse_utils.parseDelimitedImport;
const extractJvmMethodName = parse_utils.extractJvmMethodName;
const stripLineComment = parse_utils.stripLineComment;

pub fn parseJavaLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0 or startsWith(line, "@")) return;

    if (parseDelimitedImport(line, "import ", ";")) |imp| {
        try appendImportSymbol(a, outline, imp, line_num, line);
        return;
    }

    if (extractIdentAfterKeyword(line, "record ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "class ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
        try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
        try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
    } else if (extractJvmMethodName(line)) |name| {
        var java_param_buf: [16][]const u8 = undefined;
        const java_types = Explorer.extractJvmFuncTypes(line, &java_param_buf);
        const java_params = java_param_buf[0..java_types.param_count];
        try appendOutlineSymbolWithTypes(a, outline, name, .method, line_num, line, java_types.ret, java_params);
    }
}

pub fn parseKotlinLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0 or startsWith(line, "@")) return;

    if (parseDelimitedImport(line, "import ", "")) |imp| {
        try appendImportSymbol(a, outline, imp, line_num, line);
        return;
    }

    if (extractIdentAfterKeyword(line, "enum class ")) |name| {
        try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "interface ")) |name| {
        try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "class ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "object ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "fun ")) |name| {
        var kt_param_buf: [16][]const u8 = undefined;
        const kt_types = Explorer.extractKotlinFuncTypes(line, &kt_param_buf);
        const kt_params = kt_param_buf[0..kt_types.param_count];
        try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, kt_types.ret, kt_params);
    } else if (extractIdentAfterKeyword(line, "val ")) |name| {
        try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
    } else if (extractIdentAfterKeyword(line, "var ")) |name| {
        try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
    }
}
