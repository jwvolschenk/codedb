const std = @import("std");
const Explorer = @import("explore.zig").Explorer;
const FileOutline = @import("explore.zig").FileOutline;
const SymbolKind = @import("explore.zig").SymbolKind;

const max_declaration_tokens = 4096;
const max_declaration_lines = 128;

const TokenKind = enum { ident, string, punct, arrow };

const Token = struct {
    kind: TokenKind,
    text: []const u8,
    start: usize,
    end: usize,
    line: u32,
};

pub fn parse(explorer: *Explorer, content: []const u8, outline: *FileOutline) !void {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(explorer.allocator);
    try lex(explorer.allocator, content, &tokens);
    try parseModule(explorer, content, tokens.items, outline);
}

fn lex(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Token)) !void {
    var i: usize = 0;
    var line: u32 = 1;
    var can_start_regex = true;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            i += 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i < source.len) {
                if (source[i] == '\n') line += 1;
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            const start = i;
            const start_line = line;
            const quote = c;
            i += 1;
            const value_start = i;
            while (i < source.len) {
                if (source[i] == '\n') {
                    line += 1;
                    // A normal JS string cannot cross an unescaped newline. Recover
                    // there rather than hiding the remainder of a malformed file.
                    break;
                }
                if (source[i] == '\\') {
                    i += @min(@as(usize, 2), source.len - i);
                    continue;
                }
                if (source[i] == quote) break;
                i += 1;
            }
            const value_end = i;
            if (i < source.len and source[i] == quote) i += 1;
            try out.append(allocator, .{ .kind = .string, .text = source[value_start..value_end], .start = start, .end = i, .line = start_line });
            can_start_regex = false;
            continue;
        }
        if (c == '`') {
            // Template contents and interpolations are intentionally opaque. This
            // prevents braces or declaration-looking text from becoming symbols.
            i += 1;
            while (i < source.len) {
                if (source[i] == '\n') line += 1;
                if (source[i] == '\\') {
                    i += @min(@as(usize, 2), source.len - i);
                    continue;
                }
                if (source[i] == '`') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            can_start_regex = false;
            continue;
        }
        if (c == '/' and (can_start_regex or looksLikeRegexLiteral(source, i)) and !(i + 1 < source.len and source[i + 1] == '=')) {
            i += 1;
            var in_class = false;
            while (i < source.len) {
                if (source[i] == '\n') {
                    line += 1;
                    break;
                }
                if (source[i] == '\\') {
                    i += @min(@as(usize, 2), source.len - i);
                    continue;
                }
                if (source[i] == '[') in_class = true;
                if (source[i] == ']') in_class = false;
                if (source[i] == '/' and !in_class) {
                    i += 1;
                    while (i < source.len and std.ascii.isAlphabetic(source[i])) : (i += 1) {}
                    break;
                }
                i += 1;
            }
            can_start_regex = false;
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < source.len and isIdentContinue(source[i])) : (i += 1) {}
            const text = source[start..i];
            try out.append(allocator, .{ .kind = .ident, .text = text, .start = start, .end = i, .line = line });
            can_start_regex = keywordAllowsRegex(text);
            continue;
        }
        if (c == '=' and i + 1 < source.len and source[i + 1] == '>') {
            try out.append(allocator, .{ .kind = .arrow, .text = source[i .. i + 2], .start = i, .end = i + 2, .line = line });
            i += 2;
            can_start_regex = true;
            continue;
        }
        try out.append(allocator, .{ .kind = .punct, .text = source[i .. i + 1], .start = i, .end = i + 1, .line = line });
        can_start_regex = switch (c) {
            ')', ']', '}' => false,
            else => true,
        };
        i += 1;
    }
}

