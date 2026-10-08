// Adapted from upstream 36e35bf17624a277513b031c8826b552911763bf.
//! Shared gitignore matching for live listings and repository indexing.
//!
//! Subset of git's rules: comments, `!` negation, trailing-`/` directories,
//! leading-`/` (or mid-slash) anchored to the ignore file's directory, `*` / `?`
//! and bracket classes/ranges in a path segment, and `**` across segments. A parent directory that wins
//! as ignored hides its children (a `!` on a child does not pierce it).
//! `.git` itself is the walker's job, not this file.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Rule = struct {
    negated: bool,
    dir_only: bool,
    /// Leading `/` or a `/` in the middle — match from this ignore file's dir.
    anchored: bool,
    pattern: []const u8,
    /// Absolute directory that contained the ignore file (no trailing slash).
    base: []const u8,
};

pub const Verdict = enum { none, ignore, include };

pub fn parse(arena: Allocator, text: []const u8, base: []const u8) ![]Rule {
    var list: std.ArrayList(Rule) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(arena, parseLine(line, base));
    }
    return list.items;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn parseLine(line: []const u8, base: []const u8) Rule {
    var s = line;
    var negated = false;
    if (s[0] == '!') {
        negated = true;
        s = s[1..];
    }
    var dir_only = false;
    if (s.len > 0 and s[s.len - 1] == '/') {
        dir_only = true;
        s = s[0 .. s.len - 1];
    }
    var anchored = false;
    if (s.len > 0 and s[0] == '/') {
        anchored = true;
        s = s[1..];
    }
    if (std.mem.indexOfScalar(u8, s, '/') != null) anchored = true;
    return .{
        .negated = negated,
        .dir_only = dir_only,
        .anchored = anchored,
        .pattern = s,
        .base = base,
    };
}

fn under(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/';
}

/// Path of `abs` relative to `base`, or null when `abs` is not under `base`.
/// The base directory itself yields empty string.
pub fn relTo(abs: []const u8, base: []const u8) ?[]const u8 {
    if (!under(abs, base)) return null;
    if (abs.len == base.len) return "";
    return abs[base.len + 1 ..];
}

