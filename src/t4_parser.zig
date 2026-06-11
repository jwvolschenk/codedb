const std = @import("std");

/// T4-specific symbol kinds for .tt and .t4 template files.
pub const Kind = enum {
    directive_template, // <#@ template ... #>
    directive_assembly, // <#@ assembly ... #>
    directive_import, // <#@ import ... #>
    directive_output, // <#@ output ... #>
    directive_include, // <#@ include ... #>
    directive_parameter, // <#@ parameter ... #>
    code_block, // <# ... #> standard code block
    expression_block, // <#= ... #> expression block
    class_feature_block, // <#+ ... #> class feature block (methods, properties)
    helper_class, // <#+ class Name ... #> inside class feature block
    helper_method, // <#+ ReturnType MethodName(...) #> inside class feature block
    helper_property, // <#+ Type PropertyName #> inside class feature block
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    directive_import: struct {
        namespace: []const u8,
    },
};

/// Extract the value of a T4 directive attribute from a line.
/// T4 directives use the syntax: <#@ directive attribute="value" ... #>
/// Returns the substring between attr_name=" and the next quote.
fn extractDirectiveAttribute(line: []const u8, attr_name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (attr_name.len + 2 > buf.len) return null;
    @memcpy(buf[0..attr_name.len], attr_name);
    buf[attr_name.len] = '=';
    buf[attr_name.len + 1] = '"';
    const needle = buf[0 .. attr_name.len + 2];

    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    const value_start = start + needle.len;
    const remaining = line[value_start..];
    const value_end = std.mem.indexOf(u8, remaining, "\"") orelse return null;
    return remaining[0..value_end];
}

/// Parse a T4 template line. Handles directives (<#@ ... #>) and class
/// feature blocks (<#+ ... #>). Returns the parsed result.
pub fn parseT4Line(raw_line: []const u8) ParsedLine {
    // Strip UTF-8 BOM if present (common in T4 templates)
    const line = if (raw_line.len >= 3 and raw_line[0] == 0xEF and raw_line[1] == 0xBB and raw_line[2] == 0xBF)
        raw_line[3..]
    else
        raw_line;

    // Must start with <# to be a T4 directive or code block
    if (!std.mem.startsWith(u8, line, "<#")) return .none;

    // ── Directives: <#@ directive ... #> ──────────────────────────────

    // <#@ template debug="false" hostspecific="true" language="C#" #>
    if (std.mem.indexOf(u8, line, "<#@ template ") != null or
        std.mem.indexOf(u8, line, "<#@template ") != null)
    {
        const lang = extractDirectiveAttribute(line, "language");
        const name = if (lang) |l| l else "template";
        return .{ .symbol = .{ .name = name, .kind = .directive_template } };
    }

    // <#@ assembly name="System.Core" #>
    if (std.mem.indexOf(u8, line, "<#@ assembly ") != null or
        std.mem.indexOf(u8, line, "<#@assembly ") != null)
    {
        const name = extractDirectiveAttribute(line, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .directive_assembly } };
    }

    // <#@ import namespace="System.Linq" #>
    if (std.mem.indexOf(u8, line, "<#@ import ") != null or
        std.mem.indexOf(u8, line, "<#@import ") != null)
    {
        const ns = extractDirectiveAttribute(line, "namespace") orelse return .none;
        return .{ .directive_import = .{ .namespace = ns } };
    }

    // <#@ output extension=".txt" #>
    if (std.mem.indexOf(u8, line, "<#@ output ") != null or
        std.mem.indexOf(u8, line, "<#@output ") != null)
    {
        const ext = extractDirectiveAttribute(line, "extension") orelse return .none;
        return .{ .symbol = .{ .name = ext, .kind = .directive_output } };
    }

    // <#@ include file="Common.tt" #>
    if (std.mem.indexOf(u8, line, "<#@ include ") != null or
        std.mem.indexOf(u8, line, "<#@include ") != null)
    {
        const file = extractDirectiveAttribute(line, "file") orelse return .none;
        return .{ .symbol = .{ .name = file, .kind = .directive_include } };
    }

    // <#@ parameter name="ParamName" type="string" #>
    if (std.mem.indexOf(u8, line, "<#@ parameter ") != null or
        std.mem.indexOf(u8, line, "<#@parameter ") != null)
    {
        const name = extractDirectiveAttribute(line, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .directive_parameter } };
    }

    // ── Class feature block: <#+ ... #> ───────────────────────────────
    // These contain C# declarations (classes, methods, properties)
    // that are compiled into the generated template class.
    if (std.mem.startsWith(u8, line, "<#+")) {
        const inner = extractT4BlockInner(line);

        // <#+ class ClassName ... #> — helper class
        if (extractIdentAfterKeyword(inner, "class ")) |name| {
            return .{ .symbol = .{ .name = name, .kind = .helper_class } };
        }

        // <#+ public static string MethodName(...) #> — helper method
        // Look for a method pattern: has parentheses and doesn't start with
        // known non-method keywords
        if (extractHelperMethod(inner)) |name| {
            return .{ .symbol = .{ .name = name, .kind = .helper_method } };
        }

        // <#+ public string PropertyName { get; set; } #> — helper property
        if (extractHelperProperty(inner)) |name| {
            return .{ .symbol = .{ .name = name, .kind = .helper_property } };
        }

        // Generic class feature block marker
        return .{ .symbol = .{ .name = "class_feature", .kind = .class_feature_block } };
    }

    return .none;
}

