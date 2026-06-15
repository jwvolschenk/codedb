const std = @import("std");
const ident = @import("explore/ident_utils.zig");

/// TSQL-specific symbol kinds for .sql files.
pub const Kind = enum {
    procedure, // CREATE/ALTER PROCEDURE
    function_def, // CREATE/ALTER FUNCTION
    view, // CREATE/ALTER VIEW
    table_def, // CREATE/ALTER TABLE
    trigger, // CREATE/ALTER TRIGGER
    schema, // CREATE/ALTER SCHEMA
    type_def, // CREATE/ALTER TYPE
    sequence, // CREATE/ALTER SEQUENCE
    synonym, // CREATE/ALTER SYNONYM
    index_def, // CREATE/ALTER INDEX
    variable, // DECLARE @variable
    exec_ref, // EXEC/EXECUTE call (dependency)
    table_ref, // FROM/JOIN/INSERT INTO/UPDATE/DELETE FROM (dependency)
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    import: struct {
        path: []const u8,
    },
};

/// Strip a TSQL line comment (-- ...) respecting string literals.
/// Returns the trimmed line with the comment removed.
pub fn stripLineComment(raw_line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r");
    if (trimmed.len == 0) return "";
    // Skip if entire line is a comment
    if (startsWith(trimmed, "--")) return "";
    // Find -- that's not inside a string
    var in_string = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '\'' and !in_string) {
            in_string = true;
        } else if (trimmed[i] == '\'' and in_string) {
            // Check for escaped quote ''
            if (i + 1 < trimmed.len and trimmed[i + 1] == '\'') {
                i += 1;
            } else {
                in_string = false;
            }
        } else if (!in_string and i + 1 < trimmed.len and trimmed[i] == '-' and trimmed[i + 1] == '-') {
            return std.mem.trimEnd(u8, trimmed[0..i], " \t");
        }
    }
    return trimmed;
}

/// Check if a line is a blank or comment-only line.
pub fn isCommentOrBlank(raw_line: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r");
    if (trimmed.len == 0) return true;
    if (startsWith(trimmed, "--")) return true;
    if (startsWith(trimmed, "/*")) return true;
    if (startsWith(trimmed, "*")) return true;
    return false;
}

/// Parse a TSQL line. Returns the parsed result.
/// The caller is responsible for block comment state tracking.
pub fn parseLine(raw_line: []const u8) ParsedLine {
    // Strip UTF-8 BOM (EF BB BF) — Visual Studio-generated SQL files often have this
    const unbommed = if (raw_line.len >= 3 and raw_line[0] == 0xEF and raw_line[1] == 0xBB and raw_line[2] == 0xBF)
        raw_line[3..]
    else
        raw_line;
    const line = stripLineComment(unbommed);
    if (line.len == 0) return .none;

    // ── GO batch separator (skip) ─────────────────────────────────
    if (equalsIgnoreCase(line, "go")) return .none;

    // ── DECLARE @variable ─────────────────────────────────────────
    if (parseDeclare(line)) |sym| return sym;

    // ── CREATE/ALTER object definitions ───────────────────────────
    if (parseCreateOrAlter(line)) |sym| return sym;

    // ── EXEC/EXECUTE calls (dependency tracking) ──────────────────
    if (parseExec(line)) |imp| return imp;

    // ── FROM/JOIN references (dependency tracking) ────────────────
    if (parseFromRef(line)) |imp| return imp;

    // ── INSERT INTO references (dependency tracking) ──────────────
    if (parseInsertInto(line)) |imp| return imp;

    // ── UPDATE references (dependency tracking) ───────────────────
    if (parseUpdateRef(line)) |imp| return imp;

    // ── DELETE FROM references (dependency tracking) ──────────────
    if (parseDeleteFrom(line)) |imp| return imp;

    return .none;
}