fn globSeg(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globSeg(pat[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (pat[0] == '[') {
        var i: usize = 1;
        const negated = i < pat.len and (pat[i] == '!' or pat[i] == '^');
        if (negated) i += 1;
        const first = i;
        var matched = false;
        // A closing bracket is literal in the first class position.
        if (i < pat.len and pat[i] == ']') {
            matched = s[0] == ']';
            i += 1;
        }
        while (i < pat.len and pat[i] != ']') {
            var lo = pat[i];
            if (lo == '\\' and i + 1 < pat.len) { i += 1; lo = pat[i]; }
            i += 1;
            if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
                i += 1;
                if (pat[i] == '\\' and i + 1 < pat.len) i += 1;
                const hi = pat[i];
                i += 1;
                matched = matched or (s[0] >= lo and s[0] <= hi);
            } else matched = matched or s[0] == lo;
        }
        if (i < pat.len and i > first) {
            return (matched != negated) and globSeg(pat[i + 1 ..], s[1..]);
        }
        // An unterminated class matches a literal '[' (Git wildmatch).
    }
    if (pat[0] == '\\' and pat.len > 1) return pat[1] == s[0] and globSeg(pat[2..], s[1..]);
    if (pat[0] == '?' or pat[0] == s[0]) return globSeg(pat[1..], s[1..]);
    return false;
}

test "gitignore bracket classes ranges and malformed classes" {
    try std.testing.expect(globSeg("*.[Pp]ublish.xml", "Autumn_Debug_.publish.xml"));
    try std.testing.expect(globSeg("[Dd]ebug", "Debug"));
    try std.testing.expect(globSeg("file[0-9].ts", "file7.ts"));
    try std.testing.expect(!globSeg("file[!0-9].ts", "file7.ts"));
    try std.testing.expect(globSeg("file[!0-9].ts", "filex.ts"));
    try std.testing.expect(globSeg("file[].].ts", "file].ts"));
    try std.testing.expect(!globSeg("[Pp", "p"));
    try std.testing.expect(globSeg("[Pp", "[Pp"));
    try std.testing.expect(globSeg("file\\?.ts", "file?.ts"));
}

const Segment = struct {
    value: []const u8,
    next: usize,
};

fn nextSegment(s: []const u8, start: usize) ?Segment {
    var begin = start;
    while (begin < s.len and s[begin] == '/') begin += 1;
    if (begin >= s.len) return null;
    const end = std.mem.indexOfScalarPos(u8, s, begin, '/') orelse s.len;
    return .{ .value = s[begin..end], .next = end };
}

/// Allocation-free segment matcher. Indexing calls this once per path, so the
/// old split-into-ArrayList implementation accumulated scan-sized scratch
/// allocations when its caller used a long-lived arena.
fn matchSegs(pattern: []const u8, pattern_at: usize, path: []const u8, path_at: usize) bool {
    const pat = nextSegment(pattern, pattern_at) orelse return nextSegment(path, path_at) == null;
    if (std.mem.eql(u8, pat.value, "**")) {
        if (nextSegment(pattern, pat.next) == null) return true;
        if (matchSegs(pattern, pat.next, path, path_at)) return true;
        var cursor = path_at;
        while (nextSegment(path, cursor)) |segment| {
            cursor = segment.next;
            if (matchSegs(pattern, pat.next, path, cursor)) return true;
        }
        return false;
    }
    const part = nextSegment(path, path_at) orelse return false;
    if (!globSeg(pat.value, part.value)) return false;
    return matchSegs(pattern, pat.next, path, part.next);
}

fn matchPattern(arena: Allocator, pattern: []const u8, local: []const u8, anchored: bool) !bool {
    _ = arena;
    if (pattern.len == 0) return false;
    if (anchored) return matchSegs(pattern, 0, local, 0);
    if (matchSegs(pattern, 0, local, 0)) return true;
    var cursor: usize = 0;
    while (nextSegment(local, cursor)) |segment| {
        cursor = segment.next;
        if (matchSegs(pattern, 0, local, cursor)) return true;
    }
    return false;
}

fn ruleHits(arena: Allocator, rule: Rule, abs: []const u8, is_dir: bool) !bool {
    if (rule.dir_only and !is_dir) return false;
    const local = relTo(abs, rule.base) orelse return false;
    if (local.len == 0) return false; // the ignore file's own directory
    return matchPattern(arena, rule.pattern, local, rule.anchored);
}

/// Last matching rule wins.
pub fn verdict(arena: Allocator, rules: []const Rule, abs: []const u8, is_dir: bool) !Verdict {
    var v: Verdict = .none;
    for (rules) |r| {
        if (try ruleHits(arena, r, abs, is_dir)) {
            v = if (r.negated) .include else .ignore;
        }
    }
    return v;
}

/// True when `abs` or a parent under the walk is ignored. `walk_root` stops
/// the parent walk so we do not apply a rule to a path above the listing.
pub fn ignored(arena: Allocator, rules: []const Rule, walk_root: []const u8, abs: []const u8, is_dir: bool) !bool {
    if (!under(abs, walk_root)) return false;
    var start: usize = if (abs.len > walk_root.len) walk_root.len + 1 else abs.len;
    while (start <= abs.len) {
        const slash = if (start >= abs.len) abs.len else (std.mem.indexOfScalarPos(u8, abs, start, '/') orelse abs.len);
        const prefix = abs[0..slash];
        const prefix_dir = slash < abs.len or is_dir;
        const last = slash == abs.len;
        switch (try verdict(arena, rules, prefix, prefix_dir)) {
            .ignore => return true,
            .include => if (last) return false,
            .none => {},
        }
        if (slash == abs.len) break;
        start = slash + 1;
    }
    return false;
}