fn parseModule(explorer: *Explorer, source: []const u8, tokens: []const Token, outline: *FileOutline) !void {
    var i: usize = 0;
    var brace_depth: i32 = 0;
    while (i < tokens.len) {
        const token = tokens[i];
        if (eq(token, "{")) {
            brace_depth += 1;
            i += 1;
            continue;
        }
        if (eq(token, "}")) {
            brace_depth = @max(0, brace_depth - 1);
            i += 1;
            continue;
        }
        if (brace_depth != 0) {
            i += 1;
            continue;
        }

        if (eq(tokens[i], "export") and findTokenBounded(tokens, i + 1, "from") != null) {
            const end = statementEnd(tokens, i);
            try appendImportDeclaration(explorer.allocator, source, tokens, i, end, outline);
            i = @max(end, i + 1);
            continue;
        }

        var start = i;
        while (start < tokens.len and isOneOf(tokens[start], &.{ "export", "default", "declare", "abstract", "async" })) : (start += 1) {}
        if (start >= tokens.len) break;

        if (eq(tokens[start], "import")) {
            const end = statementEnd(tokens, start);
            try appendImportDeclaration(explorer.allocator, source, tokens, i, end, outline);
            i = @max(end, i + 1);
            continue;
        }
        if (eq(tokens[start], "function")) {
            i = try parseFunction(explorer, source, tokens, i, start, outline);
            continue;
        }
        if (eq(tokens[start], "class") or eq(tokens[start], "interface")) {
            i = try parseType(explorer, source, tokens, i, start, outline);
            continue;
        }
        if (eq(tokens[start], "enum")) {
            i = try parseNamedBraceDeclaration(explorer.allocator, source, tokens, i, start, .enum_def, outline);
            continue;
        }
        if (eq(tokens[start], "type")) {
            i = try parseTypeAlias(explorer.allocator, source, tokens, i, start, outline);
            continue;
        }
        if (isVarKeyword(tokens[start])) {
            i = try parseVariables(explorer, source, tokens, i, start, outline, false, false);
            continue;
        }
        // CommonJS imports can occur in a top-level assignment.
        const end = statementEnd(tokens, i);
        try appendRequires(explorer.allocator, source, tokens, i, end, outline);
        i = @max(end, i + 1);
    }
}

fn parseFunction(explorer: *Explorer, source: []const u8, tokens: []const Token, decl_start: usize, kw: usize, outline: *FileOutline) !usize {
    var name_idx = kw + 1;
    if (name_idx < tokens.len and eq(tokens[name_idx], "*")) name_idx += 1;
    if (name_idx >= tokens.len or tokens[name_idx].kind != .ident) return @max(statementEnd(tokens, kw), kw + 1);
    const params_open = findTokenBounded(tokens, name_idx + 1, "(");
    const params_close = if (params_open) |po| matching(tokens, po, "(", ")") else null;
    const open = if (params_close) |pc| findCallableBody(tokens, pc + 1) else null;
    const end_idx = if (open) |o| (matching(tokens, o, "{", "}") orelse tokens.len - 1) else statementEnd(tokens, kw) -| 1;
    try appendSymbol(explorer, source, tokens, decl_start, end_idx, name_idx, .function, outline);
    if (open != null and matching(tokens, open.?, "{", "}") == null) return tokens.len;
    return @min(end_idx + 1, tokens.len);
}

fn parseType(explorer: *Explorer, source: []const u8, tokens: []const Token, decl_start: usize, kw: usize, outline: *FileOutline) !usize {
    const name_idx = kw + 1;
    if (name_idx >= tokens.len or tokens[name_idx].kind != .ident) return kw + 1;
    const open = findTokenBounded(tokens, name_idx + 1, "{") orelse {
        try appendSymbol(explorer, source, tokens, decl_start, name_idx, name_idx, if (eq(tokens[kw], "class")) .class_def else .interface_def, outline);
        return name_idx + 1;
    };
    const close = matching(tokens, open, "{", "}") orelse tokens.len - 1;
    const kind: SymbolKind = if (eq(tokens[kw], "class")) .class_def else .interface_def;
    try appendSymbol(explorer, source, tokens, decl_start, close, name_idx, kind, outline);
    try parseMembers(explorer, source, tokens, open + 1, close, outline, kind == .interface_def);
    return @min(close + 1, tokens.len);
}

