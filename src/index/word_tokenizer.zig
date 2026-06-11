const std = @import("std");
const chars = @import("chars.zig");
const isWordChar = chars.isWordChar;
const normalizeChar = chars.normalizeChar;

pub const WordTokenizer = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordTokenizer) ?[]const u8 {
        // Skip non-word chars
        while (self.pos < self.buf.len and !isWordChar(self.buf[self.pos])) {
            self.pos += 1;
        }
        if (self.pos >= self.buf.len) return null;

        const start = self.pos;
        while (self.pos < self.buf.len and isWordChar(self.buf[self.pos])) {
            self.pos += 1;
        }
        return self.buf[start..self.pos];
    }
};

fn emitSubToken(seg: []const u8, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    if (seg.len < 2) return;
    const lower = try arena.alloc(u8, seg.len);
    for (seg, 0..) |c, j| lower[j] = normalizeChar(c);
    try out.append(arena, lower);
}

/// Split an identifier into lowercased sub-tokens.
/// Handles: snake_case, camelCase, SCREAMING_CASE, HTTPHandler-style acronyms.
/// Appends to `out`; strings are allocated from `arena`.
pub fn splitIdentifier(token: []const u8, out: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    if (token.len < 2) return;

    var start: usize = 0;
    var i: usize = 1;
    while (i < token.len) : (i += 1) {
        const c = token[i];
        const prev = token[i - 1];
        var split = false;

        if (c == '_') {
            try emitSubToken(token[start..i], out, arena);
            start = i + 1;
            continue;
        }
        if (prev == '_') continue;

        // CamelCase: lowercase → uppercase boundary
        if (c >= 'A' and c <= 'Z' and prev >= 'a' and prev <= 'z') split = true;

        // Digit/letter transition
        if (!split) {
            const c_d = c >= '0' and c <= '9';
            const p_d = prev >= '0' and prev <= '9';
            if (c_d != p_d) split = true;
        }

        // Acronym end: HTTPHandler → HTTP|Handler
        if (!split and c >= 'A' and c <= 'Z' and prev >= 'A' and prev <= 'Z') {
            if (i + 1 < token.len and token[i + 1] >= 'a' and token[i + 1] <= 'z') split = true;
        }

        if (split) {
            try emitSubToken(token[start..i], out, arena);
            start = i;
        }
    }
    try emitSubToken(token[start..token.len], out, arena);
}
