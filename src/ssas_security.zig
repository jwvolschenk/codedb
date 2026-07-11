//! Content-level secret filtering for SSAS source and deployment artifacts.
//!
//! Path filtering alone cannot protect checked-in `.bim`/XMLA deployment
//! sources: those formats can carry credentials in otherwise legitimate
//! project files. Keep this check extension-gated so ordinary source indexing
//! does not pay for a content scan or acquire surprising false positives.

const std = @import("std");

const extensions = [_][]const u8{
    ".bim",        ".tmdl",              ".dax",               ".mdx",                ".cube", ".xmla", ".smproj", ".dwproj",
    ".asdatabase", ".deploymenttargets", ".deploymentoptions", ".deploymentmetadata",
};

pub fn isSsasContentPath(path: []const u8) bool {
    for (extensions) |ext| {
        if (endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn containsSensitiveContent(path: []const u8, content: []const u8) bool {
    if (!isSsasContentPath(path)) return false;

    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '"' or c == '\'') {
            const quote = c;
            const key_start = i + 1;
            const key_end = findQuote(content, key_start, quote) orelse return false;
            if (isSecretKey(content[key_start..key_end])) {
                var p = skipSpace(content, key_end + 1);
                if (p < content.len and (content[p] == ':' or content[p] == '=')) {
                    p = skipSpace(content, p + 1);
                    if (hasNonEmptyValue(content, p)) return true;
                }
            }
            // Connection strings and deployment properties frequently embed
            // `Password=...`/`Pwd=...` inside an otherwise unrelated JSON or
            // XML string value. Inspect the bounded quoted slice as well as
            // structured key/value pairs.
            if (containsInlineSecret(content[key_start..key_end])) return true;
            i = key_end + 1;
            continue;
        }

        if (c == '<' and i + 1 < content.len and content[i + 1] != '/' and
            content[i + 1] != '!' and content[i + 1] != '?')
        {
            var name_end = i + 1;
            while (name_end < content.len and isKeyChar(content[name_end])) : (name_end += 1) {}
            if (name_end > i + 1 and isSecretKey(content[i + 1 .. name_end])) {
                const gt = std.mem.indexOfScalarPos(u8, content, name_end, '>') orelse return false;
                const value_end = std.mem.indexOfScalarPos(u8, content, gt + 1, '<') orelse content.len;
                if (isNonEmptyToken(content[gt + 1 .. value_end])) return true;
            }
        }

        if ((i == 0 or content[i - 1] == '\n' or content[i - 1] == '\r') or
            (i > 0 and (content[i - 1] == ' ' or content[i - 1] == '\t')))
        {
            var key_end = i;
            while (key_end < content.len and isKeyChar(content[key_end])) : (key_end += 1) {}
            if (key_end > i and isSecretKey(content[i..key_end])) {
                var p = skipSpace(content, key_end);
                if (p < content.len and (content[p] == ':' or content[p] == '=')) {
                    p = skipSpace(content, p + 1);
                    if (hasNonEmptyValue(content, p)) return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

fn containsInlineSecret(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (i > 0 and text[i - 1] != ';' and text[i - 1] != ',' and
            !std.ascii.isWhitespace(text[i - 1]))
        {
            i += 1;
            continue;
        }
        var key_end = i;
        while (key_end < text.len and isKeyChar(text[key_end])) : (key_end += 1) {}
        if (key_end > i and isSecretKey(text[i..key_end])) {
            var p = skipSpace(text, key_end);
            if (p < text.len and (text[p] == '=' or text[p] == ':')) {
                p = skipSpace(text, p + 1);
                var end = p;
                while (end < text.len and text[end] != ';' and text[end] != ',') : (end += 1) {}
                if (isNonEmptyToken(text[p..end])) return true;
            }
        }
        i = if (key_end > i) key_end else i + 1;
    }
    return false;
}

fn hasNonEmptyValue(content: []const u8, start: usize) bool {
    if (start >= content.len) return false;
    if (content[start] == '"' or content[start] == '\'') {
        const end = findQuote(content, start + 1, content[start]) orelse content.len;
        return isNonEmptyToken(content[start + 1 .. end]);
    }
    var end = start;
    while (end < content.len and content[end] != ',' and content[end] != '\n' and
        content[end] != '\r' and content[end] != '}' and content[end] != '<') : (end += 1)
    {}
    return isNonEmptyToken(content[start..end]);
}

fn isNonEmptyToken(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\r\n\"");
    if (value.len == 0) return false;
    if (eqlIgnoreCase(value, "null") or eqlIgnoreCase(value, "none")) return false;
    return true;
}

fn isSecretKey(raw: []const u8) bool {
    var normalized: [64]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n == normalized.len) return false;
            normalized[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    const key = normalized[0..n];
    const keys = [_][]const u8{
        "password", "pwd", "accountkey", "accesstoken", "clientsecret", "apikey", "privatekey",
    };
    for (keys) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn findQuote(content: []const u8, start: usize, quote: u8) ?usize {
    var escaped = false;
    var i = start;
    while (i < content.len) : (i += 1) {
        if (escaped) {
            escaped = false;
        } else if (content[i] == '\\') {
            escaped = true;
        } else if (content[i] == quote) {
            return i;
        }
    }
    return null;
}

fn skipSpace(content: []const u8, start: usize) usize {
    var i = start;
    while (i < content.len and std.ascii.isWhitespace(content[i])) : (i += 1) {}
    return i;
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn endsWithIgnoreCase(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    return eqlIgnoreCase(path[path.len - suffix.len ..], suffix);
}

test "SSAS sensitive content distinguishes credentials from connection metadata" {
    try std.testing.expect(containsSensitiveContent("model.bim", "{\"password\":\"hunter2\"}"));
    try std.testing.expect(containsSensitiveContent("model.xmla", "<ClientSecret>abc</ClientSecret>"));
    try std.testing.expect(containsSensitiveContent("model.tmdl", "account-key: value\n"));
    try std.testing.expect(containsSensitiveContent("model.bim", "{\"connectionString\":\"Server=db;Pwd=hunter2;Encrypt=true\"}"));
    try std.testing.expect(!containsSensitiveContent("model.bim", "{\"Username\":\"alice\",\"server\":\"db\",\"AuthenticationKind\":\"Windows\",\"password\":null}"));
    try std.testing.expect(!containsSensitiveContent("main.zig", "const password = \"not extension gated\";"));
}