fn parseMembers(explorer: *Explorer, source: []const u8, tokens: []const Token, first: usize, limit: usize, outline: *FileOutline, is_interface: bool) !void {
    var i = first;
    while (i < limit) {
        while (i < limit and (eq(tokens[i], ";") or eq(tokens[i], ","))) : (i += 1) {}
        if (i >= limit) break;
        const start = i;
        var cursor = i;
        var readonly = false;
        while (cursor < limit and isMemberModifier(tokens[cursor])) : (cursor += 1) {
            if (eq(tokens[cursor], "readonly")) readonly = true;
        }
        if (cursor < limit and eq(tokens[cursor], "*")) cursor += 1;
        if (cursor >= limit or (tokens[cursor].kind != .ident and tokens[cursor].kind != .string)) {
            i += 1;
            continue;
        }
        const name_idx = cursor;
        cursor += 1;
        if (cursor < limit and eq(tokens[cursor], "?")) cursor += 1;

        // Method syntax: name<T>(...), getter/setter name(...), or constructor.
        const paren = findBeforeBoundary(tokens, cursor, limit, "(");
        const equals = findBeforeBoundary(tokens, cursor, limit, "=");
        const colon = findBeforeBoundary(tokens, cursor, limit, ":");
        if (paren != null and (equals == null or paren.? < equals.?) and (colon == null or paren.? < colon.? or is_interface)) {
            const close_paren = matching(tokens, paren.?, "(", ")") orelse paren.?;
            const body_open = findCallableBodyLimited(tokens, close_paren + 1, limit);
            var end_idx: usize = close_paren;
            if (body_open) |bo| {
                end_idx = matching(tokens, bo, "{", "}") orelse limit -| 1;
            } else end_idx = memberEnd(tokens, close_paren + 1, limit) -| 1;
            try appendSymbol(explorer, source, tokens, start, end_idx, name_idx, .method, outline);
            if (body_open != null and matching(tokens, body_open.?, "{", "}") == null) return;
            i = @max(end_idx + 1, i + 1);
            continue;
        }

        const arrow_before_body = findBeforeBoundary(tokens, cursor, limit, "=>");
        const function_before_body = findBeforeBoundary(tokens, cursor, limit, "function");
        if (arrow_before_body != null or function_before_body != null) {
            const callable_at = arrow_before_body orelse function_before_body.?;
            var end_idx = callable_at;
            if (findCallableBodyLimited(tokens, callable_at + 1, limit)) |body_open| {
                end_idx = matching(tokens, body_open, "{", "}") orelse limit -| 1;
                try appendSymbol(explorer, source, tokens, start, end_idx, name_idx, .method, outline);
                if (matching(tokens, body_open, "{", "}") == null) return;
            } else {
                end_idx = memberEnd(tokens, callable_at + 1, limit) -| 1;
                try appendSymbol(explorer, source, tokens, start, end_idx, name_idx, .method, outline);
            }
            i = @max(end_idx + 1, i + 1);
            if (i < limit and eq(tokens[i], ";")) i += 1;
            continue;
        }

        const end = memberEnd(tokens, cursor, limit);
        const kind: SymbolKind = if (readonly) .constant else .variable;
        const end_idx = end -| 1;
        try appendSymbol(explorer, source, tokens, start, end_idx, name_idx, kind, outline);
        i = @max(end, i + 1);
    }
}

fn parseVariables(explorer: *Explorer, source: []const u8, tokens: []const Token, decl_start: usize, kw: usize, outline: *FileOutline, class_member: bool, readonly: bool) !usize {
    _ = class_member;
    const end = statementEnd(tokens, kw);
    var i = kw + 1;
    var segment_start = i;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    while (i <= end) : (i += 1) {
        const boundary = i == end or (i < end and eq(tokens[i], ",") and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0);
        if (boundary) {
            try appendBindingSegment(explorer, source, tokens, if (segment_start == kw + 1) decl_start else segment_start, segment_start, i, outline, readonly or eq(tokens[kw], "const"));
            segment_start = i + 1;
            continue;
        }
        if (eq(tokens[i], "(")) paren_depth += 1 else if (eq(tokens[i], ")")) paren_depth -= 1;
        if (eq(tokens[i], "[")) bracket_depth += 1 else if (eq(tokens[i], "]")) bracket_depth -= 1;
        if (eq(tokens[i], "{")) brace_depth += 1 else if (eq(tokens[i], "}")) brace_depth -= 1;
    }
    try appendRequires(explorer.allocator, source, tokens, kw, end, outline);
    return @max(end, kw + 1);
}

fn appendBindingSegment(explorer: *Explorer, source: []const u8, tokens: []const Token, detail_start: usize, first: usize, end: usize, outline: *FileOutline, is_const: bool) !void {
    if (first >= end) return;
    const equals = findTokenRange(tokens, first, end, "=") orelse end;
    const callable = findTokenRange(tokens, equals, end, "=>") != null or findTokenRange(tokens, equals, end, "function") != null;
    if (eq(tokens[first], "{") or eq(tokens[first], "[")) {
        var i = first + 1;
        while (i < equals) : (i += 1) {
            if (tokens[i].kind != .ident or isDestructureNoise(tokens, i, first, equals)) continue;
            try appendSymbol(explorer, source, tokens, detail_start, end -| 1, i, if (is_const) .constant else .variable, outline);
        }
        return;
    }
    if (tokens[first].kind != .ident) return;
    var end_idx = end -| 1;
    if (callable) {
        if (findTokenRange(tokens, equals, end, "{")) |bo| end_idx = matching(tokens, bo, "{", "}") orelse end_idx;
    }
    try appendSymbol(explorer, source, tokens, detail_start, end_idx, first, if (callable) .function else if (is_const) .constant else .variable, outline);
}

