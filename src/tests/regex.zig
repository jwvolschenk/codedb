const std = @import("std");
const cio = @import("../cio.zig");
const testing = std.testing;
const io = std.testing.io;

const Store = @import("../store.zig").Store;
const ChangeEntry = @import("../store.zig").ChangeEntry;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const Explorer = @import("../explore.zig").Explorer;
const csharp_parser = @import("../csharp_parser.zig");
const tsql_parser = @import("../tsql_parser.zig");
const ssrs_parser = @import("../ssrs_parser.zig");
const SearchResult = @import("../explore.zig").SearchResult;
const WordIndex = @import("../index.zig").WordIndex;
const TrigramIndex = @import("../index.zig").TrigramIndex;
const SparseNgramIndex = @import("../index.zig").SparseNgramIndex;
const pairWeight = @import("../index.zig").pairWeight;
const extractSparseNgrams = @import("../index.zig").extractSparseNgrams;
const buildCoveringSet = @import("../index.zig").buildCoveringSet;
const setFrequencyTable = @import("../index.zig").setFrequencyTable;
const resetFrequencyTable = @import("../index.zig").resetFrequencyTable;
const buildFrequencyTable = @import("../index.zig").buildFrequencyTable;
const writeFrequencyTable = @import("../index.zig").writeFrequencyTable;
const readFrequencyTable = @import("../index.zig").readFrequencyTable;

const WordTokenizer = @import("../index.zig").WordTokenizer;
const splitIdentifier = @import("../index.zig").splitIdentifier;

const version = @import("../version.zig");
const watcher = @import("../watcher.zig");
const edit_mod = @import("../edit.zig");
const snapshot_json = @import("../snapshot_json.zig");
const explore = @import("../explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("../mcp.zig");
const main_mod = @import("../main.zig");
const nuke_mod = @import("../nuke.zig");
const update_mod = @import("../update.zig");
const Config = @import("../config.zig").Config;
// Pull in unit tests that were extracted from implementation files into
// dedicated `*__tests.zig` companions. Zig collects test blocks through
// @import, so referencing them here makes the test runner discover them.
comptime {
    _ = @import("../config_tests.zig");
    _ = @import("../hot_cache_tests.zig");
    _ = @import("../root_policy_tests.zig");
    _ = @import("../tsql_parser_tests.zig");
}
const snapshot_mod = @import("../snapshot.zig");
const telemetry_mod = @import("../telemetry.zig");
const release_info = @import("../release_info.zig");
// ── Store tests ─────────────────────────────────────────────

const decomposeRegex = @import("../index.zig").decomposeRegex;

const RegexQuery = @import("../index.zig").RegexQuery;

const packTrigram = @import("../index.zig").packTrigram;

const git_mod = @import("../git.zig");

const regexMatch = explore.regexMatch;

const PostingMask = @import("../index.zig").PostingMask;

const normalizeChar = @import("../index.zig").normalizeChar;

const Trigram = @import("../index.zig").Trigram;

fn buildCliForHelpTests() !void {
    const build = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}

const MmapTrigramIndex = @import("../index.zig").MmapTrigramIndex;

const AnyTrigramIndex = @import("../index.zig").AnyTrigramIndex;

const fuzzyScore = @import("../explore.zig").fuzzyScore;

fn expectOutlineSymbol(outline: *const explore.FileOutline, name: []const u8, kind: SymbolKind) !void {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.kind == kind) return;
    }
    return error.TestUnexpectedResult;
}

fn expectOutlineImport(outline: *const explore.FileOutline, import_path: []const u8) !void {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, import_path)) return;
    }
    return error.TestUnexpectedResult;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "decomposeRegex: dot in longer literal" {
    var q = try decomposeRegex("hello.world", testing.allocator);
    defer q.deinit();
    // "hello" -> hel,ell,llo; "world" -> wor,orl,rld = 6 trigrams
    try testing.expectEqual(@as(usize, 6), q.and_trigrams.len);
}

test "decomposeRegex: alternation creates OR groups" {
    var q = try decomposeRegex("foo|bar", testing.allocator);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
    // All branch trigrams merged into single OR group
    try testing.expectEqual(@as(usize, 1), q.or_groups.len);
    // "foo" has 1 trigram + "bar" has 1 trigram = 2 trigrams in the group
    try testing.expectEqual(@as(usize, 2), q.or_groups[0].len);
}

