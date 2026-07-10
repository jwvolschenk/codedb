const std = @import("std");
const ident = @import("explore/ident_utils.zig");

pub const Kind = enum {
    class_def,
    interface_def,
    enum_def,
    struct_def,
    function,
    method,
    variable,
    constant,
    type_alias,
};

pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    return_type: ?[]const u8 = null,
    param_types: ParamTypesResult = .{},
};

/// Stack-embedded param type storage to avoid heap allocation in the parser.
/// The embedded array has fixed capacity; excess params are silently dropped.
pub const ParamTypesResult = struct {
    buf: [max_params][]const u8 = undefined,
    len: usize = 0,

    pub const max_params = 32;

    pub fn push(self: *ParamTypesResult, item: []const u8) void {
        if (self.len < max_params) {
            self.buf[self.len] = item;
            self.len += 1;
        }
    }

    pub fn slice(self: *const ParamTypesResult) []const []const u8 {
        return self.buf[0..self.len];
    }
};

pub const ParsedLine = union(enum) {
    none,
    import: []const u8,
    symbol: Symbol,
};

pub fn parseLine(raw_line: []const u8) ParsedLine {
    return parseLineWithOptions(raw_line, .{});
}

pub const ParseOptions = struct {
    /// Bare `Name = value,` lines are only declarations inside an enum body.
    /// Keeping this off by default prevents object-initializer entries from
    /// polluting the global symbol/definition index.
    allow_enum_member: bool = false,
    /// Field declarations are only valid at type-member scope (except in C#
    /// scripts). Lifecycle parsing disables this inside method/local-function
    /// bodies so local `const` values do not become global definitions.
    allow_field_declarations: bool = true,
};

pub fn parseLineWithOptions(raw_line: []const u8, options: ParseOptions) ParsedLine {
    const line_with_comments_removed = stripLineComment(raw_line);
    const line = stripAttributePrefix(line_with_comments_removed) orelse return .none;
    if (line.len == 0 or startsWith(line, "#")) return .none;

    if (parseUsing(line)) |imp| return .{ .import = imp };
    if (extractNamespace(line)) |name| return .{ .symbol = .{ .name = name, .kind = .type_alias } };
    if (extractTypeDeclaration(line)) |decl| return .{ .symbol = decl };
    if (extractDelegateSymbol(line)) |sym| return .{ .symbol = sym };
    if (extractMethodSignature(line)) |sym| return .{ .symbol = sym };
    if (extractEventName(line)) |name| return .{ .symbol = .{ .name = name, .kind = .variable } };
    if (extractPropertySymbol(line)) |sym| return .{ .symbol = sym };
    if (options.allow_field_declarations) {
        if (extractFieldName(line)) |field| return .{ .symbol = field };
    }
    if (options.allow_enum_member) {
        if (extractEnumMemberContextual(line)) |name| return .{ .symbol = .{ .name = name, .kind = .constant } };
    }
    return .none;
}

pub fn lineDeclaresEnum(raw_line: []const u8) bool {
    const line = stripAttributePrefix(stripLineComment(raw_line)) orelse return false;
    const decl = extractTypeDeclaration(line) orelse return false;
    return decl.kind == .enum_def;
}

pub fn lineDeclaresType(raw_line: []const u8) bool {
    const line = stripAttributePrefix(stripLineComment(raw_line)) orelse return false;
    return extractTypeDeclaration(line) != null;
}

pub const BraceCounts = struct {
    opens: usize = 0,
    closes: usize = 0,
};

/// Count structural braces on one C# line, excluding comments and all string
/// forms. This is deliberately allocation-free because it runs on every line.
pub fn countStructuralBraces(raw_line: []const u8) BraceCounts {
    const line = stripLineComment(raw_line);
    var result: BraceCounts = .{};
    var quote: u8 = 0;
    var verbatim = false;
    var raw_quote_count: usize = 0;
    var in_block_comment = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_block_comment) {
            if (ch == '*' and i + 1 < line.len and line[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (raw_quote_count != 0) {
            if (ch == '"') {
                const count = countConsecutiveQuotes(line, i);
                if (count >= raw_quote_count) {
                    i += raw_quote_count - 1;
                    raw_quote_count = 0;
                }
            }
            continue;
        }
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '*') {
            in_block_comment = true;
            i += 1;
            continue;
        }
        if (ch == '"') {
            if (rawStringDelimiterLength(line, i)) |count| {
                raw_quote_count = count;
                i += count - 1;
                continue;
            }
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
            continue;
        }
        if (ch == '{') result.opens += 1;
        if (ch == '}') result.closes += 1;
    }
    return result;
}

