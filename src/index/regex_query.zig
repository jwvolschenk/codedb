// Regex decomposition into required-trigram queries.
const std = @import("std");
const normalizeChar = @import("chars.zig").normalizeChar;
const tg_posting = @import("trigram_posting.zig");
const Trigram = tg_posting.Trigram;
const packTrigram = tg_posting.packTrigram;

pub const RegexQuery = struct {
    and_trigrams: []Trigram,
    or_groups: [][]Trigram,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RegexQuery) void {
        self.allocator.free(self.and_trigrams);
        for (self.or_groups) |group| {
            self.allocator.free(group);
        }
        self.allocator.free(self.or_groups);
    }
};

/// Parse a regex pattern and extract literal segments that yield trigrams.
/// Handles: . \s \w \d * + ? | [...] \ (escapes)
/// Literal runs >= 3 chars produce AND trigrams.
/// Alternations (foo|bar) produce OR groups.
pub fn decomposeRegex(pattern: []const u8, allocator: std.mem.Allocator) !RegexQuery {
    // First check if this is an alternation at the top level
    // We need to respect grouping: only split on | outside of [...] and (...)
    var top_pipes: std.ArrayList(usize) = .empty;
    defer top_pipes.deinit(allocator);

    {
        var depth: usize = 0;
        var in_bracket = false;
        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];
            if (c == '\\' and i + 1 < pattern.len) {
                i += 2;
                continue;
            }
            if (c == '[') {
                in_bracket = true;
                i += 1;
                continue;
            }
            if (c == ']') {
                in_bracket = false;
                i += 1;
                continue;
            }
            if (in_bracket) {
                i += 1;
                continue;
            }
            if (c == '(') {
                depth += 1;
                i += 1;
                continue;
            }
            if (c == ')') {
                if (depth > 0) depth -= 1;
                i += 1;
                continue;
            }
            if (c == '|' and depth == 0) {
                try top_pipes.append(allocator, i);
            }
            i += 1;
        }
    }

    if (top_pipes.items.len > 0) {
        // Top-level alternation: merge all branch trigrams into a single OR group.
        // A file matching ANY branch's trigrams is a valid candidate.
        var all_tris: std.ArrayList(Trigram) = .empty;
        errdefer all_tris.deinit(allocator);

        var start: usize = 0;
        for (top_pipes.items) |pipe_pos| {
            const branch = pattern[start..pipe_pos];
            const branch_tris = try extractLiteralTrigrams(branch, allocator);
            defer allocator.free(branch_tris);
            for (branch_tris) |tri| {
                try all_tris.append(allocator, tri);
            }
            start = pipe_pos + 1;
        }
        // Last branch
        const last_branch = pattern[start..];
        const last_tris = try extractLiteralTrigrams(last_branch, allocator);
        defer allocator.free(last_tris);
        for (last_tris) |tri| {
            try all_tris.append(allocator, tri);
        }

        const empty_and = try allocator.alloc(Trigram, 0);
        var or_groups: std.ArrayList([]Trigram) = .empty;
        errdefer or_groups.deinit(allocator);
        if (all_tris.items.len > 0) {
            try or_groups.append(allocator, try all_tris.toOwnedSlice(allocator));
        }
        return RegexQuery{
            .and_trigrams = empty_and,
            .or_groups = try or_groups.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    // No top-level alternation: extract trigrams from literal segments
    const and_tris = try extractLiteralTrigrams(pattern, allocator);
    const empty_or = try allocator.alloc([]Trigram, 0);
    return RegexQuery{
        .and_trigrams = and_tris,
        .or_groups = empty_or,
        .allocator = allocator,
    };
}

/// Extract trigrams from literal runs in a regex fragment (no top-level |).
fn extractLiteralTrigrams(pattern: []const u8, allocator: std.mem.Allocator) ![]Trigram {
    var literals: std.ArrayList(u8) = .empty;
    defer literals.deinit(allocator);

    var trigrams_list: std.ArrayList(Trigram) = .empty;
    errdefer trigrams_list.deinit(allocator);

    // Deduplicate trigrams
    var seen = std.AutoHashMap(Trigram, void).init(allocator);
    defer seen.deinit();

    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];

        // Escape sequences
        if (c == '\\' and i + 1 < pattern.len) {
            const next = pattern[i + 1];
            switch (next) {
                's', 'S', 'w', 'W', 'd', 'D', 'b', 'B' => {
                    // Character class — breaks literal chain
                    try flushLiterals(allocator, &literals, &trigrams_list, &seen);
                    i += 2;
                    // If followed by quantifier, skip it too
                    if (i < pattern.len and isQuantifier(pattern[i])) i += 1;
                    continue;
                },
                else => {
                    // Escaped literal char (e.g. \. \( \) \\ etc.)
                    try literals.append(allocator, next);
                    i += 2;
                    // Check for quantifier after escaped char
                    if (i < pattern.len and isQuantifier(pattern[i])) {
                        // Quantifier on single char — pop it and flush
                        if (literals.items.len > 0) {
                            _ = literals.pop();
                        }
                        try flushLiterals(allocator, &literals, &trigrams_list, &seen);
                        i += 1;
                    }
                    continue;
                },
            }
        }

        // Character class [...]
        if (c == '[') {
            try flushLiterals(allocator, &literals, &trigrams_list, &seen);
            // Skip to closing ]
            i += 1;
            if (i < pattern.len and pattern[i] == '^') i += 1;
            if (i < pattern.len and pattern[i] == ']') i += 1; // literal ] at start
            while (i < pattern.len and pattern[i] != ']') : (i += 1) {}
            if (i < pattern.len) i += 1; // skip ]
            // Skip quantifier after class
            if (i < pattern.len and isQuantifier(pattern[i])) i += 1;
            continue;
        }

        // Grouping parens — just skip them, process contents
        if (c == '(' or c == ')') {
            try flushLiterals(allocator, &literals, &trigrams_list, &seen);
            i += 1;
            continue;
        }

        // Anchors
        if (c == '^' or c == '$') {
            try flushLiterals(allocator, &literals, &trigrams_list, &seen);
            i += 1;
            continue;
        }

        // Dot — any char, breaks chain
        if (c == '.') {
            try flushLiterals(allocator, &literals, &trigrams_list, &seen);
            i += 1;
            if (i < pattern.len and isQuantifier(pattern[i])) i += 1;
            continue;
        }

        // Quantifiers on previous char
        if (isQuantifier(c)) {
            // Remove last literal (it's now optional/repeated)
            if (literals.items.len > 0) {
                _ = literals.pop();
            }
            try flushLiterals(allocator, &literals, &trigrams_list, &seen);
            // If it's a brace quantifier {n}, {n,m}, {n,}, skip to closing }
            if (c == '{') {
                i += 1;
                while (i < pattern.len and pattern[i] != '}') : (i += 1) {}
                if (i < pattern.len) i += 1; // skip '}'
            } else {
                i += 1;
            }
            continue;
        }

        // Plain literal character
        try literals.append(allocator, c);
        i += 1;
    }

    // Flush remaining literals
    try flushLiterals(allocator, &literals, &trigrams_list, &seen);

    return trigrams_list.toOwnedSlice(allocator);
}

fn isQuantifier(c: u8) bool {
    return c == '*' or c == '+' or c == '?' or c == '{';
}

/// Flush a run of literal characters into trigrams (if >= 3 chars).
fn flushLiterals(
    allocator: std.mem.Allocator,
    literals: *std.ArrayList(u8),
    trigrams_list: *std.ArrayList(Trigram),
    seen: *std.AutoHashMap(Trigram, void),
) !void {
    if (literals.items.len >= 3) {
        for (0..literals.items.len - 2) |j| {
            const tri = packTrigram(
                normalizeChar(literals.items[j]),
                normalizeChar(literals.items[j + 1]),
                normalizeChar(literals.items[j + 2]),
            );
            const gop = try seen.getOrPut(tri);
            if (!gop.found_existing) {
                try trigrams_list.append(allocator, tri);
            }
        }
    }
    literals.clearRetainingCapacity();
}
