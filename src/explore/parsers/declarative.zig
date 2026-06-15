const std = @import("std");
const Explorer = @import("../../explore.zig").Explorer;
const types = @import("../types.zig");
const FileOutline = types.FileOutline;
const SymbolKind = types.SymbolKind;

const parse_utils = @import("../parse_utils.zig");
const startsWith = parse_utils.startsWith;
const startsWithIgnoreCase = parse_utils.startsWithIgnoreCase;
const appendOutlineSymbol = parse_utils.appendOutlineSymbol;
const appendImportSymbol = parse_utils.appendImportSymbol;
const extractIdent = parse_utils.extractIdent;
const extractIdentAfterKeyword = parse_utils.extractIdentAfterKeyword;
const extractIdentAfterKeywordIgnoreCase = parse_utils.extractIdentAfterKeywordIgnoreCase;
const extractLastIdent = parse_utils.extractLastIdent;
const stripLineComment = parse_utils.stripLineComment;
const stripSqlLineComment = parse_utils.stripSqlLineComment;
const parseSqlCreate = parse_utils.parseSqlCreate;
const stripFortranComment = parse_utils.stripFortranComment;
const parseFortranUse = parse_utils.parseFortranUse;
const parseFortranTypeName = parse_utils.parseFortranTypeName;
const extractAtName = parse_utils.extractAtName;
const extractLlvmGlobalName = parse_utils.extractLlvmGlobalName;
const extractStringLiteral = parse_utils.extractStringLiteral;
const resolveDartImport = parse_utils.resolveDartImport;
const containsAny = parse_utils.containsAny;
const firstIndexOfAny = parse_utils.firstIndexOfAny;
const extractHclQuotedName = parse_utils.extractHclQuotedName;
const extractHclBlockName = parse_utils.extractHclBlockName;

pub fn parseSqlLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripSqlLineComment(raw_line);
    if (line.len == 0) return;

    if (parseSqlCreate(line)) |sym| {
        try appendOutlineSymbol(a, outline, sym.name, sym.kind, line_num, line);
    }
}

pub fn parseProtoLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0) return;

    if (startsWith(line, "import ")) {
        if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
    } else if (extractIdentAfterKeyword(line, "message ")) |name| {
        try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "enum ")) |name| {
        try appendOutlineSymbol(a, outline, name, .enum_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "service ")) |name| {
        try appendOutlineSymbol(a, outline, name, .interface_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "rpc ")) |name| {
        try appendOutlineSymbol(a, outline, name, .method, line_num, line);
    }
}

pub fn parseFortranLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripFortranComment(raw_line);
    if (line.len == 0) return;

    if (parseFortranUse(line)) |imp| {
        try appendImportSymbol(a, outline, imp, line_num, line);
    } else if (extractIdentAfterKeywordIgnoreCase(line, "module ")) |name| {
        if (!startsWithIgnoreCase(line, "module procedure ")) try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeywordIgnoreCase(line, "program ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (extractIdentAfterKeywordIgnoreCase(line, "subroutine ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (extractIdentAfterKeywordIgnoreCase(line, "function ")) |name| {
        try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (parseFortranTypeName(line)) |name| {
        try appendOutlineSymbol(a, outline, name, .struct_def, line_num, line);
    }
}

pub fn parseLlvmIrLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = std.mem.trim(u8, raw_line, " \t");
    if (line.len == 0 or startsWith(line, ";")) return;

    if (startsWith(line, "define ") or startsWith(line, "declare ")) {
        if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    } else if (line[0] == '@') {
        if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
    } else if (line[0] == '%' and std.mem.indexOf(u8, line, " = type") != null) {
        if (extractLlvmGlobalName(line)) |name| try appendOutlineSymbol(a, outline, name, .type_alias, line_num, line);
    }
}

pub fn parseMlirLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0) return;

    if (std.mem.indexOf(u8, line, "module @") != null) {
        if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (std.mem.indexOf(u8, line, "func") != null and std.mem.indexOfScalar(u8, line, '@') != null) {
        if (extractAtName(line)) |name| try appendOutlineSymbol(a, outline, name, .function, line_num, line);
    }
}

