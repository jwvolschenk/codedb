//! Helpers for appending parser output to file outlines.

const std = @import("std");
const csharp_parser = @import("../csharp_parser.zig");
const fsharp_parser = @import("../fsharp_parser.zig");
const explore = @import("../explore.zig");

const SymbolKind = explore.SymbolKind;
const Symbol = explore.Symbol;
const FileOutline = explore.FileOutline;

pub fn appendOutlineSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_num: u32,
    detail: []const u8,
) !void {
    return appendOutlineSymbolWithTypes(allocator, outline, name, kind, line_num, detail, null, &.{});
}

pub fn appendOutlineSymbolWithTypes(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    name: []const u8,
    kind: SymbolKind,
    line_num: u32,
    detail: []const u8,
    return_type: ?[]const u8,
    param_types: []const []const u8,
) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const detail_copy = try allocator.dupe(u8, detail);
    errdefer allocator.free(detail_copy);
    const rt_copy: ?[]const u8 = if (return_type) |rt| try allocator.dupe(u8, rt) else null;
    errdefer if (rt_copy) |rt| allocator.free(rt);
    const pt_copy = try allocator.dupe([]const u8, param_types);
    errdefer allocator.free(pt_copy);
    for (param_types, 0..) |pt, i| {
        pt_copy[i] = try allocator.dupe(u8, pt);
        errdefer for (pt_copy[0..i]) |p| allocator.free(p);
    }
    try outline.symbols.append(allocator, .{
        .name = name_copy,
        .kind = kind,
        .line_start = line_num,
        .line_end = line_num,
        .detail = detail_copy,
        .return_type = rt_copy,
        .param_types = pt_copy,
    });
}

pub fn appendImportSymbol(
    allocator: std.mem.Allocator,
    outline: *FileOutline,
    import_path: []const u8,
    line_num: u32,
    detail: []const u8,
) !void {
    try appendOutlineSymbol(allocator, outline, import_path, .import, line_num, detail);
    const import_copy = try allocator.dupe(u8, import_path);
    errdefer allocator.free(import_copy);
    try outline.imports.append(allocator, import_copy);
}

pub fn cSharpSymbolKind(kind: csharp_parser.Kind) SymbolKind {
    return switch (kind) {
        .class_def => .class_def,
        .interface_def => .interface_def,
        .enum_def => .enum_def,
        .struct_def => .struct_def,
        .function => .function,
        .method => .method,
        .variable => .variable,
        .constant => .constant,
        .type_alias => .type_alias,
    };
}

pub fn fSharpSymbolKind(kind: fsharp_parser.Kind) SymbolKind {
    return switch (kind) {
        .class_def => .class_def,
        .interface_def => .interface_def,
        .enum_def => .enum_def,
        .struct_def => .struct_def,
        .function => .function,
        .method => .method,
        .variable => .variable,
        .constant => .constant,
        .type_alias => .type_alias,
    };
}