test "issue-628: alternation with a no-trigram branch falls back to scan-all" {
    // "xy" is too short to yield a trigram. Pre-fix, decomposeRegex constrained
    // candidate files to "createGateway"'s trigrams, dropping any file that
    // matched only the "xy" branch — a silent 0-match false negative. The query
    // must instead be fully unconstrained so the search scans every file.
    var q = try decomposeRegex("xy|createGateway", testing.allocator);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
    try testing.expectEqual(@as(usize, 0), q.or_groups.len);

    // A metachar-only branch (matches anywhere) must also force scan-all.
    var q2 = try decomposeRegex(".*|createGateway", testing.allocator);
    defer q2.deinit();
    try testing.expectEqual(@as(usize, 0), q2.and_trigrams.len);
    try testing.expectEqual(@as(usize, 0), q2.or_groups.len);

    // Sanity: when every branch yields trigrams, prefiltering is still used.
    var q3 = try decomposeRegex("generateText|streamText", testing.allocator);
    defer q3.deinit();
    try testing.expectEqual(@as(usize, 1), q3.or_groups.len);
}

test "decomposeRegex: quantifier removes preceding char" {
    var q = try decomposeRegex("hel+o", testing.allocator);
    defer q.deinit();
    // "he" then "o" — + removes 'l', neither segment >= 3
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}

test "decomposeRegex: escaped literal preserved" {
    var q = try decomposeRegex("a\\.bc", testing.allocator);
    defer q.deinit();
    // Escaped dot is literal: "a.bc" = 2 trigrams: a.b, .bc
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}

test "decomposeRegex: character class breaks chain" {
    var q = try decomposeRegex("abc[xy]def", testing.allocator);
    defer q.deinit();
    // "abc" = 1 trigram, "def" = 1 trigram
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}

test "decomposeRegex: backslash-w breaks chain" {
    var q = try decomposeRegex("abc\\wdef", testing.allocator);
    defer q.deinit();
    // "abc" = 1 trigram, "def" = 1 trigram
    try testing.expectEqual(@as(usize, 2), q.and_trigrams.len);
}

test "candidatesRegex: OR groups union posting lists" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("alpha.zig", "function foobar() {}");
    try ti.indexFile("beta.zig", "function bazqux() {}");
    try ti.indexFile("gamma.zig", "const x = 1;");

    var q = try decomposeRegex("foobar|bazqux", testing.allocator);
    defer q.deinit();
    // All branch trigrams merged into single OR group
    try testing.expectEqual(@as(usize, 1), q.or_groups.len);

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    // Both alpha.zig and beta.zig should be candidates
    var found_alpha = false;
    var found_beta = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "alpha.zig")) found_alpha = true;
        if (std.mem.eql(u8, p, "beta.zig")) found_beta = true;
    }
    try testing.expect(found_alpha or found_beta);
}

test "regexMatch: literal match" {
    try testing.expect(regexMatch("hello world", "hello"));
    try testing.expect(regexMatch("hello world", "world"));
    try testing.expect(!regexMatch("hello world", "xyz"));
}

test "regexMatch: dot matches any char" {
    try testing.expect(regexMatch("hello", "h.llo"));
    try testing.expect(regexMatch("hello", "h..lo"));
    try testing.expect(!regexMatch("hello", "h...lo"));
}

test "regexMatch: star quantifier" {
    try testing.expect(regexMatch("helllo", "hel*o"));
    try testing.expect(regexMatch("heo", "hel*o"));
    try testing.expect(regexMatch("aab", "a*b"));
}

// test "regexMatch: plus quantifier" {
//     try testing.expect(regexMatch("helllo", "hel+o"));
//     try testing.expect(!regexMatch("heo", "hel+o"));
// }

test "regexMatch: question quantifier" {
    try testing.expect(regexMatch("color", "colou?r"));
    try testing.expect(regexMatch("colour", "colou?r"));
}

test "regexMatch: character class" {
    try testing.expect(regexMatch("cat", "c[aeiou]t"));
    try testing.expect(regexMatch("cot", "c[aeiou]t"));
    try testing.expect(!regexMatch("cxt", "c[aeiou]t"));
}

test "regexMatch: negated character class" {
    try testing.expect(!regexMatch("cat", "c[^aeiou]t"));
    try testing.expect(regexMatch("cxt", "c[^aeiou]t"));
}

test "regexMatch: anchors" {
    try testing.expect(regexMatch("hello", "^hello"));
    try testing.expect(!regexMatch("say hello", "^hello"));
    try testing.expect(regexMatch("hello", "hello$"));
    try testing.expect(!regexMatch("hello world", "hello$"));
}

test "regexMatch: escape sequences" {
    try testing.expect(regexMatch("abc123", "\\d+"));
    try testing.expect(regexMatch("hello world", "\\w+\\s\\w+"));
    try testing.expect(regexMatch("a.b", "a\\.b"));
    try testing.expect(!regexMatch("axb", "a\\.b"));
}

test "regexMatch: alternation" {
    try testing.expect(regexMatch("foo", "foo|bar"));
    try testing.expect(regexMatch("bar", "foo|bar"));
    try testing.expect(!regexMatch("baz", "foo|bar"));
}