/// Return the first block-comment opener that is outside C# strings and a
/// trailing line comment. Used by lifecycle parsing to carry inline `/* ...`
/// state onto following lines.
pub fn findBlockCommentStart(line: []const u8) ?usize {
    var quote: u8 = 0;
    var verbatim = false;
    var raw_quote_count: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (raw_quote_count != 0) {
            if (ch == '"') {
                const count = countConsecutiveQuotes(line, i);
                if (count >= raw_quote_count) {
                    i += raw_quote_count - 1;
                    raw_quote_count = 0;
                }
            }
            continue;
        }
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '/' and i + 1 < line.len) {
            if (line[i + 1] == '/') return null;
            if (line[i + 1] == '*') return i;
        }
        if (ch == '"') {
            if (rawStringDelimiterLength(line, i)) |count| {
                raw_quote_count = count;
                i += count - 1;
                continue;
            }
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
        }
    }
    return null;
}

pub fn isVerbatimStringStart(line: []const u8, quote_index: usize) bool {
    if (quote_index > 0 and line[quote_index - 1] == '@') return true;
    if (quote_index > 1 and line[quote_index - 1] == '@' and line[quote_index - 2] == '$') return true;
    if (quote_index > 1 and line[quote_index - 1] == '$' and line[quote_index - 2] == '@') return true;
    return false;
}

pub fn rawStringDelimiterLength(line: []const u8, quote_index: usize) ?usize {
    if (quote_index >= line.len or line[quote_index] != '"') return null;
    if (quote_index > 0 and line[quote_index - 1] == '"') return null;

    var count: usize = 0;
    while (quote_index + count < line.len and line[quote_index + count] == '"') : (count += 1) {}
    if (count < 3) return null;

    var prefix = quote_index;
    while (prefix > 0 and line[prefix - 1] == '$') : (prefix -= 1) {}
    if (prefix > 0 and (isIdentChar(line[prefix - 1]) or line[prefix - 1] == '@')) return null;

    return count;
}

pub fn updateRawStringState(line: []const u8, raw_quote_count: *usize) void {
    var quote: u8 = 0;
    var verbatim = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (raw_quote_count.* != 0) {
            if (ch == '"') {
                const count = countConsecutiveQuotes(line, i);
                if (count >= raw_quote_count.*) {
                    i += raw_quote_count.* - 1;
                    raw_quote_count.* = 0;
                }
            }
            continue;
        }
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') return;
        if (ch == '"') {
            if (rawStringDelimiterLength(line, i)) |count| {
                raw_quote_count.* = count;
                i += count - 1;
                continue;
            }
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
        }
    }
}

pub fn stripAttributeLine(line: []const u8, in_attribute_block: *bool) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    if (in_attribute_block.*) {
        const close = findAttributeClose(rest) orelse return null;
        in_attribute_block.* = false;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        if (rest.len == 0) return null;
    }
    while (startsWith(rest, "[")) {
        const close = findAttributeClose(rest) orelse {
            in_attribute_block.* = true;
            return null;
        };
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        if (rest.len == 0) return null;
    }
    return rest;
}

fn stripLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t");
    var quote: u8 = 0;
    var verbatim = false;
    var raw_quote_count: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (raw_quote_count != 0) {
            if (ch == '"') {
                const count = countConsecutiveQuotes(trimmed, i);
                if (count >= raw_quote_count) {
                    i += raw_quote_count - 1;
                    raw_quote_count = 0;
                }
            }
            continue;
        }
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < trimmed.len and trimmed[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < trimmed.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '/' and i + 1 < trimmed.len and trimmed[i + 1] == '/') {
            return std.mem.trimEnd(u8, trimmed[0..i], " \t");
        }
        if (ch == '"') {
            if (rawStringDelimiterLength(trimmed, i)) |count| {
                raw_quote_count = count;
                i += count - 1;
                continue;
            }
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(trimmed, i);
        }
    }
    return trimmed;
}

fn countConsecutiveQuotes(line: []const u8, start: usize) usize {
    var count: usize = 0;
    while (start + count < line.len and line[start + count] == '"') : (count += 1) {}
    return count;
}

fn stripAttributePrefix(line: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, line, " \t");
    while (startsWith(rest, "[")) {
        const close = findAttributeClose(rest) orelse return null;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        if (rest.len == 0) return null;
    }
    return rest;
}

fn findAttributeClose(line: []const u8) ?usize {
    var quote: u8 = 0;
    var verbatim = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
            continue;
        }
        if (ch == ']') return i;
    }
    return null;
}

fn parseUsing(line: []const u8) ?[]const u8 {
    if (parseExternAlias(line)) |alias| return alias;
    var body = if (startsWith(line, "global using "))
        std.mem.trim(u8, line["global using ".len..], " \t;")
    else if (startsWith(line, "using "))
        std.mem.trim(u8, line["using ".len..], " \t;")
    else
        return null;
    if (startsWith(body, "(") or startsWith(body, "var ")) return null;
    if (startsWith(body, "static ")) body = std.mem.trimStart(u8, body["static ".len..], " \t");
    if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
        const alias = std.mem.trim(u8, body[0..eq], " \t");
        if (std.mem.indexOfAny(u8, alias, " \t") != null) return null;
        body = std.mem.trim(u8, body[eq + 1 ..], " \t");
    }
    if (std.mem.indexOfScalar(u8, body, ';')) |semi| body = body[0..semi];
    body = std.mem.trim(u8, body, " \t;");
    if (!isImportPath(body)) return null;
    return if (body.len > 0) body else null;
}

