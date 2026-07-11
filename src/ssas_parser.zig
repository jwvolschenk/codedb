//! Zero-dependency structural parser for SSAS, DAX, MDX, TMDL, and projects.
//!
//! JSON/TMSL is decoded with Zig's standard JSON parser. The text formats use
//! deliberately bounded scanners: malformed or incomplete input may yield a
//! partial outline, but never causes an out-of-bounds read or parser panic.

const std = @import("std");
const cio = @import("cio.zig");
const types = @import("explore/types.zig");
const FileOutline = types.FileOutline;
const SymbolKind = types.SymbolKind;

const max_detail_len = 320;

pub fn parse(allocator: std.mem.Allocator, path: []const u8, content: []const u8, outline: *FileOutline) !void {
    outline.line_count = countLines(content);
    switch (outline.language) {
        .ssas_tabular => try parseTabularJson(allocator, content, outline),
        .tmdl => try parseTmdl(allocator, content, outline),
        .dax => try parseDax(allocator, content, outline),
        .mdx => try parseMdx(allocator, content, outline, 0),
        .ssas_cube => try parseCubeXml(allocator, content, outline),
        .ssas_project => try parseProject(allocator, path, content, outline),
        else => {},
    }
}

fn parseTabularJson(allocator: std.mem.Allocator, content: []const u8, outline: *FileOutline) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();
    const model = findModel(parsed.value) orelse return;
    if (model != .object) return;
    var cursor: usize = 0;

    if (model.object.get("tables")) |tables| if (tables == .array) {
        for (tables.array.items) |table| {
            if (table != .object) continue;
            const name = objectString(table.object, "name") orelse continue;
            const is_calc_group = table.object.get("calculationGroup") != null;
            try appendJsonSymbol(allocator, outline, content, &cursor, name, .class_def, if (is_calc_group) "subtype=calculation_group" else "subtype=table");

            if (table.object.get("columns")) |columns| if (columns == .array) {
                for (columns.array.items) |column| {
                    if (column != .object) continue;
                    const col_name = objectString(column.object, "name") orelse continue;
                    const data_type = objectString(column.object, "dataType");
                    const expression = column.object.get("expression");
                    const subtype = if (expression != null) "calculated_column" else "column";
                    const detail = try makeDetail(allocator, name, subtype, data_type, expression);
                    defer allocator.free(detail);
                    try appendJsonSymbol(allocator, outline, content, &cursor, col_name, .variable, detail);
                }
            };

            if (table.object.get("measures")) |measures| if (measures == .array) {
                for (measures.array.items) |measure| {
                    if (measure != .object) continue;
                    const measure_name = objectString(measure.object, "name") orelse continue;
                    const detail = try makeDetail(allocator, name, "measure", null, measure.object.get("expression"));
                    defer allocator.free(detail);
                    try appendJsonSymbol(allocator, outline, content, &cursor, measure_name, .function, detail);
                }
            };

            if (table.object.get("hierarchies")) |hierarchies| if (hierarchies == .array) {
                for (hierarchies.array.items) |hierarchy| {
                    if (hierarchy != .object) continue;
                    const hierarchy_name = objectString(hierarchy.object, "name") orelse continue;
                    const detail = try std.fmt.allocPrint(allocator, "table={s}; subtype=hierarchy", .{name});
                    defer allocator.free(detail);
                    try appendJsonSymbol(allocator, outline, content, &cursor, hierarchy_name, .struct_def, detail);
                }
            };

            if (table.object.get("partitions")) |partitions| if (partitions == .array) {
                for (partitions.array.items) |partition| {
                    if (partition != .object) continue;
                    const partition_name = objectString(partition.object, "name") orelse continue;
                    var partition_type: ?[]const u8 = objectString(partition.object, "mode");
                    if (partition.object.get("source")) |source| if (source == .object) {
                        partition_type = objectString(source.object, "type") orelse partition_type;
                    };
                    const detail = try makeDetail(allocator, name, "partition", partition_type, null);
                    defer allocator.free(detail);
                    try appendJsonSymbol(allocator, outline, content, &cursor, partition_name, .type_alias, detail);
                }
            };

            if (table.object.get("calculationGroup")) |group| if (group == .object) {
                if (group.object.get("calculationItems")) |items| if (items == .array) {
                    for (items.array.items) |item| {
                        if (item != .object) continue;
                        const item_name = objectString(item.object, "name") orelse continue;
                        const detail = try makeDetail(allocator, name, "calculation_item", null, item.object.get("expression"));
                        defer allocator.free(detail);
                        try appendJsonSymbol(allocator, outline, content, &cursor, item_name, .function, detail);
                    }
                };
            };
        }
    };

    if (model.object.get("relationships")) |relationships| if (relationships == .array) {
        for (relationships.array.items) |relationship| {
            if (relationship != .object) continue;
            const from_table = objectString(relationship.object, "fromTable") orelse "?";
            const from_column = objectString(relationship.object, "fromColumn") orelse "?";
            const to_table = objectString(relationship.object, "toTable") orelse "?";
            const to_column = objectString(relationship.object, "toColumn") orelse "?";
            const generated = try std.fmt.allocPrint(allocator, "{s}[{s}] -> {s}[{s}]", .{ from_table, from_column, to_table, to_column });
            defer allocator.free(generated);
            const rel_name = objectString(relationship.object, "name") orelse generated;
            const detail = try std.fmt.allocPrint(allocator, "subtype=relationship; from={s}[{s}]; to={s}[{s}]", .{ from_table, from_column, to_table, to_column });
            defer allocator.free(detail);
            try appendJsonSymbol(allocator, outline, content, &cursor, rel_name, .type_alias, detail);
        }
    };

    try appendNamedArray(allocator, outline, content, &cursor, model.object.get("perspectives"), "perspective");
    try appendNamedArray(allocator, outline, content, &cursor, model.object.get("roles"), "role");
}