/// Extract detail text for a TSQL symbol (parameter list, return type, etc.)
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    _ = kind;
    // For procedures/functions, try to extract the parameter list
    if (std.mem.indexOf(u8, line, "(")) |open| {
        if (std.mem.indexOf(u8, line[open..], ")")) |close_rel| {
            const params = line[open .. open + close_rel + 1];
            if (params.len > 0 and params.len <= buf.len) {
                @memcpy(buf[0..params.len], params);
                return buf[0..params.len];
            }
        }
    }
    return "";
}

// ── Internal parsers ────────────────────────────────────────────────

fn parseDeclare(line: []const u8) ?ParsedLine {
    if (!startsWithIgnoreCase(line, "declare ")) return null;
    const rest = std.mem.trimStart(u8, line["declare ".len..], " \t");
    // Must start with @
    if (rest.len == 0 or rest[0] != '@') return null;
    const name = extractSqlIdent(rest);
    if (name.len == 0) return null;
    return .{ .symbol = .{ .name = name, .kind = .variable } };
}

fn parseCreateOrAlter(line: []const u8) ?ParsedLine {
    // Handle CREATE [OR ALTER] and ALTER
    var rest: []const u8 = undefined;
    if (startsWithIgnoreCase(line, "create ")) {
        rest = std.mem.trimStart(u8, line["create ".len..], " \t");
        // Skip OR ALTER, OR REPLACE
        if (startsWithIgnoreCase(rest, "or alter "))
            rest = std.mem.trimStart(u8, rest["or alter ".len..], " \t")
        else if (startsWithIgnoreCase(rest, "or replace "))
            rest = std.mem.trimStart(u8, rest["or replace ".len..], " \t");
    } else if (startsWithIgnoreCase(line, "alter ")) {
        rest = std.mem.trimStart(u8, line["alter ".len..], " \t");
    } else {
        return null;
    }

    // Skip PROCEDURE/FUNCTION modifiers like INLINE, SCHEMABINDING etc.
    // Also handle: CREATE PROC, CREATE PROCEDURE, CREATE OR ALTER PROCEDURE
    return parseTsqlObjectDef(rest);
}

fn parseTsqlObjectDef(rest: []const u8) ?ParsedLine {
    // Table of keyword -> Kind mappings, longest first to avoid prefix conflicts
    const mappings = [_]struct { keyword: []const u8, kind: Kind }{
        .{ .keyword = "procedure ", .kind = .procedure },
        .{ .keyword = "proc ", .kind = .procedure },
        .{ .keyword = "function ", .kind = .function_def },
        .{ .keyword = "view ", .kind = .view },
        .{ .keyword = "table ", .kind = .table_def },
        .{ .keyword = "trigger ", .kind = .trigger },
        .{ .keyword = "schema ", .kind = .schema },
        .{ .keyword = "type ", .kind = .type_def },
        .{ .keyword = "sequence ", .kind = .sequence },
        .{ .keyword = "synonym ", .kind = .synonym },
        .{ .keyword = "index ", .kind = .index_def },
        .{ .keyword = "unique index ", .kind = .index_def },
        .{ .keyword = "clustered index ", .kind = .index_def },
        .{ .keyword = "nonclustered index ", .kind = .index_def },
        .{ .keyword = "unique clustered index ", .kind = .index_def },
        .{ .keyword = "unique nonclustered index ", .kind = .index_def },
    };

    for (mappings) |m| {
        if (startsWithIgnoreCase(rest, m.keyword)) {
            var body = std.mem.trimStart(u8, rest[m.keyword.len..], " \t");
            // Skip IF NOT EXISTS
            if (startsWithIgnoreCase(body, "if not exists "))
                body = std.mem.trimStart(u8, body["if not exists ".len..], " \t");
            // Skip [dbo]. or dbo. prefix to get the object name
            const name = extractSchemaQualifiedName(body);
            if (name.len == 0) return null;
            return .{ .symbol = .{ .name = name, .kind = m.kind } };
        }
    }
    return null;
}