/// Extract the content between <#+ and #> (or <# and #>).
fn extractT4BlockInner(line: []const u8) []const u8 {
    // Find the opening <#
    const start: usize = if (std.mem.indexOf(u8, line, "<#")) |s| s else return "";
    const after_open = if (start + 2 < line.len and line[start + 2] == '+')
        line[start + 3 ..]
    else if (start + 2 < line.len)
        line[start + 2 ..]
    else
        return "";

    // Find the closing #>
    if (std.mem.indexOf(u8, after_open, "#>")) |end| {
        return std.mem.trim(u8, after_open[0..end], " \t");
    }
    return std.mem.trim(u8, after_open, " \t");
}

/// Extract an identifier after a keyword (e.g., "class " -> ClassName).
fn extractIdentAfterKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, keyword)) return null;
    const rest = line[keyword.len..];
    if (rest.len == 0) return null;
    // Skip access modifiers and other keywords before the name
    return extractFirstIdentifier(rest);
}

/// Extract the first C# identifier from a line, skipping access/type modifiers.
fn extractFirstIdentifier(line: []const u8) ?[]const u8 {
    const modifiers = [_][]const u8{
        "public ",    "private ",  "protected ", "internal ",
        "static ",    "abstract ", "virtual ",   "override ",
        "sealed ",    "readonly ", "const ",     "partial ",
        "new ",       "extern ",   "unsafe ",    "volatile ",
        "async ",     "async",
    };

    var remaining = std.mem.trim(u8, line, " \t");
    // Strip modifiers iteratively
    var changed = true;
    while (changed) {
        changed = false;
        for (modifiers) |mod| {
            if (std.mem.startsWith(u8, remaining, mod)) {
                remaining = std.mem.trim(u8, remaining[mod.len..], " \t");
                changed = true;
            }
        }
    }

    // Now extract the identifier (may be a type like List<string>)
    return extractCSharpIdentifier(remaining);
}

/// Extract a C# identifier, handling generics like List<string>.
/// Returns the identifier up to the first non-identifier char (space, (, {, etc.)
fn extractCSharpIdentifier(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;
    // Must start with letter or underscore
    if (!std.ascii.isAlphabetic(line[0]) and line[0] != '_') return null;

    var depth: usize = 0;
    var end: usize = 0;
    for (line, 0..) |ch, i| {
        if (ch == '<') {
            depth += 1;
        } else if (ch == '>') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0) {
            if (ch == ' ' or ch == '\t' or ch == '(' or ch == '{' or
                ch == ';' or ch == '=' or ch == '\n')
            {
                end = i;
                break;
            }
        }
        end = i + 1;
    }
    if (end == 0) return null;
    return line[0..end];
}

/// Try to extract a helper method name from a class feature block line.
/// Looks for: [modifiers] ReturnType MethodName(...) [where ...]
fn extractHelperMethod(line: []const u8) ?[]const u8 {
    // Must contain parentheses to be a method
    if (std.mem.indexOf(u8, line, "(")) |paren_pos| {
        // Check there's no { get or { set before the parens (property)
        if (std.mem.indexOf(u8, line, "{")) |brace_pos| {
            if (brace_pos < paren_pos) return null; // property, not method
        }
        // Extract the identifier just before the (
        const before_paren = std.mem.trim(u8, line[0..paren_pos], " \t");
        // Find the last space to get just the method name
        if (std.mem.lastIndexOfScalar(u8, before_paren, ' ')) |last_space| {
            const name = std.mem.trim(u8, before_paren[last_space + 1 ..], " \t");
            if (name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '_')) {
                return name;
            }
        }
    }
    return null;
}