fn parseNamedBraceDeclaration(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, decl_start: usize, kw: usize, kind: SymbolKind, outline: *FileOutline) !usize {
    const name_idx = kw + 1;
    if (name_idx >= tokens.len or tokens[name_idx].kind != .ident) return kw + 1;
    const open = findTokenBounded(tokens, name_idx + 1, "{");
    const end_idx = if (open) |o| (matching(tokens, o, "{", "}") orelse o) else name_idx;
    try appendRawSymbol(allocator, source, tokens, decl_start, end_idx, name_idx, kind, outline, null, &.{});
    return @min(end_idx + 1, tokens.len);
}

fn parseTypeAlias(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, decl_start: usize, kw: usize, outline: *FileOutline) !usize {
    const name_idx = kw + 1;
    if (name_idx >= tokens.len or tokens[name_idx].kind != .ident) return kw + 1;
    const end = statementEnd(tokens, kw);
    try appendRawSymbol(allocator, source, tokens, decl_start, end -| 1, name_idx, .type_alias, outline, null, &.{});
    return @max(end, kw + 1);
}

fn appendSymbol(explorer: *Explorer, source: []const u8, tokens: []const Token, detail_start: usize, end_idx: usize, name_idx: usize, kind: SymbolKind, outline: *FileOutline) !void {
    var return_type: ?[]const u8 = null;
    var param_buf: [16][]const u8 = undefined;
    var param_types: []const []const u8 = &.{};
    const detail_slice = declarationSlice(source, tokens, detail_start, end_idx);
    if (kind == .function or kind == .method) {
        const extracted = Explorer.extractTsFunctionTypes(detail_slice, &param_buf);
        return_type = extracted.ret;
        param_types = param_buf[0..extracted.param_count];
    }
    try appendRawSymbol(explorer.allocator, source, tokens, detail_start, end_idx, name_idx, kind, outline, return_type, param_types);
}

fn appendRawSymbol(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, detail_start: usize, end_idx: usize, name_idx: usize, kind: SymbolKind, outline: *FileOutline, return_type: ?[]const u8, param_types: []const []const u8) !void {
    if (detail_start >= tokens.len or end_idx >= tokens.len or name_idx >= tokens.len) return;
    const name = try allocator.dupe(u8, tokens[name_idx].text);
    errdefer allocator.free(name);
    const detail_end = declarationHeaderEnd(tokens, detail_start, end_idx, kind);
    const detail = try normalizeDetail(allocator, declarationSlice(source, tokens, detail_start, detail_end));
    errdefer allocator.free(detail);
    const rt_copy = if (return_type) |rt| try allocator.dupe(u8, rt) else null;
    errdefer if (rt_copy) |rt| allocator.free(rt);
    const pts = try allocator.alloc([]const u8, param_types.len);
    errdefer allocator.free(pts);
    var copied: usize = 0;
    errdefer for (pts[0..copied]) |pt| allocator.free(pt);
    for (param_types, 0..) |pt, idx| {
        pts[idx] = try allocator.dupe(u8, pt);
        copied += 1;
    }
    try outline.symbols.append(allocator, .{
        .name = name,
        .kind = kind,
        .line_start = tokens[detail_start].line,
        .line_end = tokens[end_idx].line,
        .detail = detail,
        .return_type = rt_copy,
        .param_types = pts,
    });
}