pub fn parseTableGenLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;
    const line = stripLineComment(raw_line);
    if (line.len == 0) return;

    if (startsWith(line, "include ")) {
        if (extractStringLiteral(line)) |imp| try appendImportSymbol(a, outline, imp, line_num, line);
    } else if (extractIdentAfterKeyword(line, "defm ")) |name| {
        try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
    } else if (extractIdentAfterKeyword(line, "def ")) |name| {
        try appendOutlineSymbol(a, outline, name, .constant, line_num, line);
    } else if (extractIdentAfterKeyword(line, "multiclass ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "class ")) |name| {
        try appendOutlineSymbol(a, outline, name, .class_def, line_num, line);
    } else if (extractIdentAfterKeyword(line, "let ")) |name| {
        try appendOutlineSymbol(a, outline, name, .variable, line_num, line);
    }
}

pub fn parseDartLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;

    if (line.len == 0 or startsWith(line, "@")) return;

    if (startsWith(line, "import ") or startsWith(line, "export ") or
        (startsWith(line, "part ") and !startsWith(line, "part of ")))
    {
        if (extractStringLiteral(line)) |raw_path| {
            if (resolveDartImport(raw_path, outline.path, a)) |resolved| {
                try outline.imports.append(a, resolved);
            }
        }
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{
            .name = symbol_copy,
            .kind = .import,
            .line_start = line_num,
            .line_end = line_num,
        });
        return;
    }

    if (startsWith(line, "typedef ")) {
        if (extractIdent(line["typedef ".len..])) |name| {
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
        return;
    }

    var type_decl = line;
    const type_modifiers = [_][]const u8{ "abstract ", "base ", "final ", "sealed ", "interface " };
    while (true) {
        var stripped = false;
        for (type_modifiers) |modifier| {
            if (startsWith(type_decl, modifier)) {
                type_decl = type_decl[modifier.len..];
                stripped = true;
                break;
            }
        }
        if (!stripped) break;
    }

    const TypeDecl = struct {
        prefix: []const u8,
        kind: SymbolKind,
    };
    const type_decls = [_]TypeDecl{
        .{ .prefix = "mixin class ", .kind = .class_def },
        .{ .prefix = "class ", .kind = .class_def },
        .{ .prefix = "enum ", .kind = .enum_def },
        .{ .prefix = "mixin ", .kind = .trait_def },
        .{ .prefix = "extension type ", .kind = .class_def },
        .{ .prefix = "extension ", .kind = .impl_block },
    };
    for (type_decls) |decl| {
        if (!startsWith(type_decl, decl.prefix)) continue;

        const after = std.mem.trimStart(u8, type_decl[decl.prefix.len..], " \t");
        if (decl.kind == .impl_block and startsWith(after, "on ")) return;
        if (extractIdent(after)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = decl.kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        }
        return;
    }

    var var_decl = line;
    var var_kind: ?SymbolKind = null;
    while (true) {
        if (startsWith(var_decl, "static ")) {
            var_decl = std.mem.trimStart(u8, var_decl["static ".len..], " \t");
            continue;
        }
        if (startsWith(var_decl, "late ")) {
            var_decl = std.mem.trimStart(u8, var_decl["late ".len..], " \t");
            continue;
        }
        if (startsWith(var_decl, "covariant ")) {
            var_decl = std.mem.trimStart(u8, var_decl["covariant ".len..], " \t");
            continue;
        }
        if (startsWith(var_decl, "const ")) {
            var_kind = .constant;
            var_decl = std.mem.trimStart(u8, var_decl["const ".len..], " \t");
            continue;
        }
        if (startsWith(var_decl, "final ") or startsWith(var_decl, "var ")) {
            var_kind = .variable;
            const skip = if (startsWith(var_decl, "final ")) @as(usize, "final ".len) else "var ".len;
            var_decl = std.mem.trimStart(u8, var_decl[skip..], " \t");
            continue;
        }
        break;
    }
    if (var_kind) |kind| {
        const boundary = firstIndexOfAny(var_decl, &.{ '=', ';' }) orelse var_decl.len;
        const prefix = std.mem.trimEnd(u8, var_decl[0..boundary], " \t");
        if (std.mem.indexOfScalar(u8, prefix, '(') == null) {
            if (extractLastIdent(prefix)) |name| {
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
        return;
    }

    if (std.mem.indexOf(u8, line, " get ") != null) {
        const get_pos = std.mem.indexOf(u8, line, " get ").?;
        const after_get = std.mem.trimStart(u8, line[get_pos + " get ".len ..], " \t");
        if (extractIdent(after_get)) |name| {
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
            return;
        }
    }

    if (containsAny(line, &.{ "(", "=>", "{", ";" })) {
        const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return;
        const prefix = std.mem.trimEnd(u8, line[0..open_paren], " \t");
        if (prefix.len == 0) return;
        if (containsAny(prefix, &.{ "=", "." })) return;
        if (startsWith(prefix, "if") or startsWith(prefix, "for") or startsWith(prefix, "while") or
            startsWith(prefix, "switch") or startsWith(prefix, "catch") or startsWith(prefix, "return") or
            startsWith(prefix, "throw") or startsWith(prefix, "assert") or startsWith(prefix, "await") or
            startsWith(prefix, "new ") or startsWith(prefix, "const "))
        {
            return;
        }

        var callable = prefix;
        const callable_modifiers = [_][]const u8{
            "external ",
            "static ",
            "factory ",
            "covariant ",
            "late ",
            "final ",
            "const ",
        };
        while (true) {
            var stripped = false;
            for (callable_modifiers) |modifier| {
                if (startsWith(callable, modifier)) {
                    callable = std.mem.trimStart(u8, callable[modifier.len..], " \t");
                    stripped = true;
                    break;
                }
            }
            if (!stripped) break;
        }
        if (startsWith(callable, "operator ")) return;
        var is_setter = false;
        if (startsWith(callable, "set ")) {
            callable = std.mem.trimStart(u8, callable["set ".len..], " \t");
            is_setter = true;
        }
        if (!is_setter and std.mem.indexOfScalar(u8, callable, ' ') == null) return;
        if (extractLastIdent(callable)) |name| {
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
    }
}

pub fn parseHclLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;

    // resource "type" "name" {
    if (startsWith(line, "resource ")) {
        if (extractHclBlockName(line[9..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
    } else if (startsWith(line, "data ")) {
        if (extractHclBlockName(line[5..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
    } else if (startsWith(line, "module ")) {
        if (extractHclQuotedName(line[7..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
        }
    } else if (startsWith(line, "variable ")) {
        if (extractHclQuotedName(line[9..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .variable, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
    } else if (startsWith(line, "output ")) {
        if (extractHclQuotedName(line[7..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .constant, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
    } else if (startsWith(line, "provider ")) {
        if (extractHclQuotedName(line[9..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
        }
    } else if (startsWith(line, "locals ") or startsWith(line, "locals{") or std.mem.eql(u8, line, "locals")) {
        const name_copy = try a.dupe(u8, "locals");
        errdefer a.free(name_copy);
        try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num });
    } else if (startsWith(line, "terraform ") or startsWith(line, "terraform{") or std.mem.eql(u8, line, "terraform")) {
        const name_copy = try a.dupe(u8, "terraform");
        errdefer a.free(name_copy);
        try outline.symbols.append(a, .{ .name = name_copy, .kind = .struct_def, .line_start = line_num, .line_end = line_num });
    }
}

pub fn parseRLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
    const a = self.allocator;

    // library(pkg) or require(pkg)
    if (startsWith(line, "library(") or startsWith(line, "require(")) {
        const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
        const close = std.mem.indexOfScalar(u8, line[open..], ')') orelse return;
        const pkg = std.mem.trim(u8, line[open + 1 .. open + close], " \t\"'");
        if (pkg.len == 0) return;
        const import_copy = try a.dupe(u8, pkg);
        errdefer a.free(import_copy);
        try outline.imports.append(a, import_copy);
        const symbol_copy = try a.dupe(u8, line);
        errdefer a.free(symbol_copy);
        try outline.symbols.append(a, .{ .name = symbol_copy, .kind = .import, .line_start = line_num, .line_end = line_num });
        return;
    }

    // setClass("ClassName") or setRefClass("ClassName")
    if (startsWith(line, "setClass(") or startsWith(line, "setRefClass(")) {
        const open = std.mem.indexOfScalar(u8, line, '(') orelse return;
        if (extractHclQuotedName(line[open + 1 ..])) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{ .name = name_copy, .kind = .class_def, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
        }
        return;
    }

    // name <- function( or name = function(
    if (std.mem.indexOf(u8, line, "<- function(") != null or std.mem.indexOf(u8, line, "= function(") != null) {
        const assign_pos = std.mem.indexOf(u8, line, "<-") orelse std.mem.indexOf(u8, line, "=") orelse return;
        const name = std.mem.trim(u8, line[0..assign_pos], " \t");
        if (name.len == 0) return;
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '.') return;
        const name_copy = try a.dupe(u8, name);
        errdefer a.free(name_copy);
        const detail_copy = try a.dupe(u8, line);
        errdefer a.free(detail_copy);
        try outline.symbols.append(a, .{ .name = name_copy, .kind = .function, .line_start = line_num, .line_end = line_num, .detail = detail_copy });
    }
}