fn findModel(root: std.json.Value) ?std.json.Value {
    if (root != .object) return null;
    if (root.object.get("model")) |model| return model;
    if (root.object.get("tables") != null) return root;
    if (root.object.get("database")) |database| {
        if (database == .object) {
            if (database.object.get("model")) |model| return model;
            if (database.object.get("tables") != null) return database;
        }
    }
    if (root.object.get("createOrReplace")) |command| return findModel(command);
    if (root.object.get("create")) |command| return findModel(command);
    return null;
}

fn appendNamedArray(allocator: std.mem.Allocator, outline: *FileOutline, content: []const u8, cursor: *usize, maybe: ?std.json.Value, subtype: []const u8) !void {
    const value = maybe orelse return;
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name = objectString(item.object, "name") orelse continue;
        var detail_buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "subtype={s}", .{subtype}) catch "subtype=object";
        try appendJsonSymbol(allocator, outline, content, cursor, name, .type_alias, detail);
    }
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn makeDetail(allocator: std.mem.Allocator, owner: ?[]const u8, subtype: []const u8, data_type: ?[]const u8, expression: ?std.json.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = cio.listWriter(&buf, allocator);
    if (owner) |name| try w.print("table={s}; ", .{name});
    try w.print("subtype={s}", .{subtype});
    if (data_type) |dt| try w.print("; data_type={s}", .{dt});
    if (expression) |expr| {
        var preview_buf: [160]u8 = undefined;
        const preview = expressionPreview(expr, &preview_buf);
        if (preview.len > 0) try w.print("; expression={s}", .{preview});
    }
    const owned = try buf.toOwnedSlice(allocator);
    if (owned.len <= max_detail_len) return owned;
    const bounded = try allocator.dupe(u8, owned[0..max_detail_len]);
    allocator.free(owned);
    return bounded;
}

fn expressionPreview(value: std.json.Value, out: []u8) []const u8 {
    var pos: usize = 0;
    switch (value) {
        .string => appendSanitizedExpression(out, &pos, value.string),
        .array => for (value.array.items) |part| {
            if (part != .string or pos >= out.len) continue;
            if (pos > 0 and pos < out.len) {
                out[pos] = ' ';
                pos += 1;
            }
            appendSanitizedExpression(out, &pos, part.string);
        },
        else => {},
    }
    return std.mem.trim(u8, out[0..pos], " \t\r\n");
}