fn parseExec(line: []const u8) ?ParsedLine {
    var rest: []const u8 = undefined;
    if (startsWithIgnoreCase(line, "exec "))
        rest = std.mem.trimStart(u8, line["exec ".len..], " \t")
    else if (startsWithIgnoreCase(line, "execute "))
        rest = std.mem.trimStart(u8, line["execute ".len..], " \t")
    else
        return null;

    // Skip EXEC @variable = procedure calls
    if (rest.len > 0 and rest[0] == '@') return null;

    // Skip EXEC('...') dynamic SQL
    if (rest.len > 0 and rest[0] == '(') return null;

    const name = extractSchemaQualifiedName(rest);
    if (name.len == 0) return null;
    return .{ .import = .{ .path = name } };
}

fn parseFromRef(line: []const u8) ?ParsedLine {
    // Match FROM or JOIN at word boundary
    const table_name = extractFromJoinTable(line);
    if (table_name) |name| {
        if (name.len == 0) return null;
        return .{ .import = .{ .path = name } };
    }
    return null;
}

fn parseInsertInto(line: []const u8) ?ParsedLine {
    if (!startsWithIgnoreCase(line, "insert ")) return null;
    const rest = std.mem.trimStart(u8, line["insert ".len..], " \t");
    // Skip INSERT INTO, INSERT, INSERT TOP
    var body = rest;
    if (startsWithIgnoreCase(body, "into "))
        body = std.mem.trimStart(u8, body["into ".len..], " \t");
    // Skip TOP(...)
    if (startsWithIgnoreCase(body, "top ")) {
        // Find the end of the TOP clause
        if (std.mem.indexOf(u8, body, ")")) |close| {
            body = std.mem.trimStart(u8, body[close + 1 ..], " \t");
            if (startsWithIgnoreCase(body, "into "))
                body = std.mem.trimStart(u8, body["into ".len..], " \t");
        }
    }

    const name = extractSchemaQualifiedName(body);
    if (name.len == 0) return null;
    return .{ .import = .{ .path = name } };
}

fn parseUpdateRef(line: []const u8) ?ParsedLine {
    if (!startsWithIgnoreCase(line, "update ")) return null;
    var rest = std.mem.trimStart(u8, line["update ".len..], " \t");
    // Skip UPDATE TOP(...)
    if (startsWithIgnoreCase(rest, "top ")) {
        if (std.mem.indexOf(u8, rest, ")")) |close| {
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        }
    }

    const name = extractSchemaQualifiedName(rest);
    if (name.len == 0) return null;
    return .{ .import = .{ .path = name } };
}

fn parseDeleteFrom(line: []const u8) ?ParsedLine {
    if (!startsWithIgnoreCase(line, "delete ")) return null;
    const rest = std.mem.trimStart(u8, line["delete ".len..], " \t");
    // DELETE FROM table or DELETE table
    var body = rest;
    if (startsWithIgnoreCase(body, "from "))
        body = std.mem.trimStart(u8, body["from ".len..], " \t");

    const name = extractSchemaQualifiedName(body);
    if (name.len == 0) return null;
    return .{ .import = .{ .path = name } };
}

/// Extract table name from FROM/JOIN clauses.
/// Handles: FROM table, JOIN table, LEFT JOIN, RIGHT JOIN, INNER JOIN, etc.
fn extractFromJoinTable(line: []const u8) ?[]const u8 {
    // Prepend a space so keywords with leading space match at line start
    var buf: [512]u8 = undefined;
    if (line.len + 1 > buf.len) return null;
    buf[0] = ' ';
    @memcpy(buf[1 .. line.len + 1], line);
    const padded = buf[0 .. line.len + 1];

    // Try to find FROM or JOIN keyword
    const keywords = [_][]const u8{
        " cross join ",
        " cross apply ",
        " outer apply ",
        " full outer join ",
        " full join ",
        " left outer join ",
        " left join ",
        " right outer join ",
        " right join ",
        " inner join ",
        " join ",
        " from ",
    };

    // Find the LAST occurrence of any keyword (to handle nested subqueries)
    var best_pos: ?usize = null;
    var best_kw_len: usize = 0;

    for (keywords) |kw| {
        // Search from the end to find the last occurrence
        var pos: ?usize = null;
        var search_start: usize = 0;
        while (search_start < padded.len) {
            if (indexOfIgnoreCase(padded[search_start..], kw)) |rel_pos| {
                const abs_pos = search_start + rel_pos;
                pos = abs_pos;
                search_start = abs_pos + kw.len;
            } else {
                break;
            }
        }
        if (pos) |p| {
            if (best_pos == null or p > best_pos.?) {
                best_pos = p;
                best_kw_len = kw.len;
            }
        }
    }

    if (best_pos) |pos| {
        const after_kw = std.mem.trimStart(u8, padded[pos + best_kw_len ..], " \t");
        // Skip subquery
        if (after_kw.len > 0 and after_kw[0] == '(') return null;
        return extractSchemaQualifiedName(after_kw);
    }
    return null;
}