fn parseExternAlias(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "extern alias ")) return null;
    var body = std.mem.trim(u8, line["extern alias ".len..], " \t;");
    if (std.mem.indexOfScalar(u8, body, ';')) |semi| body = body[0..semi];
    body = std.mem.trim(u8, body, " \t;");
    return extractIdent(body);
}

fn extractNamespace(line: []const u8) ?[]const u8 {
    if (!startsWith(line, "namespace ")) return null;
    return extractQualifiedIdent(std.mem.trimStart(u8, line["namespace ".len..], " \t"));
}

fn isImportPath(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') continue;
        if (ch == ':' and i + 1 < s.len and s[i + 1] == ':') {
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

fn extractTypeDeclaration(line: []const u8) ?Symbol {
    const patterns = [_]struct { keyword: []const u8, kind: Kind }{
        .{ .keyword = "record struct ", .kind = .struct_def },
        .{ .keyword = "record class ", .kind = .class_def },
        .{ .keyword = "record ", .kind = .class_def },
        .{ .keyword = "class ", .kind = .class_def },
        .{ .keyword = "interface ", .kind = .interface_def },
        .{ .keyword = "enum ", .kind = .enum_def },
        .{ .keyword = "struct ", .kind = .struct_def },
    };
    for (patterns) |pattern| {
        if (extractTypeNameAfterKeyword(line, pattern.keyword)) |name| {
            return .{ .name = name, .kind = pattern.kind };
        }
    }
    return null;
}

fn extractTypeNameAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, keyword)) |pos| {
        if (std.mem.indexOfScalar(u8, line[0..pos], '=') != null or
            isInsideString(line, pos) or
            (pos > 0 and (isIdentChar(line[pos - 1]) or line[pos - 1] == '.')))
        {
            start = pos + 1;
            continue;
        }
        return extractIdent(std.mem.trimStart(u8, line[pos + keyword.len ..], " \t"));
    }
    return null;
}

fn extractDelegateName(line: []const u8) ?[]const u8 {
    const rest = extractAfterKeyword(line, "delegate ") orelse return null;
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    return extractCallableName(rest[0..open]);
}

fn extractDelegateSymbol(line: []const u8) ?Symbol {
    const rest = extractAfterKeyword(line, "delegate ") orelse return null;
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const name = extractCallableName(rest[0..open]) orelse return null;
    // Return type is everything between "delegate " and the name
    const before_open = std.mem.trimEnd(u8, rest[0..open], " \t");
    var stripped = before_open;
    if (std.mem.endsWith(u8, stripped, ">")) stripped = stripTrailingGenericSuffix(stripped);
    const span = extractLastIdentSpan(stripped) orelse return .{ .name = name, .kind = .function };
    // Use raw prefix to preserve generics like Task<Result>
    const ret_end = if (span.start > 0 and before_open[span.start - 1] == ' ')
        span.start - 1
    else
        span.start;
    const ret_type_raw = std.mem.trim(u8, before_open[0..ret_end], " \t");
    const clean_type = stripCSharpModifiers(ret_type_raw);
    return .{
        .name = name,
        .kind = .function,
        .return_type = if (clean_type.len > 0) clean_type else null,
    };
}