fn appendSanitizedExpression(out: []u8, pos: *usize, expression: []const u8) void {
    var quote: u8 = 0;
    var emitted_placeholder = false;
    var i: usize = 0;
    while (i < expression.len and pos.* < out.len) : (i += 1) {
        const c = expression[i];
        if (quote != 0) {
            if (!emitted_placeholder and pos.* + 3 <= out.len) {
                @memcpy(out[pos.* .. pos.* + 3], "...");
                pos.* += 3;
                emitted_placeholder = true;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"') {
            quote = c;
            emitted_placeholder = false;
            continue;
        }
        out[pos.*] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
        pos.* += 1;
    }
}

fn appendJsonSymbol(allocator: std.mem.Allocator, outline: *FileOutline, content: []const u8, cursor: *usize, name: []const u8, kind: SymbolKind, detail: []const u8) !void {
    const pos = std.mem.indexOfPos(u8, content, cursor.*, name) orelse std.mem.indexOf(u8, content, name) orelse 0;
    cursor.* = @min(content.len, pos + name.len);
    try appendSymbol(allocator, outline, name, kind, lineAt(content, pos), detail);
}

fn parseTmdl(allocator: std.mem.Allocator, content: []const u8, outline: *FileOutline) !void {
    var owner: ?[]u8 = null;
    defer if (owner) |name| allocator.free(name);
    var owner_indent: usize = 0;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    var in_block_comment = false;
    while (line_it.next()) |raw_line| {
        line_num += 1;
        const clean = stripTextComments(raw_line, &in_block_comment, true);
        const trimmed = std.mem.trim(u8, clean, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = countIndent(raw_line);
        if (owner != null and indent <= owner_indent and !startsWithKeyword(trimmed, "table")) {
            allocator.free(owner.?);
            owner = null;
        }

        const specs = [_]struct { keyword: []const u8, kind: SymbolKind, subtype: []const u8 }{
            .{ .keyword = "table", .kind = .class_def, .subtype = "table" },
            .{ .keyword = "calculationGroup", .kind = .class_def, .subtype = "calculation_group" },
            .{ .keyword = "column", .kind = .variable, .subtype = "column" },
            .{ .keyword = "calculatedColumn", .kind = .variable, .subtype = "calculated_column" },
            .{ .keyword = "measure", .kind = .function, .subtype = "measure" },
            .{ .keyword = "calculationItem", .kind = .function, .subtype = "calculation_item" },
            .{ .keyword = "function", .kind = .function, .subtype = "dax_function" },
            .{ .keyword = "hierarchy", .kind = .struct_def, .subtype = "hierarchy" },
            .{ .keyword = "partition", .kind = .type_alias, .subtype = "partition" },
            .{ .keyword = "relationship", .kind = .type_alias, .subtype = "relationship" },
            .{ .keyword = "role", .kind = .type_alias, .subtype = "role" },
            .{ .keyword = "perspective", .kind = .type_alias, .subtype = "perspective" },
            .{ .keyword = "expression", .kind = .type_alias, .subtype = "shared_expression" },
        };
        for (specs) |spec| {
            if (!startsWithKeyword(trimmed, spec.keyword)) continue;
            const raw_name = std.mem.trimStart(u8, trimmed[spec.keyword.len..], " \t");
            const name = try parseTmdlName(allocator, raw_name);
            defer allocator.free(name);
            if (name.len == 0) break;
            const detail = if (owner) |table_name|
                try std.fmt.allocPrint(allocator, "table={s}; subtype={s}", .{ table_name, spec.subtype })
            else
                try std.fmt.allocPrint(allocator, "subtype={s}", .{spec.subtype});
            defer allocator.free(detail);
            try appendSymbol(allocator, outline, name, spec.kind, line_num, detail);
            if (std.mem.eql(u8, spec.keyword, "table")) {
                if (owner) |old| allocator.free(old);
                owner = try allocator.dupe(u8, name);
                owner_indent = indent;
            }
            break;
        }
    }
}

fn parseTmdlName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "");
    if (raw[0] == '\'') {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var i: usize = 1;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\'') {
                if (i + 1 < raw.len and raw[i + 1] == '\'') {
                    try out.append(allocator, '\'');
                    i += 1;
                    continue;
                }
                break;
            }
            try out.append(allocator, raw[i]);
        }
        return out.toOwnedSlice(allocator);
    }
    var end: usize = 0;
    while (end < raw.len and !std.ascii.isWhitespace(raw[end]) and raw[end] != '=' and raw[end] != ':') : (end += 1) {}
    return allocator.dupe(u8, raw[0..end]);
}

