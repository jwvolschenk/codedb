// codedb — glob pattern matching for path filters.
const std = @import("std");

/// Brace alternation (`{a,b}`) is expanded before matching, so
/// `**/*.{cs,cshtml}` and `src/{Foo,Bar}Controller.cs` behave as in a shell.
/// Groups may nest and alternatives may be empty (`file{,.bak}.txt`). A `{`
/// with no matching `}` is an ordinary character.
pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    return matchBraces(pattern, path, 0);
}

const max_brace_depth = 8;
const brace_buf_len = 512;

fn matchBraces(pattern: []const u8, path: []const u8, depth: usize) bool {
    const open = std.mem.indexOfScalar(u8, pattern, '{') orelse return matchGlobPlain(pattern, path);
    const close = findBraceClose(pattern, open) orelse return matchGlobPlain(pattern, path);
    if (depth >= max_brace_depth) return false;

    const pre = pattern[0..open];
    const body = pattern[open + 1 .. close];
    const post = pattern[close + 1 ..];

    var buf: [brace_buf_len]u8 = undefined;
    var alt_start: usize = 0;
    var i: usize = 0;
    var nest: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i < body.len) {
            switch (body[i]) {
                '{' => nest += 1,
                '}' => nest -= 1,
                else => {},
            }
            if (!(body[i] == ',' and nest == 0)) continue;
        }
        // End of one top-level alternative: splice it between pre and post.
        const alt = body[alt_start..i];
        alt_start = i + 1;
        if (pre.len + alt.len + post.len > buf.len) continue;
        @memcpy(buf[0..pre.len], pre);
        @memcpy(buf[pre.len .. pre.len + alt.len], alt);
        @memcpy(buf[pre.len + alt.len .. pre.len + alt.len + post.len], post);
        if (matchBraces(buf[0 .. pre.len + alt.len + post.len], path, depth + 1)) return true;
    }
    return false;
}

/// Index of the `}` closing the `{` at `open`, honouring nested groups.
fn findBraceClose(pattern: []const u8, open: usize) ?usize {
    var nest: usize = 0;
    var i = open;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '{' => nest += 1,
            '}' => {
                nest -= 1;
                if (nest == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn matchGlobPlain(pattern: []const u8, path: []const u8) bool {
    // Fast path: `**/*X` where X is a literal — degenerates to endsWith(X).
    // Covers the common agent-style pattern `**/*.ext`.
    if (globIsPureSuffix(pattern)) |suffix| {
        return std.mem.endsWith(u8, path, suffix);
    }
    // Fast path: literal prefix before any wildcard. If the path doesn't
    // start with that prefix, we can reject without recursing.
    var lit_end: usize = 0;
    while (lit_end < pattern.len) : (lit_end += 1) {
        const c = pattern[lit_end];
        if (c == '*' or c == '?') break;
    }
    if (lit_end > 0) {
        if (path.len < lit_end) return false;
        if (!std.mem.startsWith(u8, path, pattern[0..lit_end])) return false;
        if (lit_end == pattern.len) return path.len == lit_end;
    }
    return matchGlobRec(pattern, lit_end, path, lit_end);
}

/// If `pattern` is exactly `**/*X` for some literal X (no `*`/`?` in X),
/// returns X. Such patterns are equivalent to `endsWith(X)` because `**` may
/// absorb everything up to the last `/` and the trailing `*` consumes the
/// basename. Patterns like `*X` (single star) do NOT qualify because a single
/// `*` cannot cross `/`.
pub fn globIsPureSuffix(pattern: []const u8) ?[]const u8 {
    if (pattern.len < 4) return null;
    if (pattern[0] != '*' or pattern[1] != '*' or pattern[2] != '/' or pattern[3] != '*') return null;
    const tail = pattern[4..];
    for (tail) |c| if (c == '*' or c == '?') return null;
    return tail;
}

pub fn matchGlobRec(pattern: []const u8, gi_start: usize, path: []const u8, ti_start: usize) bool {
    var gi = gi_start;
    var ti = ti_start;
    while (gi < pattern.len) {
        const c = pattern[gi];
        if (c == '*') {
            if (gi + 1 < pattern.len and pattern[gi + 1] == '*') {
                // ** matches across path separators
                var rest = gi + 2;
                if (rest < pattern.len and pattern[rest] == '/') rest += 1;
                if (matchGlobRec(pattern, rest, path, ti)) return true;
                var k: usize = ti;
                while (k < path.len) : (k += 1) {
                    if (matchGlobRec(pattern, rest, path, k + 1)) return true;
                }
                return false;
            } else {
                // single * does not cross /
                if (matchGlobRec(pattern, gi + 1, path, ti)) return true;
                var k: usize = ti;
                while (k < path.len and path[k] != '/') : (k += 1) {
                    if (matchGlobRec(pattern, gi + 1, path, k + 1)) return true;
                }
                return false;
            }
        } else if (c == '?') {
            if (ti >= path.len or path[ti] == '/') return false;
            gi += 1;
            ti += 1;
        } else {
            if (ti >= path.len or path[ti] != c) return false;
            gi += 1;
            ti += 1;
        }
    }
    return ti == path.len;
}