fn extractMethodSignature(line: []const u8) ?Symbol {
    if (startsWithAny(line, &.{
        "using ", "namespace ", "return ", "throw ", "new ",     "case ",    "where ",
        "if ",    "if(",        "for ",    "for(",   "foreach ", "foreach(", "while ",
        "while(", "switch ",    "switch(", "catch ", "catch(",   "lock ",    "lock(",
        "fixed ", "fixed(",
    })) return null;
    if (containsAny(line, &.{ " class ", " interface ", " enum ", " struct ", " record ", " delegate " })) return null;
    const open = findSignatureOpen(line) orelse return null;
    // Assignments and initializers can contain arbitrarily declaration-looking
    // nested calls/casts. The only valid callable declaration with `=` before
    // its parameter list is an equality/conversion operator.
    if (std.mem.indexOfScalar(u8, line[0..open], '=') != null and extractOperatorName(line[0..open]) == null) return null;
    const name = extractCallableName(line[0..open]) orelse return null;
    if (isControlKeyword(name)) return null;
    if (!hasDeclarationPrefix(line[0..open], name)) return null;

    // Extract return type from the raw prefix before the method name.
    // We use the raw prefix (not stripTrailingGenericSuffix) to preserve
    // return type generics like Task<IViewComponentResult>.
    const before_open = std.mem.trimEnd(u8, line[0..open], " \t");
    // Find method name position using stripped version for IdentSpan lookup
    var stripped = before_open;
    if (std.mem.endsWith(u8, stripped, ">")) stripped = stripTrailingGenericSuffix(stripped);
    const span = extractLastIdentSpan(stripped) orelse return .{ .name = name, .kind = .method };
    // Use the raw prefix to get the full return type including generics
    const ret_end = if (span.start > 0 and before_open[span.start - 1] == ' ')
        span.start - 1
    else
        span.start;
    const raw_prefix = before_open[0..ret_end];
    // Strip C# modifiers (public, async, static, etc.) to get just the type
    const clean_type = stripCSharpModifiers(raw_prefix);
    var ret_type: ?[]const u8 = null;
    if (clean_type.len > 0 and looksLikeReturnTypePrefix(clean_type)) {
        ret_type = clean_type;
    }

    // Extract parameter types
    const close = findMatchingParen(line, open);
    const param_result = if (close) |c| extractParamTypesFromSlice(line[open + 1 .. c]) else ParamTypesResult{};

    return .{
        .name = name,
        .kind = .method,
        .return_type = ret_type,
        .param_types = param_result,
    };
}

fn findSignatureOpen(line: []const u8) ?usize {
    var limit = line.len;
    if (std.mem.indexOfScalar(u8, line, '{')) |pos| limit = @min(limit, pos);
    if (std.mem.indexOf(u8, line, "=>")) |pos| limit = @min(limit, pos);
    if (std.mem.indexOfScalar(u8, line, ';')) |pos| limit = @min(limit, pos);
    if (std.mem.indexOf(u8, line[0..limit], " where ")) |pos| limit = @min(limit, pos);
    // The first parenthesis is the declaration's parameter list. Choosing the
    // last one mistakes nested calls, casts, attributes, and default values for
    // the callable being declared.
    return std.mem.indexOfScalar(u8, line[0..limit], '(');
}

fn extractEventName(line: []const u8) ?[]const u8 {
    const rest = extractAfterKeyword(line, "event ") orelse return null;
    const end = std.mem.indexOfAny(u8, rest, ";{=") orelse rest.len;
    return extractLastIdent(std.mem.trim(u8, rest[0..end], " \t"));
}

fn extractPropertyName(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, '(') != null) return null;
    const body_end = findPropertyBodyStart(line) orelse return null;
    const before = std.mem.trimEnd(u8, line[0..body_end], " \t");
    if (std.mem.indexOf(u8, before, " this[") != null or std.mem.endsWith(u8, before, " this")) return null;
    const span = extractLastIdentSpan(before) orelse return null;
    const name = span.text;
    if (isNonMemberName(name)) return null;
    const before_name = std.mem.trim(u8, before[0..span.start], " \t");
    if (before_name.len == 0 or std.mem.endsWith(u8, before_name, ".") or
        std.mem.endsWith(u8, before_name, "="))
        return null;
    return name;
}

fn extractPropertySymbol(line: []const u8) ?Symbol {
    if (std.mem.indexOfScalar(u8, line, '(') != null) return null;
    const body_end = findPropertyBodyStart(line) orelse return null;
    // `Items = new List<T> { ... }` is an object/collection initializer, not a
    // property declaration. A real property initializer has its accessor body
    // before the assignment (`public T Items { get; } = ...`).
    if (std.mem.indexOfScalar(u8, line[0..body_end], '=') != null) return null;
    const before = std.mem.trimEnd(u8, line[0..body_end], " \t");
    if (std.mem.indexOf(u8, before, " this[") != null or std.mem.endsWith(u8, before, " this")) return null;
    const span = extractLastIdentSpan(before) orelse return null;
    const name = span.text;
    if (isNonMemberName(name)) return null;
    const before_name = std.mem.trim(u8, before[0..span.start], " \t");
    if (before_name.len == 0 or std.mem.endsWith(u8, before_name, ".") or
        std.mem.endsWith(u8, before_name, "="))
        return null;
    // Extract property type: the prefix before the property name, after stripping modifiers
    const raw_prefix = std.mem.trim(u8, before[0..span.start], " \t");
    const clean_type = stripCSharpModifiers(raw_prefix);
    var ret_type: ?[]const u8 = null;
    if (clean_type.len > 0 and looksLikeReturnTypePrefix(clean_type)) {
        ret_type = clean_type;
    }
    return .{
        .name = name,
        .kind = .variable,
        .return_type = ret_type,
    };
}

fn findPropertyBodyStart(line: []const u8) ?usize {
    var quote: u8 = 0;
    var verbatim = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
            continue;
        }
        if (line[i] == '{') return i;
        if (line[i] == '=' and i + 1 < line.len and line[i + 1] == '>') return i;
    }
    return null;
}

