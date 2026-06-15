const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;
const SymbolKind = types.SymbolKind;
const PhpParseState = types.PhpParseState;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const extractIdent = parse_utils.extractIdent;
const appendOutlineSymbolWithTypes = parse_utils.appendOutlineSymbolWithTypes;
const extractPythonModulePath = parse_utils.extractPythonModulePath;
const phpNamespaceToPath = parse_utils.phpNamespaceToPath;
const extractRubyMethodName = parse_utils.extractRubyMethodName;
const extractStringLiteral = parse_utils.extractStringLiteral;

pub fn parsePythonLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    if (startsWith(line, "def ")) {
        if (extractIdent(line[4..])) |name| {
            var py_param_buf: [16][]const u8 = undefined;
            const py_types = Explorer.extractPythonFuncTypes(line, &py_param_buf);
            const py_params = py_param_buf[0..py_types.param_count];
            try appendOutlineSymbolWithTypes(a, outline, name, .function, line_num, line, py_types.ret, py_params);
        }
    } else if (startsWith(line, "class ")) {
        if (extractIdent(line[6..])) |name| {
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
    } else if (startsWith(line, "import ") or startsWith(line, "from ")) {
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
        // Extract module path and convert dots to slashes for dep matching.
        // "from mypackage.utils.helpers import X" → "mypackage/utils/helpers.py"
        // "import os.path" → "os/path.py"
        if (extractPythonModulePath(line)) |mod_path| {
            var buf: [512]u8 = undefined;
            var pos: usize = 0;
            for (mod_path) |c| {
                if (pos >= buf.len - 3) break;
                buf[pos] = if (c == '.') '/' else c;
                pos += 1;
            }
            if (pos + 3 <= buf.len) {
                buf[pos] = '.';
                buf[pos + 1] = 'p';
                buf[pos + 2] = 'y';
                pos += 3;
            }
            const import_copy = try a.dupe(u8, buf[0..pos]);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        }
    }
}

pub fn parsePhpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline, state: *PhpParseState) !void {
    const a = self.allocator;

    var line = raw_line;
    if (line.len == 0) return;
    if (state.in_block_comment) {
        if (std.mem.indexOf(u8, line, "*/")) |end| {
            state.in_block_comment = false;
            line = std.mem.trim(u8, line[end + 2 ..], " \t");
            if (line.len == 0) return;
        } else return;
    }
    if (startsWith(line, "<?php")) return;
    if (startsWith(line, "//") or startsWith(line, "#")) return;
    if (startsWith(line, "/*")) {
        if (std.mem.indexOf(u8, line, "*/") == null) state.in_block_comment = true;
        return;
    }

    if (startsWith(line, "use ") and std.mem.indexOf(u8, line, "\\") != null) {
        try self.parsePhpUseImport(a, line, line_num, outline);
        return;
    }

    if (self.phpMatchClassLike(line)) |match| {
        const name_copy = try a.dupe(u8, match.name);
        errdefer a.free(name_copy);
        const detail_copy = try a.dupe(u8, line);
        errdefer a.free(detail_copy);
        try outline.symbols.append(a, .{
            .name = name_copy,
            .kind = match.kind,
            .line_start = line_num,
            .line_end = line_num,
            .detail = detail_copy,
        });
        state.in_class = true;
        state.class_brace_depth = state.brace_depth;
    } else if (self.phpMatchConstant(line)) |name| {
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
    } else if (std.mem.indexOf(u8, line, "function ")) |fn_pos| {
        const after_fn = line[fn_pos + 9 ..];
        if (extractIdent(after_fn)) |name| {
            const kind: SymbolKind = if (state.in_class) .method else .function;
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

    var in_string: u8 = 0;
    var escaped: bool = false;
    for (line) |ch| {
        if (in_string != 0) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == in_string) {
                in_string = 0;
            }
            continue;
        }
        if (ch == '\'' or ch == '"') {
            in_string = ch;
        } else if (ch == '{') {
            state.brace_depth += 1;
        } else if (ch == '}') {
            state.brace_depth -= 1;
            if (state.in_class and state.brace_depth <= state.class_brace_depth) {
                state.in_class = false;
            }
        }
    }
}

