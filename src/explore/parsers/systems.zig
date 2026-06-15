const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;
const SymbolKind = types.SymbolKind;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const appendOutlineSymbolWithTypes = parse_utils.appendOutlineSymbolWithTypes;
const extractIdent = parse_utils.extractIdent;
const extractStringLiteral = parse_utils.extractStringLiteral;
const containsAny = parse_utils.containsAny;

pub fn parseZigLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    if (startsWith(line, "pub fn ") or startsWith(line, "fn ")) {
        const start: usize = if (startsWith(line, "pub fn ")) 7 else 3;
        if (extractIdent(line[start..])) |name| {
            var zig_param_buf: [16][]const u8 = undefined;
            const zig_types = Explorer.extractZigFuncTypes(line, &zig_param_buf);
            const zig_params = zig_param_buf[0..zig_types.param_count];
            try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, zig_types.ret, zig_params);
        }
    } else if (startsWith(line, "pub const ") or startsWith(line, "const ")) {
        const start: usize = if (startsWith(line, "pub const ")) 10 else 6;
        if (extractIdent(line[start..])) |name| {
            const kind: SymbolKind = if (std.mem.indexOf(u8, line, "struct {") != null)
                .struct_def
            else if (std.mem.indexOf(u8, line, "enum {") != null)
                .enum_def
            else if (std.mem.indexOf(u8, line, "union {") != null or
                std.mem.indexOf(u8, line, "union(enum) {") != null)
                .union_def
            else if (std.mem.indexOf(u8, line, "@import") != null)
                .import
            else
                .constant;

            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });

            if (kind == .import) {
                if (extractStringLiteral(line)) |import_path| {
                    const import_copy = try a.dupe(u8, import_path);
                    errdefer a.free(import_copy);
                    try outline.imports.append(a, import_copy);
                }
            }
        }
    } else if (startsWith(line, "test ")) {
        const name_copy = try a.dupe(u8, line);
        errdefer a.free(name_copy);
        try outline.symbols.append(a, .{
            .name = name_copy,
            .kind = .test_decl,
            .line_start = line_num,
            .line_end = line_num,
        });
    }
}