fn extractFieldName(line: []const u8) ?Symbol {
    const semi = std.mem.indexOfScalar(u8, line, ';');
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse semi orelse return null;
    const end = semi orelse blk: {
        if (findRawStringStart(line[eq + 1 ..])) |_| break :blk line.len;
        return null;
    };
    if (std.mem.indexOfScalar(u8, line[0..eq], '(') != null) return null;
    const has_member_modifier = containsAny(line, &.{ "public ", "private ", "protected ", "internal ", "static ", "const ", "readonly ", "volatile " });
    if (!has_member_modifier) return null;
    var before = std.mem.trim(u8, line[0..end], " \t");
    if (std.mem.indexOfScalar(u8, before, '=')) |assign| before = std.mem.trimEnd(u8, before[0..assign], " \t");
    const name = extractLastIdent(before) orelse return null;
    if (isNonMemberName(name)) return null;
    // Extract field type: prefix before the field name
    const span = extractLastIdentSpan(before) orelse return .{ .name = name, .kind = if (containsAny(line, &.{"const "})) .constant else .variable };
    const raw_prefix = std.mem.trim(u8, before[0..span.start], " \t");
    const clean_type = stripCSharpModifiers(raw_prefix);
    var ret_type: ?[]const u8 = null;
    if (clean_type.len > 0 and extractLastTypeIdent(clean_type) != null) {
        ret_type = clean_type;
    }
    return .{
        .name = name,
        .kind = if (containsAny(line, &.{"const "})) .constant else .variable,
        .return_type = ret_type,
    };
}

pub const max_field_names = 16;

/// Extract every field name from a single-line multi-declarator field, e.g.
/// `private int a, b, c;` → {a, b, c}. Conservative: returns 0 when any
/// declarator carries an initializer, generic, call, index, or other nested
/// punctuation, leaving those to the single-field path (`extractFieldName`).
/// Allocation-free; returned names borrow from `line`.
pub fn extractFieldNames(line: []const u8, out: *[max_field_names][]const u8) usize {
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse return 0;
    const region = std.mem.trim(u8, line[0..semi], " \t");
    const first_comma = std.mem.indexOfScalar(u8, region, ',') orelse return 0;
    // Only a plain `Modifiers Type a, b, c` declarator list qualifies.
    if (std.mem.indexOfAny(u8, region, "=(){}[]<>:\"'") != null) return 0;
    const has_member_modifier = containsAny(line, &.{ "public ", "private ", "protected ", "internal ", "static ", "const ", "readonly ", "volatile " });
    if (!has_member_modifier) return 0;

    var count: usize = 0;
    // First declarator: the last identifier of the `modifiers type name` head.
    const head = std.mem.trim(u8, region[0..first_comma], " \t");
    const first_name = extractLastIdent(head) orelse return 0;
    if (isNonMemberName(first_name)) return 0;
    out[count] = first_name;
    count += 1;

    var it = std.mem.splitScalar(u8, region[first_comma + 1 ..], ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) return 0; // empty/trailing declarator — bail
        const name = extractIdent(tok) orelse return 0;
        if (name.len != tok.len) return 0; // not a bare identifier
        if (isNonMemberName(name)) return 0;
        if (count >= max_field_names) break;
        out[count] = name;
        count += 1;
    }
    return if (count > 1) count else 0;
}

fn findRawStringStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (rawStringDelimiterLength(line, i) != null) return i;
    }
    return null;
}

fn extractAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, line, start, keyword)) |pos| {
        if (isInsideString(line, pos) or (pos > 0 and (isIdentChar(line[pos - 1]) or line[pos - 1] == '.'))) {
            start = pos + 1;
            continue;
        }
        return std.mem.trimStart(u8, line[pos + keyword.len ..], " \t");
    }
    return null;
}

fn isInsideString(line: []const u8, pos: usize) bool {
    var quote: u8 = 0;
    var verbatim = false;
    var i: usize = 0;
    while (i < pos and i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < pos and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < pos) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
        }
    }
    return quote != 0;
}

fn extractIdent(s: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, s, " \t");
    if (startsWith(rest, "@")) rest = rest[1..];
    return ident.extractIdent(rest);
}

fn extractQualifiedIdent(s: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, s, " \t");
    if (startsWith(rest, "@")) rest = rest[1..];
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const ch = rest[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) break;
    }
    while (end > 0 and rest[end - 1] == '.') end -= 1;
    return if (end > 0) rest[0..end] else null;
}

fn extractCallableName(before_open_paren: []const u8) ?[]const u8 {
    var before = std.mem.trimEnd(u8, before_open_paren, " \t");
    if (extractOperatorName(before)) |name| return name;
    if (std.mem.endsWith(u8, before, ">")) before = stripTrailingGenericSuffix(before);
    const span = extractLastIdentSpan(before) orelse return null;
    const name = span.text;
    if (std.mem.eql(u8, name, "operator")) return name;
    const before_name = std.mem.trim(u8, before[0..span.start], " \t");
    if (before_name.len == 0 or std.mem.endsWith(u8, before_name, "->") or
        std.mem.endsWith(u8, before_name, "="))
        return null;
    if (std.mem.endsWith(u8, before_name, ".") and std.mem.indexOfAny(u8, before_name, " \t") == null) return null;
    return name;
}