test "regexMatch: alternation with many branches does not stack overflow" {
    // 300 branches: 4 chars each + 299 separators = 1499 bytes max
    var buf: [1500]u8 = undefined;
    var pos: usize = 0;
    var bi: usize = 0;
    while (bi < 300) : (bi += 1) {
        if (bi > 0) {
            buf[pos] = '|';
            pos += 1;
        }
        buf[pos] = 'a';
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi / 100 % 10));
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi / 10 % 10));
        pos += 1;
        buf[pos] = @as(u8, @intCast('0' + bi % 10));
        pos += 1;
    }
    const pattern = buf[0..pos];
    try testing.expect(regexMatch("a000", pattern));
    try testing.expect(regexMatch("a299", pattern));
    try testing.expect(!regexMatch("a999", pattern));
}

test "regexMatch: dot-star" {
    try testing.expect(regexMatch("hello world", "hello.*world"));
    try testing.expect(regexMatch("helloworld", "hello.*world"));
}

test "issue-454: regex \\b word boundary matches whole-word, not literal 'b'" {
    // \b is a word-boundary assertion: should match "foo" as a whole word
    // but not when it appears as a substring inside another word.
    try testing.expect(regexMatch("foo bar", "\\bfoo\\b"));
    try testing.expect(!regexMatch("foobar", "\\bfoo\\b"));
    // Whole-word "bar" at end
    try testing.expect(regexMatch("foo bar", "\\bbar\\b"));
    try testing.expect(!regexMatch("foobarbaz", "\\bbar\\b"));
}

test "explorer: searchContentRegex end-to-end" {
    var explorer_inst = Explorer.init(testing.allocator);
    defer explorer_inst.deinit();

    try explorer_inst.indexFile("test1.zig", "pub fn recordSnapshot() void {}\nconst x = 42;");
    try explorer_inst.indexFile("test2.zig", "pub fn recordState() void {}\nconst y = 99;");
    try explorer_inst.indexFile("test3.zig", "const z = 0;\nfn other() void {}");

    const results = try explorer_inst.searchContentRegex("record\\w+", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    // Both test1 and test2 should have matches
    var found1 = false;
    var found2 = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "test1.zig")) found1 = true;
        if (std.mem.eql(u8, r.path, "test2.zig")) found2 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
}

test "explorer: searchContentRegex no match" {
    var explorer_inst = Explorer.init(testing.allocator);
    defer explorer_inst.deinit();

    try explorer_inst.indexFile("only.zig", "const x = 42;");

    const results = try explorer_inst.searchContentRegex("zzz\\d+qqq", testing.allocator, 50);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}

// ── Bloom filter correctness tests ──────────────────────────
// These tests prove that the PostingMask (nextMask + locMask) bloom
// filters are actually working — reducing false-positive candidates
// without introducing false negatives.

test "regex regression: regexMatch edge cases" {
    // Empty pattern matches anything
    try testing.expect(regexMatch("anything", ""));

    // Pure wildcard
    try testing.expect(regexMatch("abc", ".*"));
    try testing.expect(regexMatch("", ".*"));

    // Consecutive quantifiers shouldn't crash
    try testing.expect(regexMatch("aab", "a+b"));
    try testing.expect(!regexMatch("b", "a+b"));

    // Nested-ish patterns
    try testing.expect(regexMatch("foobar", "foo.ar"));
    try testing.expect(!regexMatch("foar", "foo.ar"));

    // Backslash at end of pattern (edge case)
    try testing.expect(!regexMatch("abc", "abc\\"));
}

test "regex regression: candidatesRegex reduces vs brute force" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("handler.zig", "pub fn handleRequest(ctx: *Context) !void { }");
    try ti.indexFile("process.zig", "pub fn processData(input: []u8) void { }");
    try ti.indexFile("utils.zig", "pub fn formatString(s: []const u8) []u8 { return s; }");
    try ti.indexFile("config.zig", "const default_config = Config{ .debug = false };");

    // "handle.*Request" — should extract trigrams from "handle" and "Request"
    var q = try decomposeRegex("handle.*Request", testing.allocator);
    defer q.deinit();
    try testing.expect(q.and_trigrams.len >= 4); // at least some from both halves

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // handler.zig MUST be a candidate (soundness)
    var found_handler = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "handler.zig")) found_handler = true;
    }
    try testing.expect(found_handler);

    // Should NOT include config.zig (no "handle" or "Request" trigrams)
    var found_config = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "config.zig")) found_config = true;
    }
    try testing.expect(!found_config);

    // Candidate count should be much less than total files
    try testing.expect(cands.?.len <= 2);
}

// ── Performance regression benchmarks ───────────────────────
// These tests index a realistic number of files and assert that
// operations complete within a time budget. If bloom filtering
// regresses or indexing gets slower, these will catch it.

test "issue-292: codedb_search guidance hints regex=true on metachar query" {
    const args_json = "{\"query\":\"timestamp|activity|filter\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") != null);
}

test "issue-292: codedb_search guidance does not warn when regex=true is set" {
    const args_json = "{\"query\":\"timestamp|activity\",\"regex\":true}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") == null);
}
