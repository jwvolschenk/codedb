const std = @import("std");
const parse_utils = @import("parse_utils.zig");
const startsWith = parse_utils.startsWith;

/// Extract return type and param types from a Zig function signature.
/// E.g. "pub fn getUser(id: i32) !User" → ret="!User", params=["i32"]
///      "fn init(allocator: Allocator) Self" → ret="Self", params=["Allocator"]
pub const ZigTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractZigFuncTypes(line: []const u8, param_out: *[16][]const u8) ZigTypes {
    // Find the parameter list: first '(' to matching ')'
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const close_pos = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    // Zig params are "name: Type" format, same as TS
    const params_raw = line[open + 1 .. close_pos];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractTsParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractTsParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: after ')', could be "!Type", "?Type", "Type", or nothing
    var ret_type: ?[]const u8 = null;
    if (close_pos + 1 < line.len) {
        const after = std.mem.trimStart(u8, line[close_pos + 1 ..], " \t");
        if (after.len > 0) {
            // Find end of return type (before '{', ';', or end of line)
            var end: usize = after.len;
            for (after, 0..) |ch, i| {
                if (ch == '{' or ch == ';') {
                    end = i;
                    break;
                }
            }
            const rt = std.mem.trim(u8, after[0..end], " \t");
            if (rt.len > 0) ret_type = rt;
        }
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract return type and param types from a Python function signature.
/// E.g. "def get_user(id: int) -> User:" → ret="User", params=["int"]
///      "def process(data: List[str]) -> None:" → ret="None", params=["List[str]"]
pub const PyTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractPythonFuncTypes(line: []const u8, param_out: *[16][]const u8) PyTypes {
    // Find the parameter list: first '(' to matching ')'
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const close_pos = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    // Python params are "name: Type" format, same as TS
    const params_raw = line[open + 1 .. close_pos];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractTsParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractTsParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: look for "->" after close paren
    var ret_type: ?[]const u8 = null;
    if (close_pos + 2 < line.len and line[close_pos + 1] == '-' and line[close_pos + 2] == '>') {
        const after_arrow = std.mem.trimStart(u8, line[close_pos + 3 ..], " \t");
        // Find end of return type (before ':', '{', ';', or end of line)
        var end: usize = after_arrow.len;
        for (after_arrow, 0..) |ch, i| {
            if (ch == ':' or ch == '{' or ch == ';') {
                end = i;
                break;
            }
        }
        const rt = std.mem.trim(u8, after_arrow[0..end], " \t");
        if (rt.len > 0) ret_type = rt;
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract return type and param types from a TypeScript function signature.
/// E.g. "function getUser(id: number): Promise<User>" → ret="Promise<User>", params=["number"]
///      "export async function fn(x: string, y: number): void" → ret="void", params=["string","number"]
pub const TsTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractTsFunctionTypes(line: []const u8, param_out: *[16][]const u8) TsTypes {
    // Find the parameter list: first '(' to matching ')'
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    // Find matching close paren (respecting nested parens)
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const close_pos = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    const params_raw = line[open + 1 .. close_pos];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        // Split on commas, respecting nested angle brackets
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractTsParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractTsParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: look for "):" after close paren
    var ret_type: ?[]const u8 = null;
    if (close_pos + 1 < line.len and line[close_pos + 1] == ':') {
        // Return type annotation: "): ReturnType"
        const after_colon = std.mem.trimStart(u8, line[close_pos + 2 ..], " \t");
        // Find end of return type (before '{', '=>', ';', or end of line)
        var end = after_colon.len;
        for (after_colon, 0..) |ch, i| {
            if (ch == '{' or ch == ';' or ch == '=') {
                end = i;
                break;
            }
        }
        const rt = std.mem.trim(u8, after_colon[0..end], " \t");
        if (rt.len > 0) ret_type = rt;
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract type from a single TS parameter: "id: number" → "number"
/// Handles: "x: string", "x?: string", "x: string = 'default'", "...args: string[]"
pub fn extractTsParamType(param: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, param, " \t");
    if (rest.len == 0) return null;
    // Skip "..." (rest params)
    if (startsWith(rest, "...")) rest = rest[3..];
    rest = std.mem.trimStart(u8, rest, " \t");
    // Find ':' separator
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    // Skip past '?' if present (optional params)
    var type_start = colon + 1;
    if (type_start < rest.len and rest[type_start] == '?') type_start += 1;
    const type_part = std.mem.trim(u8, rest[type_start..], " \t");
    // Find end of type (before '=' default value)
    if (std.mem.indexOfScalar(u8, type_part, '=')) |eq| {
        const trimmed = std.mem.trim(u8, type_part[0..eq], " \t");
        return if (trimmed.len > 0) trimmed else null;
    }
    return if (type_part.len > 0) type_part else null;
}

pub fn stripJavaModifiers(s: []const u8) []const u8 {
    var result = std.mem.trim(u8, s, " \t");
    const modifiers = [_][]const u8{
        "public ", "private ", "protected ",
        "static ", "abstract ", "final ", "synchronized ",
        "native ", "strictfp ", "transient ", "volatile ",
        "default ", "sealed ", "non-sealed ",
    };
    var changed = true;
    while (changed and result.len > 0) {
        changed = false;
        for (modifiers) |mod| {
            if (startsWith(result, mod)) {
                result = std.mem.trimStart(u8, result[mod.len..], " \t");
                changed = true;
                break;
            }
        }
    }
    return result;
}

/// Extract type from a single Java parameter: "int id" → "int", "String name" → "String"
pub fn extractJvmParamType(param: []const u8) ?[]const u8 {
    const rest = std.mem.trim(u8, param, " \t");
    if (rest.len == 0) return null;
    // Java params are "Type name" — the type is everything before the last identifier
    if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |last_space| {
        const type_part = std.mem.trim(u8, rest[0..last_space], " \t");
        if (type_part.len > 0) return type_part;
    }
    // No space — might be a type-only param in annotations, return as-is
    return if (rest.len > 0) rest else null;
}

/// Extract return type and param types from a Java method signature.
/// E.g. "public void getUser(int id, String name)" → ret="void", params=["int","String"]
///      "private static List<String> find(String q)" → ret="List<String>", params=["String"]
pub const JvmTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractJvmFuncTypes(line: []const u8, param_out: *[16][]const u8) JvmTypes {
    // Find the parameter list: last '(' to matching ')'
    const open = std.mem.lastIndexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    if (std.mem.indexOfScalar(u8, line[open..], ')') == null) return .{ .ret = null, .param_count = 0 };
    // Find the actual closing paren
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const actual_close = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    const params_raw = line[open + 1 .. actual_close];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractJvmParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractJvmParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type from prefix: strip modifiers, then take everything before method name
    var ret_type: ?[]const u8 = null;
    const before_params = std.mem.trimEnd(u8, line[0..open], " \t");
    const stripped = stripJavaModifiers(before_params);
    if (stripped.len > 0) {
        // Find the last space before the method name to get the return type
        if (std.mem.lastIndexOfScalar(u8, stripped, ' ')) |last_space| {
            const rt = std.mem.trim(u8, stripped[0..last_space], " \t");
            if (rt.len > 0) ret_type = rt;
        }
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract return type and param types from a Kotlin function signature.
/// E.g. "fun getUser(id: Int): User" → ret="User", params=["Int"]
///      "fun process(data: List<String>): Unit" → ret="Unit", params=["List<String>"]
pub const KtTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractKotlinFuncTypes(line: []const u8, param_out: *[16][]const u8) KtTypes {
    // Find the parameter list: first '(' to matching ')'
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const close_pos = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    // Kotlin params are "name: Type" format, same as TS
    const params_raw = line[open + 1 .. close_pos];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractTsParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractTsParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: look for "): Type" after close paren
    var ret_type: ?[]const u8 = null;
    if (close_pos + 1 < line.len and line[close_pos + 1] == ':') {
        const after_colon = std.mem.trimStart(u8, line[close_pos + 2 ..], " \t");
        // Find end of return type (before '{', ';', or end of line)
        var end: usize = after_colon.len;
        for (after_colon, 0..) |ch, i| {
            if (ch == '{' or ch == ';' or ch == '=') {
                end = i;
                break;
            }
        }
        const rt = std.mem.trim(u8, after_colon[0..end], " \t");
        if (rt.len > 0) ret_type = rt;
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract return type and param types from a Rust function signature.
/// E.g. "fn get_user(id: i32) -> Result<User, Error>" → ret="Result<User, Error>", params=["i32"]
///      "fn process(data: &str) -> String" → ret="String", params=["&str"]
pub const RustTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractRustFuncTypes(line: []const u8, param_out: *[16][]const u8) RustTypes {
    // Find the parameter list: first '(' to matching ')'
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return .{ .ret = null, .param_count = 0 };
    var depth: i32 = 1;
    var close: ?usize = null;
    for (line[open + 1 ..], open + 1..) |ch, i| {
        if (ch == '(') depth += 1
        else if (ch == ')') {
            depth -= 1;
            if (depth == 0) {
                close = i;
                break;
            }
        }
    }
    const close_pos = close orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    // Rust params are "name: Type" format, same as TS
    const params_raw = line[open + 1 .. close_pos];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        var bracket_depth: i32 = 0;
        var param_start: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractTsParamType(params_raw[param_start..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start = i + 1;
            }
        }
        if (extractTsParamType(params_raw[param_start..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: look for "->" after close paren
    var ret_type: ?[]const u8 = null;
    if (close_pos + 2 < line.len and line[close_pos + 1] == '-' and line[close_pos + 2] == '>') {
        const after_arrow = std.mem.trimStart(u8, line[close_pos + 3 ..], " \t");
        // Find end of return type (before '{', ';', or end of line)
        var end: usize = after_arrow.len;
        for (after_arrow, 0..) |ch, i| {
            if (ch == '{' or ch == ';') {
                end = i;
                break;
            }
        }
        const rt = std.mem.trim(u8, after_arrow[0..end], " \t");
        if (rt.len > 0) ret_type = rt;
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract return type and param types from a Go function signature.
/// E.g. "func GetUser(id int) (*User, error)" → ret="*User, error", params=["int"]
///      "func (r *Type) Name(id int, name string) error" → ret="error", params=["int","string"]
pub const GoTypes = struct { ret: ?[]const u8, param_count: usize };
pub fn extractGoFuncTypes(line: []const u8, param_out: *[16][]const u8) GoTypes {
    // Find the parameter list for the function (not the receiver)
    // For "func (r *Type) Name(id int) string", we need the second '('
    // For "func GetUser(id int) string", we need the first '('
    var paren_start: ?usize = null;
    var paren_end: ?usize = null;
    var depth: i32 = 0;

    // If line starts with "func (", skip the receiver parens
    var search_from: usize = 5; // skip "func "
    if (line.len > 5 and line[5] == '(') {
        // Skip receiver: find matching ')'
        depth = 1;
        for (line[6..], 6..) |ch, i| {
            if (ch == '(') depth += 1
            else if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    search_from = i + 1;
                    break;
                }
            }
        }
    }

    // Find the function's parameter '('
    if (std.mem.indexOfScalar(u8, line[search_from..], '(')) |rel_open| {
        const abs_open = search_from + rel_open;
        paren_start = abs_open;
        // Find matching ')'
        depth = 1;
        for (line[abs_open + 1 ..], abs_open + 1..) |ch, i| {
            if (ch == '(') depth += 1
            else if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    paren_end = i;
                    break;
                }
            }
        }
    }

    const p_start = paren_start orelse return .{ .ret = null, .param_count = 0 };
    const p_end = paren_end orelse return .{ .ret = null, .param_count = 0 };

    // Extract param types from between ( and )
    // Go params: "id int, name string" or "id, name int" (shared type)
    const params_raw = line[p_start + 1 .. p_end];
    var param_count: usize = 0;
    if (params_raw.len > 0) {
        // Split on commas
        var bracket_depth: i32 = 0;
        var param_start_idx: usize = 0;
        for (params_raw, 0..) |ch, i| {
            if (ch == '<') bracket_depth += 1
            else if (ch == '>') bracket_depth -= 1
            else if (ch == ',' and bracket_depth == 0) {
                if (extractGoParamType(params_raw[param_start_idx..i])) |pt| {
                    if (param_count < 16) {
                        param_out.*[param_count] = pt;
                        param_count += 1;
                    }
                }
                param_start_idx = i + 1;
            }
        }
        if (extractGoParamType(params_raw[param_start_idx..])) |pt| {
            if (param_count < 16) {
                param_out.*[param_count] = pt;
                param_count += 1;
            }
        }
    }

    // Extract return type: everything after the closing ')' of params
    // In Go, return type can be: "error", "(error)", "(*User, error)", "(int, error)"
    var ret_type: ?[]const u8 = null;
    if (p_end + 1 < line.len) {
        const after_raw = std.mem.trimStart(u8, line[p_end + 1 ..], " \t");
        if (after_raw.len > 0) {
            var end: usize = after_raw.len;
            // Find '{' that starts the function body, respecting parens in return type
            var rdepth: i32 = 0;
            for (after_raw, 0..) |ch, i| {
                if (ch == '(') rdepth += 1
                else if (ch == ')') {
                    rdepth -= 1;
                    if (rdepth < 0) {
                        // Unmatched ')' — this is the start of function body region
                        // Look for '{' from here
                        for (after_raw[i..], i..) |ch2, j| {
                            if (ch2 == '{') {
                                end = j;
                                break;
                            }
                        }
                        break;
                    }
                } else if (rdepth == 0 and ch == '{') {
                    end = i;
                    break;
                }
            }
            const trimmed = std.mem.trim(u8, after_raw[0..end], " \t");
            if (trimmed.len > 0) ret_type = trimmed;
        }
    }

    return .{
        .ret = ret_type,
        .param_count = param_count,
    };
}

/// Extract type from a single Go parameter: "id int" → "int"
/// Handles: "id int", "name string", "...args []string", "ch chan int"
pub fn extractGoParamType(param: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, param, " \t");
    if (rest.len == 0) return null;
    // Skip "..." (variadic)
    if (startsWith(rest, "...")) rest = rest[3..];
    rest = std.mem.trimStart(u8, rest, " \t");
    // In Go, params are "name type" — the last word(s) are the type
    // Find the first space to separate name from type
    if (std.mem.indexOfScalar(u8, rest, ' ')) |space| {
        const type_part = std.mem.trim(u8, rest[space + 1 ..], " \t");
        if (type_part.len > 0) return type_part;
    }
    // No space means it's a shared type like "func(a, b int)" — return as-is
    return if (rest.len > 0) rest else null;
}