fn appendImportDeclaration(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, start: usize, end: usize, outline: *FileOutline) !void {
    if (start >= end) return;
    const end_idx = end - 1;
    const detail = try normalizeDetail(allocator, declarationSlice(source, tokens, start, end_idx));
    errdefer allocator.free(detail);
    // The symbol NAME is the resolved import path/specifier (e.g.
    // "../mod.ts"), not the whole statement — matches every other language's
    // import-symbol convention (appendImportSymbol) and is what makes
    // consecutive-import collapsing (codedb_outline) produce a compact
    // "imports: a, b, c" line instead of gluing full statements together.
    // `detail` keeps the full statement for non-collapsed / verbose display.
    var chosen: ?usize = null;
    var i = start;
    while (i < end) : (i += 1) {
        if (tokens[i].kind == .string) chosen = i;
    }
    const name = if (chosen) |idx| try allocator.dupe(u8, tokens[idx].text) else try allocator.dupe(u8, detail);
    errdefer allocator.free(name);
    try outline.symbols.append(allocator, .{ .name = name, .kind = .import, .line_start = tokens[start].line, .line_end = tokens[end_idx].line, .detail = detail });
    if (chosen) |idx| try outline.imports.append(allocator, try allocator.dupe(u8, tokens[idx].text));
}

fn appendRequires(allocator: std.mem.Allocator, source: []const u8, tokens: []const Token, start: usize, end: usize, outline: *FileOutline) !void {
    var i = start;
    while (i + 2 < end) : (i += 1) {
        if (!eq(tokens[i], "require") or !eq(tokens[i + 1], "(") or tokens[i + 2].kind != .string) continue;
        try outline.imports.append(allocator, try allocator.dupe(u8, tokens[i + 2].text));
        const detail = try normalizeDetail(allocator, declarationSlice(source, tokens, start, end -| 1));
        errdefer allocator.free(detail);
        // Same rationale as appendImportDeclaration: name is the require()d
        // path, not the whole `const x = require(...)` statement.
        const name = try allocator.dupe(u8, tokens[i + 2].text);
        errdefer allocator.free(name);
        try outline.symbols.append(allocator, .{ .name = name, .kind = .import, .line_start = tokens[start].line, .line_end = tokens[end -| 1].line, .detail = detail });
    }
}