fn parseDax(allocator: std.mem.Allocator, content: []const u8, outline: *FileOutline) !void {
    var state = TextState{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (lines.next()) |raw| {
        line_num += 1;
        var scratch: [4096]u8 = undefined;
        const clean = sanitizeCodeLine(raw, &state, &scratch, .dax);
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;
        var rest = line;
        if (startsWithKeyword(rest, "DEFINE")) rest = std.mem.trimStart(u8, rest[6..], " \t");
        const specs = [_]struct { keyword: []const u8, kind: SymbolKind, subtype: []const u8 }{
            .{ .keyword = "MEASURE", .kind = .function, .subtype = "measure" },
            .{ .keyword = "FUNCTION", .kind = .function, .subtype = "dax_function" },
            .{ .keyword = "VAR", .kind = .variable, .subtype = "variable" },
            .{ .keyword = "TABLE", .kind = .class_def, .subtype = "table" },
            .{ .keyword = "COLUMN", .kind = .variable, .subtype = "column" },
        };
        var matched = false;
        for (specs) |spec| {
            if (!startsWithKeyword(rest, spec.keyword)) continue;
            const declaration = std.mem.trimStart(u8, rest[spec.keyword.len..], " \t");
            const name = daxDeclarationName(declaration);
            if (name.len > 0) {
                var detail_buf: [128]u8 = undefined;
                const detail = std.fmt.bufPrint(&detail_buf, "subtype={s}", .{spec.subtype}) catch "subtype=dax_object";
                try appendSymbol(allocator, outline, name, spec.kind, line_num, detail);
            }
            matched = true;
            break;
        }
        if (matched) continue;
        if (startsWithKeyword(line, "EVALUATE")) {
            try appendSymbol(allocator, outline, "EVALUATE", .function, line_num, "subtype=query_block");
            continue;
        }
        if (std.mem.indexOf(u8, line, ":=")) |assign| {
            const name = daxDeclarationName(std.mem.trim(u8, line[0..assign], " \t"));
            if (name.len > 0) try appendSymbol(allocator, outline, name, .function, line_num, "subtype=calculated_object");
        }
    }
}

fn daxDeclarationName(raw: []const u8) []const u8 {
    const before_eq = if (std.mem.indexOfScalar(u8, raw, '=')) |eq| raw[0..eq] else raw;
    const trimmed = std.mem.trim(u8, before_eq, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '[')) |open| {
        if (std.mem.indexOfScalarPos(u8, trimmed, open + 1, ']')) |close| return trimmed[open + 1 .. close];
    }
    if (trimmed.len > 0 and trimmed[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, trimmed, 1, '\'')) |close| return trimmed[1..close];
    }
    var end: usize = 0;
    while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end]) and trimmed[end] != '(' and trimmed[end] != ':') : (end += 1) {}
    return trimmed[0..end];
}