pub fn parseRustLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline, prev_line: []const u8) !void {
    const a = self.allocator;

    // fn / pub fn / pub(crate) fn / async fn / pub async fn / unsafe fn
    if (containsAny(line, &.{"fn "})) {
        const is_decl = startsWith(line, "fn ") or
            startsWith(line, "pub fn ") or
            startsWith(line, "pub(crate) fn ") or
            startsWith(line, "pub(super) fn ") or
            startsWith(line, "async fn ") or
            startsWith(line, "pub async fn ") or
            startsWith(line, "unsafe fn ") or
            startsWith(line, "pub unsafe fn ") or
            startsWith(line, "pub(crate) async fn ") or
            startsWith(line, "pub(crate) unsafe fn ") or
            startsWith(line, "pub unsafe extern ");
        if (is_decl) {
            if (std.mem.indexOf(u8, line, "fn ")) |fn_pos| {
                if (extractIdent(line[fn_pos + 3 ..])) |name| {
                    const is_test = std.mem.eql(u8, prev_line, "#[test]") or
                        startsWith(prev_line, "#[tokio::test");
                    const kind: SymbolKind = if (is_test) .test_decl else .function;
                    var rust_param_buf: [16][]const u8 = undefined;
                    const rust_types = Explorer.extractRustFuncTypes(line, &rust_param_buf);
                    const rust_params = rust_param_buf[0..rust_types.param_count];
                    try appendOutlineSymbolWithTypes(a, outline, name, kind, line_num, line, rust_types.ret, rust_params);
                }
            }
        }
    }

    // struct
    if (startsWith(line, "struct ") or startsWith(line, "pub struct ") or startsWith(line, "pub(crate) struct ")) {
        if (std.mem.indexOf(u8, line, "struct ")) |pos| {
            if (extractIdent(line[pos + 7 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    // enum
    if (startsWith(line, "enum ") or startsWith(line, "pub enum ") or startsWith(line, "pub(crate) enum ")) {
        if (std.mem.indexOf(u8, line, "enum ")) |pos| {
            if (extractIdent(line[pos + 5 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .enum_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    // trait
    if (startsWith(line, "trait ") or startsWith(line, "pub trait ") or startsWith(line, "pub(crate) trait ") or startsWith(line, "unsafe trait ") or startsWith(line, "pub unsafe trait ")) {
        if (std.mem.indexOf(u8, line, "trait ")) |pos| {
            if (extractIdent(line[pos + 6 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .trait_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    // impl
    if (startsWith(line, "impl ") or startsWith(line, "impl<") or startsWith(line, "unsafe impl ")) {
        const impl_start: usize = if (startsWith(line, "unsafe impl ")) 12 else if (startsWith(line, "impl<")) blk: {
            if (std.mem.indexOf(u8, line, "> ")) |gt| {
                break :blk gt + 2;
            } else break :blk 5;
        } else 5;
        if (extractIdent(line[impl_start..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .impl_block,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
    }

    // type alias
    if (startsWith(line, "type ") or startsWith(line, "pub type ") or startsWith(line, "pub(crate) type ")) {
        if (std.mem.indexOf(u8, line, "type ")) |pos| {
            if (extractIdent(line[pos + 5 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .type_alias,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    // const / static
    if (startsWith(line, "const ") or startsWith(line, "pub const ") or startsWith(line, "pub(crate) const ") or
        startsWith(line, "static ") or startsWith(line, "pub static ") or startsWith(line, "pub(crate) static "))
    {
        const keyword = if (std.mem.indexOf(u8, line, "static ")) |_| "static " else "const ";
        if (std.mem.indexOf(u8, line, keyword)) |pos| {
            if (extractIdent(line[pos + keyword.len ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .constant,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    // macro_rules!
    if (startsWith(line, "macro_rules!")) {
        if (extractIdent(line[13..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .macro_def,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
    }

    // use / mod
    if (startsWith(line, "use ") or startsWith(line, "pub use ") or startsWith(line, "pub(crate) use ")) {
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
        const import_copy = try a.dupe(u8, line);
        errdefer a.free(import_copy);
        try outline.imports.append(a, import_copy);
    } else if (startsWith(line, "mod ") or startsWith(line, "pub mod ") or startsWith(line, "pub(crate) mod ")) {
        if (std.mem.indexOf(u8, line, "mod ")) |pos| {
            if (extractIdent(line[pos + 4 ..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .import,
                    .line_start = line_num,
                    .line_end = line_num,
                });
                const import_copy = try a.dupe(u8, name);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }
}

pub fn parseGoLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    // func name( or func (receiver) name(
    if (startsWith(line, "func ")) {
        // Skip "func (" for function literals
        const rest = line[5..];
        // Method with receiver: func (r *Type) Name(
        var name_start = rest;
        if (rest.len > 0 and rest[0] == '(') {
            // Skip past receiver: find ") "
            if (std.mem.indexOf(u8, rest, ") ")) |close| {
                name_start = rest[close + 2 ..];
            }
        }
        if (extractIdent(name_start)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);

            // Extract Go function types
            var go_param_buf: [16][]const u8 = undefined;
            const go_types = Explorer.extractGoFuncTypes(line, &go_param_buf);
            const rt_copy: ?[]const u8 = if (go_types.ret) |rt| try a.dupe(u8, rt) else null;
            errdefer if (rt_copy) |rt| a.free(rt);
            const go_params = go_param_buf[0..go_types.param_count];
            const pt_copy = try a.dupe([]const u8, go_params);
            errdefer a.free(pt_copy);
            for (go_params, 0..) |pt, i| {
                pt_copy[i] = try a.dupe(u8, pt);
                errdefer for (pt_copy[0..i]) |p| a.free(p);
            }

            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .function,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
                .return_type = rt_copy,
                .param_types = pt_copy,
            });
        }
    } else if (startsWith(line, "type ")) {
        const rest = line[5..];
        if (extractIdent(rest)) |name| {
            const kind: SymbolKind = .struct_def;
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
    } else if (startsWith(line, "import ")) {
        if (extractStringLiteral(line)) |path| {
            const import_copy = try a.dupe(u8, path);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        }
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
    } else if (startsWith(line, "const ") or startsWith(line, "var ")) {
        const skip = if (startsWith(line, "const ")) @as(usize, 6) else 4;
        if (extractIdent(line[skip..])) |name| {
            const kind: SymbolKind = if (startsWith(line, "const ")) .constant else .variable;
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
    }
}