// ── Identifier extraction helpers ───────────────────────────────────

/// Extract a schema-qualified name like [dbo].[Table], dbo.Table, or [database].[dbo].[Table]
/// Returns the normalized name (without brackets).
fn extractSchemaQualifiedName(s: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    if (trimmed.len == 0) return "";

    // Handle bracketed names: [name] or [schema].[name]
    if (trimmed[0] == '[') {
        return extractBracketedName(trimmed);
    }

    // Handle dotted names: schema.name or schema.name.name
    // Also handle @table_var (table variables - skip them)
    if (trimmed.len > 0 and trimmed[0] == '@') return "";

    // Extract until whitespace, comma, semicolon, parenthesis, or end
    var end: usize = 0;
    var last_dot: usize = 0;
    while (end < trimmed.len) {
        const ch = trimmed[end];
        if (ch == ' ' or ch == '\t' or ch == ',' or ch == ';' or ch == '(' or ch == ')' or ch == '\r' or ch == '\n')
            break;
        if (ch == '.')
            last_dot = end;
        if (ch == '[' or ch == ']')
            break; // Mixed bracket/unbracketed - stop
        end += 1;
    }
    if (end == 0) return "";

    // If there's a dot, include up to the last dot segment
    // But only if the name looks like a schema reference (not a string, not a keyword)
    const name = trimmed[0..end];

    // Skip common SQL keywords that aren't object names
    if (isReservedKeyword(name)) return "";

    return name;
}

/// Extract a bracketed name like [dbo].[Table] or [database].[dbo].[Table]
fn extractBracketedName(s: []const u8) []const u8 {
    var end: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            // Find matching ]
            if (std.mem.indexOf(u8, s[i..], "]")) |close| {
                i += close + 1;
                end = i;
                // Check for another [ immediately after
                if (i < s.len and s[i] == '.') {
                    i += 1; // skip dot
                    end = i;
                    continue;
                }
                break;
            } else {
                // Unclosed bracket
                break;
            }
        } else if (s[i] == ' ' or s[i] == '\t' or s[i] == ',' or s[i] == ';') {
            break;
        } else {
            i += 1;
            end = i;
        }
    }
    if (end == 0) return "";

    // Normalize: strip brackets for the symbol name
    return normalizeBracketedName(s[0..end]);
}

/// Normalize a bracketed name: [dbo].[Table] -> dbo.Table
fn normalizeBracketedName(s: []const u8) []const u8 {
    // For now, return as-is since the caller may not own the buffer
    // The outline will store the raw text as detail
    // We strip brackets in the name for cleaner symbol display
    return s;
}