fn parseMdx(allocator: std.mem.Allocator, content: []const u8, outline: *FileOutline, line_offset: u32) !void {
    var state = TextState{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    var local_line: u32 = 0;
    while (lines.next()) |raw| {
        local_line += 1;
        var scratch: [4096]u8 = undefined;
        const clean = sanitizeCodeLine(raw, &state, &scratch, .mdx);
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;
        const line_num = line_offset + local_line;
        var rest = line;
        if (startsWithKeyword(rest, "WITH")) rest = std.mem.trimStart(u8, rest[4..], " \t");
        if (startsWithKeyword(rest, "CREATE")) rest = std.mem.trimStart(u8, rest[6..], " \t");
        const specs = [_]struct { keyword: []const u8, subtype: []const u8 }{
            .{ .keyword = "MEMBER", .subtype = "member" },
            .{ .keyword = "SET", .subtype = "named_set" },
            .{ .keyword = "CALCULATED CELL", .subtype = "calculated_cell" },
        };
        var matched = false;
        for (specs) |spec| {
            if (!startsWithKeyword(rest, spec.keyword)) continue;
            const name = mdxObjectName(std.mem.trimStart(u8, rest[spec.keyword.len..], " \t"));
            if (name.len > 0) {
                var detail_buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(&detail_buf, "subtype={s}", .{spec.subtype}) catch "subtype=mdx_object";
                try appendSymbol(allocator, outline, name, .function, line_num, detail);
            }
            matched = true;
            break;
        }
        if (matched) continue;
        if (startsWithKeyword(line, "SCOPE")) {
            const name = mdxObjectName(line[5..]);
            try appendSymbol(allocator, outline, if (name.len > 0) name else "SCOPE", .function, line_num, "subtype=scope");
        } else if (startsWithKeyword(line, "SELECT")) {
            try appendSymbol(allocator, outline, "SELECT", .function, line_num, "subtype=query_block");
        } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const name = mdxObjectName(line[0..eq]);
            if (name.len > 0) try appendSymbol(allocator, outline, name, .variable, line_num, "subtype=assignment");
        }
    }
}

fn mdxObjectName(raw: []const u8) []const u8 {
    var end_expr = raw.len;
    if (std.mem.indexOfScalar(u8, raw, ',')) |pos| end_expr = @min(end_expr, pos);
    if (std.mem.indexOfScalar(u8, raw, '=')) |pos| end_expr = @min(end_expr, pos);
    if (indexOfIgnoreCase(raw, " AS ")) |pos| end_expr = @min(end_expr, pos);
    const expr = std.mem.trim(u8, raw[0..end_expr], " \t();");
    if (std.mem.lastIndexOfScalar(u8, expr, '[')) |open| {
        if (std.mem.indexOfScalarPos(u8, expr, open + 1, ']')) |close| return expr[open + 1 .. close];
    }
    var end: usize = 0;
    while (end < expr.len and !std.ascii.isWhitespace(expr[end])) : (end += 1) {}
    return expr[0..end];
}

fn parseCubeXml(allocator: std.mem.Allocator, content: []const u8, outline: *FileOutline) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], "<![CDATA[")) {
            const start = i + 9;
            const close = std.mem.indexOfPos(u8, content, start, "]]>") orelse content.len;
            try decoded.appendSlice(allocator, content[start..close]);
            i = if (close < content.len) close + 3 else close;
            continue;
        }
        if (content[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, content, i + 1, '>') orelse break;
            try decoded.append(allocator, '\n');
            i = close + 1;
            continue;
        }
        if (content[i] == '&') {
            const entities = [_]struct { encoded: []const u8, decoded: u8 }{
                .{ .encoded = "&lt;", .decoded = '<' },    .{ .encoded = "&gt;", .decoded = '>' },
                .{ .encoded = "&amp;", .decoded = '&' },   .{ .encoded = "&quot;", .decoded = '"' },
                .{ .encoded = "&apos;", .decoded = '\'' },
            };
            var found = false;
            for (entities) |entity| if (std.mem.startsWith(u8, content[i..], entity.encoded)) {
                try decoded.append(allocator, entity.decoded);
                i += entity.encoded.len;
                found = true;
                break;
            };
            if (found) continue;
        }
        try decoded.append(allocator, content[i]);
        i += 1;
    }
    try parseMdx(allocator, decoded.items, outline, 0);
}

fn parseProject(allocator: std.mem.Allocator, path: []const u8, content: []const u8, outline: *FileOutline) !void {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    try appendSymbol(allocator, outline, basename[0..dot], .class_def, 1, "subtype=ssas_project");
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: u32 = 0;
    while (lines.next()) |line| {
        line_num += 1;
        if (indexOfIgnoreCase(line, "include=\"") orelse indexOfIgnoreCase(line, "include='")) |pos| {
            const quote_pos = pos + "include=".len;
            if (quote_pos >= line.len) continue;
            const quote = line[quote_pos];
            if (quote != '"' and quote != '\'') continue;
            const end = std.mem.indexOfScalarPos(u8, line, quote_pos + 1, quote) orelse continue;
            const include = line[quote_pos + 1 .. end];
            if (!isModelInclude(include)) continue;
            try appendImport(allocator, outline, include, line_num);
        }
    }
}