/// Try to extract a helper property name from a class feature block line.
/// Looks for: [modifiers] Type PropertyName { get; set; }
fn extractHelperProperty(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "{")) |brace_pos| {
        // Check for property pattern: ... Name { get ... or ... Name { set ...
        const after_brace = std.mem.trim(u8, line[brace_pos + 1 ..], " \t");
        if (std.mem.startsWith(u8, after_brace, "get") or
            std.mem.startsWith(u8, after_brace, "set"))
        {
            const before_brace = std.mem.trim(u8, line[0..brace_pos], " \t");
            if (std.mem.lastIndexOfScalar(u8, before_brace, ' ')) |last_space| {
                const name = std.mem.trim(u8, before_brace[last_space + 1 ..], " \t");
                if (name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '_')) {
                    return name;
                }
            }
        }
    }
    return null;
}

/// Detail extraction for T4 symbols. Caller provides the output buffer.
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    switch (kind) {
        .directive_template => {
            // Extract language and hostspecific
            var len: usize = 0;
            if (extractDirectiveAttribute(line, "language")) |lang| {
                const copy = @min(lang.len, buf.len);
                @memcpy(buf[0..copy], lang[0..copy]);
                len = copy;
            }
            if (extractDirectiveAttribute(line, "hostspecific")) |hs| {
                if (std.mem.eql(u8, hs, "true") or std.mem.eql(u8, hs, "True")) {
                    const suffix = " host";
                    if (len + suffix.len <= buf.len) {
                        @memcpy(buf[len .. len + suffix.len], suffix);
                        len += suffix.len;
                    }
                }
            }
            return buf[0..len];
        },
        .directive_assembly => {
            // Extract the assembly name (may be a path)
            if (extractDirectiveAttribute(line, "name")) |name| {
                // Show just the filename, not full path
                const basename = if (std.mem.lastIndexOfScalar(u8, name, '\\')) |sep|
                    name[sep + 1 ..]
                else if (std.mem.lastIndexOfScalar(u8, name, '/')) |sep|
                    name[sep + 1 ..]
                else
                    name;
                const copy = @min(basename.len, buf.len);
                @memcpy(buf[0..copy], basename[0..copy]);
                return buf[0..copy];
            }
            return "";
        },
        .directive_output => {
            if (extractDirectiveAttribute(line, "extension")) |ext| {
                const copy = @min(ext.len, buf.len);
                @memcpy(buf[0..copy], ext[0..copy]);
                return buf[0..copy];
            }
            return "";
        },
        .directive_include => {
            if (extractDirectiveAttribute(line, "file")) |file| {
                const copy = @min(file.len, buf.len);
                @memcpy(buf[0..copy], file[0..copy]);
                return buf[0..copy];
            }
            return "";
        },
        .directive_parameter => {
            var len: usize = 0;
            if (extractDirectiveAttribute(line, "type")) |t| {
                const copy = @min(t.len, buf.len);
                @memcpy(buf[0..copy], t[0..copy]);
                len = copy;
            }
            return buf[0..len];
        },
        .helper_class => {
            // Extract base class if present: class Foo : Bar
            const inner = extractT4BlockInner(line);
            if (std.mem.indexOf(u8, inner, ":")) |colon_pos| {
                const after_colon = std.mem.trim(u8, inner[colon_pos + 1 ..], " \t");
                const base = extractCSharpIdentifier(after_colon) orelse return "";
                const copy = @min(base.len, buf.len);
                @memcpy(buf[0..copy], base[0..copy]);
                return buf[0..copy];
            }
            return "";
        },
        .helper_method => {
            // Extract return type
            const inner = extractT4BlockInner(line);
            if (std.mem.indexOf(u8, inner, "(")) |paren_pos| {
                const before_paren = std.mem.trim(u8, inner[0..paren_pos], " \t");
                if (std.mem.lastIndexOfScalar(u8, before_paren, ' ')) |last_space| {
                    const ret_type = std.mem.trim(u8, before_paren[0..last_space], " \t");
                    // Strip modifiers to get just the return type
                    if (extractFirstIdentifier(ret_type)) |rtype| {
                        // We want the last identifier (the return type)
                        const copy = @min(rtype.len, buf.len);
                        @memcpy(buf[0..copy], rtype[0..copy]);
                        return buf[0..copy];
                    }
                }
            }
            return "";
        },
        .helper_property => {
            // Extract type
            const inner = extractT4BlockInner(line);
            if (std.mem.indexOf(u8, inner, "{")) |brace_pos| {
                const before_brace = std.mem.trim(u8, inner[0..brace_pos], " \t");
                if (std.mem.lastIndexOfScalar(u8, before_brace, ' ')) |last_space| {
                    const type_part = std.mem.trim(u8, before_brace[0..last_space], " \t");
                    if (extractFirstIdentifier(type_part)) |t| {
                        const copy = @min(t.len, buf.len);
                        @memcpy(buf[0..copy], t[0..copy]);
                        return buf[0..copy];
                    }
                }
            }
            return "";
        },
        .code_block, .expression_block, .class_feature_block, .directive_import => return "",
    }
}