/// Normalize a SQL name by stripping brackets and converting to schema.object format.
/// Writes the normalized name into `buf` and returns the slice.
/// Examples:
///   [dbo].[Table] -> dbo.Table
///   [Holding].[vPosition] -> Holding.vPosition
///   dbo.Table -> dbo.Table (unchanged)
///   vPosition -> vPosition (unchanged)
pub fn normalizeSqlName(name: []const u8, buf: []u8) []const u8 {
    if (name.len == 0) return "";
    if (name.len >= buf.len) return name; // too long, return as-is

    // Fast path: no brackets present
    var has_bracket = false;
    for (name) |c| {
        if (c == '[' or c == ']') {
            has_bracket = true;
            break;
        }
    }
    if (!has_bracket) return name;

    // Strip brackets
    var out_pos: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] == '[') {
            // Skip opening bracket
            i += 1;
            // Copy until closing bracket
            while (i < name.len and name[i] != ']') {
                if (out_pos < buf.len) {
                    buf[out_pos] = name[i];
                    out_pos += 1;
                }
                i += 1;
            }
            // Skip closing bracket
            if (i < name.len and name[i] == ']') i += 1;
            // Skip dot after bracket
            if (i < name.len and name[i] == '.') {
                if (out_pos < buf.len) {
                    buf[out_pos] = '.';
                    out_pos += 1;
                }
                i += 1;
            }
        } else if (name[i] == ']') {
            // Stray closing bracket, skip
            i += 1;
        } else {
            if (out_pos < buf.len) {
                buf[out_pos] = name[i];
                out_pos += 1;
            }
            i += 1;
        }
    }
    return buf[0..out_pos];
}

/// Extract the bare object name from a schema-qualified SQL name.
/// Examples:
///   dbo.GetUsers -> GetUsers
///   [Holding].[vPosition] -> vPosition
///   vPosition -> vPosition
pub fn extractBareObjectName(name: []const u8) []const u8 {
    if (name.len == 0) return "";

    // Find the last dot that's not inside brackets
    var last_dot: ?usize = null;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] == '[') {
            // Skip bracketed section
            while (i < name.len and name[i] != ']') i += 1;
            if (i < name.len) i += 1; // skip ]
        } else if (name[i] == '.') {
            last_dot = i;
            i += 1;
        } else {
            i += 1;
        }
    }

    const bare = if (last_dot) |dot| name[dot + 1 ..] else name;

    // Strip brackets from the bare name
    var start: usize = 0;
    var end: usize = bare.len;
    if (start < end and bare[start] == '[') start += 1;
    if (end > start and bare[end - 1] == ']') end -= 1;

    return bare[start..end];
}

/// Extract a simple SQL identifier (possibly @-prefixed for variables)
fn extractSqlIdent(s: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " \t");
    if (trimmed.len == 0) return "";
    var end: usize = 0;
    while (end < trimmed.len) {
        const ch = trimmed[end];
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '@') {
            end += 1;
        } else {
            break;
        }
    }
    return trimmed[0..end];
}

// ── String/keyword helpers ──────────────────────────────────────────

fn isReservedKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "select",    "from",    "where",     "and",      "or",       "not",
        "in",        "exists",  "between",   "like",     "is",       "null",
        "as",        "on",      "set",       "values",   "into",     "top",
        "distinct",  "all",     "order",     "by",       "group",    "having",
        "union",     "except",  "intersect", "case",     "when",     "then",
        "else",      "end",     "begin",     "if",       "while",    "for",
        "cursor",    "open",    "close",     "deallocate", "fetch",  "next",
        "return",    "returns", "with",      "option",   "recompile",
        "noexpand",  "pivot",   "unpivot",   "apply",    "outer",    "cross",
        "left",      "right",   "inner",     "full",     "join",     "declare",
        "exec",      "execute", "print",     "raiserror", "throw",   "try",
        "catch",     "transaction", "tran",  "commit",   "rollback", "save",
        "goto",      "waitfor", "delay",     "time",     "break",    "continue",
        "merge",     "using",   "output",    "inserted", "deleted",  "table",
        "view",      "index",   "procedure", "proc",     "function", "trigger",
        "schema",    "type",    "sequence",  "synonym",  "database", "server",
        "alter",     "create",  "drop",      "grant",    "revoke",   "deny",
        "truncate",  "update",  "delete",    "backup",   "restore",  "use",
    };
    for (keywords) |kw| {
        if (equalsIgnoreCase(name, kw)) return true;
    }
    return false;
}

// ── String utility functions ────────────────────────────────────────

const startsWith = ident.startsWith;

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.ascii.eqlIgnoreCase(a, b);
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const limit = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