fn extractOperatorName(before_open_paren: []const u8) ?[]const u8 {
    const marker = " operator ";
    const pos = std.mem.indexOf(u8, before_open_paren, marker) orelse return null;
    const after_operator = std.mem.trim(u8, before_open_paren[pos + 1 ..], " \t");
    if (!startsWith(after_operator, "operator ")) return null;
    return after_operator;
}

fn hasDeclarationPrefix(before_open_paren: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "operator")) return true;
    var before = std.mem.trimEnd(u8, before_open_paren, " \t");
    if (std.mem.endsWith(u8, before, ">")) before = stripTrailingGenericSuffix(before);
    const span = extractLastIdentSpan(before) orelse return false;
    const prefix = declarationPrefixBeforeCallable(before_open_paren[0..span.start]) orelse return false;
    if (prefix.len == 0) return false;
    if (std.mem.endsWith(u8, prefix, ".") or std.mem.endsWith(u8, prefix, "->") or std.mem.endsWith(u8, prefix, "=")) return false;
    if (isStatementPrefix(prefix)) return false;
    // Object instantiation: `... new Name(` has `new` as the token immediately
    // preceding the callable name. Distinguish from the C# `new` modifier
    // (`public new void Name`), where a return type sits between `new` and the
    // name — so the modifier's prefix does NOT end with the `new` token.
    // Without this guard, `var p = new Probe();` is misclassified as a method
    // declaration named "Probe" (the `containsAny(prefix, " new")` check below
    // matches the `new` in the instantiation expression).
    if (lastTokenIs(prefix, "new")) return false;
    if (containsAny(prefix, &.{ " public", " private", " protected", " internal", " static", " virtual", " override", " abstract", " async", " extern", " partial", " sealed", " new", " unsafe" })) return true;
    if (startsWithAny(prefix, &.{ "public ", "private ", "protected ", "internal ", "static ", "virtual ", "override ", "abstract ", "async ", "extern ", "partial ", "sealed ", "new ", "unsafe " })) return true;
    return looksLikeReturnTypePrefix(prefix);
}

fn declarationPrefixBeforeCallable(raw_prefix: []const u8) ?[]const u8 {
    var prefix = std.mem.trim(u8, raw_prefix, " \t");
    if (std.mem.endsWith(u8, prefix, ".")) {
        const qualifier = std.mem.trimEnd(u8, prefix[0 .. prefix.len - 1], " \t");
        var split = qualifier.len;
        while (split > 0) {
            const ch = qualifier[split - 1];
            if (ch == ' ' or ch == '\t') break;
            split -= 1;
        }
        if (split == 0) return null;
        prefix = std.mem.trim(u8, qualifier[0..split], " \t");
    }
    return prefix;
}

fn isStatementPrefix(prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, prefix, " \t");
    const keywords = [_][]const u8{ "await", "yield", "return", "throw", "new", "using", "lock", "fixed", "checked", "unchecked", "if", "for", "foreach", "while", "switch", "catch" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, trimmed, kw)) return true;
    }
    return false;
}

/// True if the last whitespace-delimited token of `prefix` equals `keyword`.
/// Used to detect object instantiation (`... new Name(`) where `new` is the
/// token directly before the callable name. `prefix` is assumed trimmed of
/// leading/trailing whitespace by the caller.
fn lastTokenIs(prefix: []const u8, keyword: []const u8) bool {
    var start: usize = 0;
    var i: usize = prefix.len;
    while (i > 0) {
        i -= 1;
        if (prefix[i] == ' ' or prefix[i] == '\t') {
            start = i + 1;
            break;
        }
    }
    return std.mem.eql(u8, prefix[start..], keyword);
}

fn looksLikeReturnTypePrefix(prefix: []const u8) bool {
    const trimmed = std.mem.trim(u8, prefix, " \t");
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '=') != null) return false;
    if (startsWithAny(trimmed, &.{ "var ", "await ", "return ", "throw ", "new " })) return false;
    return extractLastTypeIdent(trimmed) != null;
}

fn stripTrailingGenericSuffix(s: []const u8) []const u8 {
    var depth: i32 = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        switch (s[i]) {
            '>' => depth += 1,
            '<' => {
                depth -= 1;
                if (depth == 0) return std.mem.trimEnd(u8, s[0..i], " \t");
            },
            else => {},
        }
    }
    return s;
}