pub fn parsePhpUseImport(_: *Explorer, a: std.mem.Allocator, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const use_body = std.mem.trim(u8, line[4..semi], " \t");
    if (use_body.len == 0) return;

    if (std.mem.indexOfScalar(u8, use_body, '{')) |brace_start| {
        const brace_end = std.mem.indexOfScalar(u8, use_body, '}') orelse use_body.len;
        const base = use_body[0..brace_start];
        const items_str = use_body[brace_start + 1 .. brace_end];

        const symbol_copy = try a.dupe(u8, line[0..semi]);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });

        var items = std.mem.splitScalar(u8, items_str, ',');
        while (items.next()) |item| {
            const raw_item = std.mem.trim(u8, item, " \t");
            if (raw_item.len == 0) continue;
            const trimmed_item = phpStripAlias(raw_item);
            const full_ns = try a.alloc(u8, base.len + trimmed_item.len);
            defer a.free(full_ns);
            @memcpy(full_ns[0..base.len], base);
            @memcpy(full_ns[base.len..], trimmed_item);
            const path_copy = try phpNamespaceToPath(a, full_ns);
            errdefer a.free(path_copy);
            try outline.imports.append(a, path_copy);
        }
    } else {
        const symbol_copy = try a.dupe(u8, line[0..semi]);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
        const ns = phpStripAlias(use_body);
        const path_copy = try phpNamespaceToPath(a, ns);
        errdefer a.free(path_copy);
        try outline.imports.append(a, path_copy);
    }
}

pub fn phpStripAlias(s: []const u8) []const u8 {
    if (s.len < 4) return s;
    for (0..s.len - 3) |i| {
        if (s[i] == ' ' and (s[i + 1] == 'a' or s[i + 1] == 'A') and (s[i + 2] == 's' or s[i + 2] == 'S') and s[i + 3] == ' ') return s[0..i];
    }
    return s;
}

pub fn phpMatchConstant(_: *Explorer, line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "const ",
        "public const ",
        "protected const ",
        "private const ",
    };
    for (prefixes) |prefix| {
        if (startsWith(line, prefix)) {
            if (extractIdent(line[prefix.len..])) |name| {
                if (!std.mem.eql(u8, name, "class")) return name;
            }
        }
    }
    return null;
}

pub const PhpClassMatch = struct {
    name: []const u8,
    kind: SymbolKind,
};

pub fn phpMatchClassLike(_: *Explorer, line: []const u8) ?PhpClassMatch {
    const class_keywords = [_]struct { prefix: []const u8, kind: SymbolKind }{
        .{ .prefix = "interface ", .kind = .interface_def },
        .{ .prefix = "trait ", .kind = .trait_def },
        .{ .prefix = "enum ", .kind = .enum_def },
        .{ .prefix = "class ", .kind = .class_def },
        .{ .prefix = "abstract class ", .kind = .class_def },
        .{ .prefix = "final class ", .kind = .class_def },
        .{ .prefix = "readonly class ", .kind = .class_def },
    };

    for (class_keywords) |kw| {
        if (startsWith(line, kw.prefix)) {
            if (extractIdent(line[kw.prefix.len..])) |name| {
                return .{ .name = name, .kind = kw.kind };
            }
        }
    }
    return null;
}

pub fn parseRubyLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    if (startsWith(line, "def ")) {
        // Handle "def self.method_name" — skip past "self."
        var name_start = line[4..];
        if (startsWith(name_start, "self.")) {
            name_start = name_start[5..];
        }
        if (extractRubyMethodName(name_start)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .function,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
    } else if (startsWith(line, "class ")) {
        if (extractIdent(line[6..])) |name| {
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
    } else if (startsWith(line, "module ")) {
        if (extractIdent(line[7..])) |name| {
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
    } else if (startsWith(line, "require ") or startsWith(line, "require_relative ")) {
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
    }
}