fn isModelInclude(path: []const u8) bool {
    const exts = [_][]const u8{ ".bim", ".tmdl", ".dax", ".mdx", ".cube", ".xmla" };
    for (exts) |ext| if (endsWithIgnoreCase(path, ext)) return true;
    return false;
}

fn appendSymbol(allocator: std.mem.Allocator, outline: *FileOutline, name: []const u8, kind: SymbolKind, line_num: u32, detail: []const u8) !void {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const bounded_detail = detail[0..@min(detail.len, max_detail_len)];
    const detail_copy = try allocator.dupe(u8, bounded_detail);
    errdefer allocator.free(detail_copy);
    try outline.symbols.append(allocator, .{
        .name = name_copy,
        .kind = kind,
        .line_start = line_num,
        .line_end = line_num,
        .detail = detail_copy,
    });
}

fn appendImport(allocator: std.mem.Allocator, outline: *FileOutline, path: []const u8, line_num: u32) !void {
    try appendSymbol(allocator, outline, path, .import, line_num, "subtype=model_include");
    try outline.imports.append(allocator, try allocator.dupe(u8, path));
}

const TextState = struct { block_comment: bool = false, string_quote: u8 = 0 };
const TextDialect = enum { dax, mdx };

fn sanitizeCodeLine(line: []const u8, state: *TextState, out: []u8, dialect: TextDialect) []const u8 {
    var oi: usize = 0;
    var i: usize = 0;
    while (i < line.len and oi < out.len) {
        if (state.block_comment) {
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                state.block_comment = false;
                i += 2;
            } else i += 1;
            continue;
        }
        if (state.string_quote != 0) {
            const quote = state.string_quote;
            if (line[i] == quote) {
                if (i + 1 < line.len and line[i + 1] == quote) {
                    i += 2;
                    continue;
                }
                state.string_quote = 0;
            }
            i += 1;
            continue;
        }
        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
            state.block_comment = true;
            i += 2;
            continue;
        }
        if (i + 1 < line.len and ((line[i] == '/' and line[i + 1] == '/') or (line[i] == '-' and line[i + 1] == '-'))) break;
        if (line[i] == '"') {
            state.string_quote = '"';
            i += 1;
            continue;
        }
        if (dialect == .mdx and line[i] == '\'') {
            state.string_quote = '\'';
            i += 1;
            continue;
        }
        out[oi] = line[i];
        oi += 1;
        i += 1;
    }
    return out[0..oi];
}

fn stripTextComments(line: []const u8, in_block: *bool, allow_slash: bool) []const u8 {
    if (in_block.*) {
        if (std.mem.indexOf(u8, line, "*/")) |end| {
            in_block.* = false;
            return line[end + 2 ..];
        }
        return "";
    }
    if (allow_slash) if (std.mem.indexOf(u8, line, "/*")) |start| {
        if (std.mem.indexOfPos(u8, line, start + 2, "*/") == null) in_block.* = true;
        return line[0..start];
    };
    if (std.mem.indexOf(u8, line, "//")) |pos| return line[0..pos];
    return line;
}

fn startsWithKeyword(line: []const u8, keyword: []const u8) bool {
    if (line.len < keyword.len) return false;
    for (line[0..keyword.len], keyword) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return line.len == keyword.len or std.ascii.isWhitespace(line[keyword.len]) or line[keyword.len] == '(';
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (haystack[i .. i + needle.len], needle) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
            matches = false;
            break;
        };
        if (matches) return i;
    }
    return null;
}

fn lineAt(content: []const u8, pos: usize) u32 {
    var line: u32 = 1;
    for (content[0..@min(pos, content.len)]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

fn countLines(content: []const u8) u32 {
    var lines: u32 = 1;
    for (content) |c| if (c == '\n') {
        lines += 1;
    };
    return lines;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

fn endsWithIgnoreCase(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    for (path[path.len - suffix.len ..], suffix) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    return true;
}