fn extractLastTypeIdent(s: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, s, " \t?&*");
    while (std.mem.endsWith(u8, trimmed, "[]")) {
        trimmed = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 2], " \t?&*");
    }
    if (std.mem.endsWith(u8, trimmed, ">")) trimmed = stripTrailingGenericSuffix(trimmed);
    if (std.mem.lastIndexOfScalar(u8, trimmed, '.')) |dot| {
        if (dot + 1 >= trimmed.len) return null;
        return extractIdent(trimmed[dot + 1 ..]);
    }
    if (std.mem.lastIndexOf(u8, trimmed, "::")) |scope| {
        if (scope + 2 >= trimmed.len) return null;
        return extractIdent(trimmed[scope + 2 ..]);
    }
    return extractLastIdent(trimmed);
}

const IdentSpan = ident.IdentSpan;

const extractLastIdentSpan = ident.extractLastIdentSpan;

const extractLastIdent = ident.extractLastIdent;

const isIdentChar = ident.isIdentChar;

const isControlKeyword = ident.isControlKeyword;

fn isNonMemberName(name: []const u8) bool {
    const keywords = [_][]const u8{ "get", "set", "init", "add", "remove", "value", "if", "for", "while", "switch", "catch", "return", "throw", "new" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

const startsWith = ident.startsWith;

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (startsWith(s, prefix)) return true;
    }
    return false;
}

const containsAny = ident.containsAny;

/// Extract parameter types from the content between '(' and ')'.
/// E.g. "int id, string name, ILogger logger" -> ["int", "string", "ILogger"]
/// Uses a stack-embedded array to avoid heap allocation.
fn extractParamTypesFromSlice(params_slice: []const u8) ParamTypesResult {
    const trimmed = std.mem.trim(u8, params_slice, " \t");
    if (trimmed.len == 0) return .{};

    var result: ParamTypesResult = .{};

    // Split on commas while respecting generic types, tuples, attributes,
    // array/index expressions, strings, and default-value expressions.
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var quote: u8 = 0;
    var verbatim = false;
    var param_start: usize = 0;
    for (trimmed, 0..) |ch, i| {
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < trimmed.len and trimmed[i + 1] == '"') continue;
            if (ch == quote and (i == 0 or trimmed[i - 1] != '\\')) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(trimmed, i);
            continue;
        }
        switch (ch) {
            '<' => angle_depth += 1,
            '>' => if (angle_depth > 0) {
                angle_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            ',' => {
                if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
                    if (extractParamType(trimmed[param_start..i])) |pt| {
                        result.push(pt);
                    }
                    param_start = i + 1;
                }
            },
            else => {},
        }
    }
    // Last parameter
    if (extractParamType(trimmed[param_start..])) |pt| {
        result.push(pt);
    }

    return result;
}

/// Extract the type portion from a single parameter string.
/// E.g. "int id" -> "int", "ILogger logger" -> "ILogger",
/// "List<string> items" -> "List<string>", "string? name" -> "string?"
fn extractParamType(param: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, param, " \t");
    if (trimmed.len == 0) return null;

    // Handle `this` prefix (extension methods): "this int id" -> "int"
    var rest = trimmed;
    while (startsWith(rest, "[")) {
        const close = findAttributeClose(rest) orelse return null;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
    }
    // Handle extension/ref-safety modifiers, including combinations such as
    // `this scoped in T value` and `ref readonly T value`.
    const param_modifiers = [_][]const u8{ "this", "scoped", "out", "ref", "readonly", "in", "params" };
    var changed = true;
    while (changed) {
        changed = false;
        for (param_modifiers) |modifier| {
            if (consumeLeadingWord(rest, modifier)) |after| {
                rest = after;
                changed = true;
                break;
            }
        }
    }

    if (rest.len == 0) return null;

    // Defaults belong to the parameter, not its type (`string name = "x"`).
    if (findTopLevelAssignment(rest)) |eq| {
        rest = std.mem.trimEnd(u8, rest[0..eq], " \t");
    }

    // Find where the type ends and the parameter name begins.
    // Strategy: the last identifier is the parameter name, everything before is the type.
    // But we need to handle generics: "Dictionary<string, List<int>> dict"
    // The last identifier is "dict", the type is "Dictionary<string, List<int>>".

    // Find the end of the last identifier (from the end)
    var name_end = rest.len;
    while (name_end > 0 and isIdentChar(rest[name_end - 1])) {
        name_end -= 1;
    }
    if (name_end == rest.len) return null; // no identifier at end
    if (name_end == 0) return null; // only an identifier, no type

    // The type is everything before the name, trimmed
    const type_part = std.mem.trim(u8, rest[0..name_end], " \t");
    if (type_part.len == 0) return null;
    return type_part;
}