fn normalizeDetail(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending_space = out.items.len > 0;
        } else {
            if (pending_space) try out.append(allocator, ' ');
            try out.append(allocator, c);
            pending_space = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn declarationSlice(source: []const u8, tokens: []const Token, start: usize, end: usize) []const u8 {
    return source[tokens[start].start..tokens[end].end];
}

fn statementEnd(tokens: []const Token, start: usize) usize {
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var brace: i32 = 0;
    const start_line = if (start < tokens.len) tokens[start].line else 0;
    var i = start;
    while (i < tokens.len and i - start < max_declaration_tokens and tokens[i].line <= start_line + max_declaration_lines) : (i += 1) {
        if (i > start and paren == 0 and bracket == 0 and brace == 0 and tokens[i].line > tokens[i - 1].line and isSafeDeclarationStart(tokens, i)) return i;
        if (eq(tokens[i], "(")) paren += 1 else if (eq(tokens[i], ")")) paren -= 1;
        if (eq(tokens[i], "[")) bracket += 1 else if (eq(tokens[i], "]")) bracket -= 1;
        if (eq(tokens[i], "{")) brace += 1 else if (eq(tokens[i], "}")) {
            if (brace == 0 and paren == 0 and bracket == 0) return i;
            brace -= 1;
        }
        if (eq(tokens[i], ";") and paren == 0 and bracket == 0 and brace == 0) return i + 1;
    }
    return i;
}

fn declarationHeaderEnd(tokens: []const Token, start: usize, end_idx: usize, kind: SymbolKind) usize {
    switch (kind) {
        .function, .method, .class_def, .interface_def, .enum_def => {
            var i = start;
            while (i <= end_idx and i < tokens.len) : (i += 1) {
                if (eq(tokens[i], "{") and matching(tokens, i, "{", "}") == end_idx) return i;
            }
        },
        else => {},
    }
    return end_idx;
}

fn findCallableBody(tokens: []const Token, start: usize) ?usize {
    return findCallableBodyLimited(tokens, start, tokens.len);
}

fn findCallableBodyLimited(tokens: []const Token, start: usize, limit: usize) ?usize {
    if (start >= limit) return null;
    const end = @min(limit, start + max_declaration_tokens);
    const start_line = tokens[start].line;
    var i = start;
    while (i < end and tokens[i].line <= start_line + max_declaration_lines) : (i += 1) {
        if (eq(tokens[i], ";") or eq(tokens[i], "=>")) return null;
        if (!eq(tokens[i], "{")) continue;
        const close = matching(tokens, i, "{", "}") orelse return i;
        if (close + 1 < end and eq(tokens[close + 1], "{")) return close + 1;
        return i;
    }
    return null;
}

fn isSafeDeclarationStart(tokens: []const Token, i: usize) bool {
    if (i >= tokens.len) return false;
    if (isOneOf(tokens[i], &.{ "import", "export", "class", "interface", "enum", "type", "function", "const", "let", "var", "declare", "abstract" })) return true;
    return false;
}

fn memberEnd(tokens: []const Token, start: usize, limit: usize) usize {
    const bounded = @min(limit, start + max_declaration_tokens);
    var i = start;
    var paren: i32 = 0;
    var bracket: i32 = 0;
    var brace: i32 = 0;
    while (i < bounded) : (i += 1) {
        if (eq(tokens[i], "(")) paren += 1 else if (eq(tokens[i], ")")) paren -= 1;
        if (eq(tokens[i], "[")) bracket += 1 else if (eq(tokens[i], "]")) bracket -= 1;
        if (eq(tokens[i], "{")) brace += 1 else if (eq(tokens[i], "}")) {
            if (brace == 0 and paren == 0 and bracket == 0) return i;
            brace -= 1;
        }
        if (eq(tokens[i], ";") and paren == 0 and bracket == 0 and brace == 0) return i + 1;
    }
    return i;
}

fn findTokenBounded(tokens: []const Token, start: usize, needle: []const u8) ?usize {
    if (start >= tokens.len) return null;
    const start_line = tokens[start].line;
    const end = @min(tokens.len, start + max_declaration_tokens);
    var i = start;
    while (i < end and tokens[i].line <= start_line + max_declaration_lines) : (i += 1) {
        if (eq(tokens[i], needle)) return i;
        if (eq(tokens[i], ";")) return null;
    }
    return null;
}

fn findBeforeBoundary(tokens: []const Token, start: usize, limit: usize, needle: []const u8) ?usize {
    var i = start;
    while (i < limit and i - start < max_declaration_tokens) : (i += 1) {
        if (eq(tokens[i], needle)) return i;
        if (eq(tokens[i], ";") or eq(tokens[i], "}")) return null;
        if (eq(tokens[i], "{") and !std.mem.eql(u8, needle, "{")) return null;
    }
    return null;
}

fn findTokenRange(tokens: []const Token, start: usize, end: usize, needle: []const u8) ?usize {
    var i = start;
    while (i < @min(end, tokens.len)) : (i += 1) if (eq(tokens[i], needle)) return i;
    return null;
}

fn matching(tokens: []const Token, open: usize, left: []const u8, right: []const u8) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < tokens.len) : (i += 1) {
        if (eq(tokens[i], left)) depth += 1;
        if (eq(tokens[i], right)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn isDestructureNoise(tokens: []const Token, idx: usize, first: usize, end: usize) bool {
    _ = first;
    if (isOneOf(tokens[idx], &.{ "const", "let", "var", "as" })) return true;
    if (idx + 1 < end and eq(tokens[idx + 1], ":")) return true; // property key
    if (idx > 0 and eq(tokens[idx - 1], ".")) return true;
    return false;
}

fn isMemberModifier(token: Token) bool {
    return isOneOf(token, &.{ "public", "private", "protected", "static", "abstract", "declare", "override", "readonly", "async", "get", "set", "accessor" });
}

fn isVarKeyword(token: Token) bool {
    return isOneOf(token, &.{ "const", "let", "var" });
}
fn isOneOf(token: Token, values: []const []const u8) bool {
    for (values) |value| if (eq(token, value)) return true;
    return false;
}
fn eq(token: Token, value: []const u8) bool {
    if (token.kind == .string) return false;
    return std.mem.eql(u8, token.text, value);
}
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}
fn keywordAllowsRegex(text: []const u8) bool {
    return isKeyword(text, &.{ "return", "throw", "case", "delete", "void", "typeof", "instanceof", "in", "of", "yield", "await", "else", "do" });
}
fn looksLikeRegexLiteral(source: []const u8, slash: usize) bool {
    var i = slash + 1;
    var in_class = false;
    while (i < source.len and source[i] != '\n') : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == '[') in_class = true;
        if (source[i] == ']') in_class = false;
        if (source[i] != '/' or in_class) continue;
        i += 1;
        while (i < source.len and std.ascii.isAlphabetic(source[i])) : (i += 1) {}
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i >= source.len or source[i] == '\n') return true;
        return std.mem.indexOfScalar(u8, ".;,)]}?:", source[i]) != null;
    }
    return false;
}
fn isKeyword(text: []const u8, values: []const []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, text, value)) return true;
    return false;
}