/// Strip C# access and modifier keywords from a type prefix string.
/// E.g. "public async Task<T>" -> "Task<T>"
///      "private static void" -> "void"
///      "protected override string" -> "string"
fn stripCSharpModifiers(s: []const u8) []const u8 {
    var result = std.mem.trim(u8, s, " \t");
    const modifiers = [_][]const u8{
        "public",   "private", "protected", "internal",
        "static",   "virtual", "override",  "abstract",
        "async",    "extern",  "partial",   "sealed",
        "new",      "unsafe",  "volatile",  "readonly",
        "required", "file",
    };
    // Strip modifiers iteratively (e.g. "public async static")
    var changed = true;
    while (changed and result.len > 0) {
        changed = false;
        for (modifiers) |modifier| {
            if (consumeLeadingWord(result, modifier)) |after| {
                result = after;
                changed = true;
                break;
            }
        }
    }
    return result;
}

/// Detect C# enum member lines like:
///   Draft,
///   Active = 1,
///   Submitted = 2
/// These are bare identifiers with optional `= value` and optional trailing comma.
/// Returns the member name if this line looks like an enum member.
/// Conservative: only matches PascalCase identifiers to avoid false positives
/// in method bodies where bare identifiers might appear.
pub fn extractEnumMember(line: []const u8) ?[]const u8 {
    const member = extractEnumMemberContextual(line) orelse return null;
    return if (member.len > 0 and std.ascii.isUpper(member[0])) member else null;
}

fn extractEnumMemberContextual(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;

    // Must start with a letter or underscore (identifier start)
    // Also handle @ prefix (C# verbatim identifier: @New, @class, etc.)
    var ident_start: usize = 0;
    if (trimmed.len > 1 and trimmed[0] == '@') ident_start = 1;
    if (!std.ascii.isAlphabetic(trimmed[ident_start]) and trimmed[ident_start] != '_') return null;

    // Reject lines with access modifiers, type keywords, or other declaration prefixes
    if (startsWithAny(trimmed, &.{ "public ", "private ", "protected ", "internal ", "static ", "const ", "readonly ", "volatile ", "class ", "interface ", "struct ", "enum ", "record ", "delegate ", "event ", "namespace ", "using ", "return ", "throw ", "new ", "case ", "where ", "abstract ", "sealed ", "override ", "virtual ", "extern ", "unsafe ", "async ", "partial " })) return null;

    // Reject lines with parens (method calls/declarations), braces, semicolons
    if (std.mem.indexOfScalar(u8, trimmed, '(') != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '{') != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, ';') != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '}') != null) return null;

    // Extract the identifier (skip optional @ prefix)
    var end: usize = ident_start;
    while (end < trimmed.len and isIdentChar(trimmed[end])) : (end += 1) {}
    if (end == ident_start) return null;
    const name = trimmed[ident_start..end];

    // Reject if followed by something that indicates it's not an enum member
    const after = std.mem.trimStart(u8, trimmed[end..], " \t");
    if (after.len == 0) {
        // Bare identifier (last enum member, no trailing comma)
        // Reject common non-enum-keywords
        if (isNonMemberName(name) or isControlKeyword(name)) return null;
        return name;
    }
    // Must be followed by `= value` or `,` or `= value,`
    if (after[0] == '=') {
        // Has an assigned value — this is an enum member with value
        return name;
    }
    if (after[0] == ',') {
        // Trailing comma — enum member
        return name;
    }
    // Something else follows — not an enum member
    return null;
}

fn findMatchingParen(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '(') return null;
    var depth: usize = 0;
    var quote: u8 = 0;
    var verbatim = false;
    var i = open;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote != 0) {
            if (quote == '"' and verbatim and ch == '"' and i + 1 < line.len and line[i + 1] == '"') {
                i += 1;
                continue;
            }
            if (!verbatim and ch == '\\' and i + 1 < line.len) {
                i += 1;
                continue;
            }
            if (ch == quote) {
                quote = 0;
                verbatim = false;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            verbatim = ch == '"' and isVerbatimStringStart(line, i);
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Locate the closing parenthesis for the first callable signature in `text`.
/// `text` may span lines; callers use this to enrich line-oriented outlines.
pub fn findSignatureClose(text: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    return findMatchingParen(text, open);
}

fn consumeLeadingWord(s: []const u8, word: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    if (!std.mem.startsWith(u8, trimmed, word)) return null;
    if (trimmed.len == word.len) return trimmed[word.len..];
    if (trimmed[word.len] != ' ' and trimmed[word.len] != '\t') return null;
    return std.mem.trimStart(u8, trimmed[word.len..], " \t");
}

fn findTopLevelAssignment(s: []const u8) ?usize {
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (ch == '\\' and i + 1 < s.len) {
                i += 1;
            } else if (ch == quote) {
                quote = 0;
            }
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        switch (ch) {
            '<' => angle_depth += 1,
            '>' => if (angle_depth > 0) {
                angle_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => if (brace_depth > 0) {
                brace_depth -= 1;
            },
            '=' => if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return i,
            else => {},
        }
    }
    return null;
}
