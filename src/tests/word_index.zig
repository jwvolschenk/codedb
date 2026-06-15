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

test "word index: index and search" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("src/foo.zig", "pub fn hello() void {\n    const x = 42;\n}\n");

    const hits = wi.search("hello");
    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings("src/foo.zig", wi.hitPath(hits[0]));
    try testing.expect(hits[0].line_num == 1);

    // "x" is only 1 char, should be skipped
    const x_hits = wi.search("x");
    try testing.expect(x_hits.len == 0);

    // "const" should be found
    const const_hits = wi.search("const");
    try testing.expect(const_hits.len > 0);
    try testing.expect(const_hits[0].line_num == 2);
}

test "word index: re-index clears old entries" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("f.zig", "fn old_func() void {}");
    try testing.expect(wi.search("old_func").len > 0);

    try wi.indexFile("f.zig", "fn new_func() void {}");
    try testing.expect(wi.search("old_func").len == 0);
    try testing.expect(wi.search("new_func").len > 0);
}

test "word index: removeFile" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("a.zig", "fn hello() void {}");
    try testing.expect(wi.search("hello").len > 0);

    wi.removeFile("a.zig");
    try testing.expect(wi.search("hello").len == 0);
}

test "word index: deduped search" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    // "hello" appears twice on the same line — should dedup
    try wi.indexFile("f.zig", "hello hello world");

    const hits = try wi.searchDeduped("hello", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 1);
}

// ── Trigram index tests ─────────────────────────────────────

test "word index: removeFile prunes empty buckets" {
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    try wi.indexFile("a.zig", "uniqueWordOnlyHere anotherUnique");
    // Words should exist
    try testing.expect(wi.search("uniqueWordOnlyHere").len > 0);

    wi.removeFile("a.zig");
    // After removal, buckets should be pruned (not just emptied)
    try testing.expect(wi.search("uniqueWordOnlyHere").len == 0);
}

test "disk word index: round-trip write and read preserves hits" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();

    try wi.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");
    try wi.indexFile("src/store.zig", "pub const Store = struct {};\npub fn open() void {}\n");

    const hits_before = try wi.searchDeduped("Store", alloc);
    defer alloc.free(hits_before);
    try testing.expectEqual(@as(usize, 2), hits_before.len);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "0123456789abcdef0123456789abcdef01234567".*;
    try wi.writeToDisk(io, dir_path, fake_head);

    const header = try WordIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u32, 2), header.?.file_count);
    try testing.expect(header.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &header.?.git_head.?);

    const loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_wi = loaded.?;
    defer loaded_wi.deinit();

    const hits_after = try loaded_wi.searchDeduped("Store", alloc);
    defer alloc.free(hits_after);
    try testing.expectEqual(hits_before.len, hits_after.len);

    var found_main = false;
    var found_store = false;
    for (hits_after) |hit| {
        if (std.mem.eql(u8, loaded_wi.hitPath(hit), "src/main.zig")) found_main = true;
        if (std.mem.eql(u8, loaded_wi.hitPath(hit), "src/store.zig")) found_store = true;
    }
    try testing.expect(found_main);
    try testing.expect(found_store);
}

test "disk word index: skip_file_words still writes file table" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();
    wi.skip_file_words = true;

    try wi.indexFile("src/a.zig", "pub fn alphaToken() void {}\n");
    try wi.indexFile("src/b.zig", "pub fn betaToken() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try wi.writeToDisk(io, dir_path, null);

    const header = try WordIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(header != null);
    try testing.expectEqual(@as(u32, 2), header.?.file_count);

    const loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_wi = loaded.?;
    defer loaded_wi.deinit();

    const hits = try loaded_wi.searchDeduped("alphaToken", alloc);
    defer alloc.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/a.zig", loaded_wi.hitPath(hits[0]));
}

test "issue-220: partial word index state rebuilds before search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();
    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try exp.indexFile("src/b.zig", "pub const Beta = 2;\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/partial.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator));
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    try exp2.indexFileSkipTrigram("src/b.zig", "pub const Gamma = 3;\n");
    try testing.expect(!exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());

    const alpha_hits = try exp2.searchWord("Alpha", testing.allocator);
    defer testing.allocator.free(alpha_hits);
    try testing.expectEqual(@as(usize, 1), alpha_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(alpha_hits[0]), "src/a.zig"));

    const gamma_hits = try exp2.searchWord("Gamma", testing.allocator);
    defer testing.allocator.free(gamma_hits);
    try testing.expectEqual(@as(usize, 1), gamma_hits.len);
    try testing.expect(std.mem.eql(u8, exp2.word_index.hitPath(gamma_hits[0]), "src/b.zig"));
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}

test "issue-220: word index persistence tracking skips redundant rewrites" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("src/a.zig", "pub const Alpha = 1;\n");
    try testing.expect(exp.wordIndexIsComplete());
    try testing.expect(exp.wordIndexNeedsPersist());

    const first_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
    try testing.expect(exp.wordIndexGenerationToPersist() == null);

    try exp.indexFile("src/a.zig", "pub const Beta = 2;\n");
    try testing.expect(exp.wordIndexNeedsPersist());

    const second_gen = exp.wordIndexGenerationToPersist() orelse return error.TestUnexpectedResult;
    try testing.expect(second_gen != first_gen);
    exp.markWordIndexPersisted(first_gen);
    try testing.expect(exp.wordIndexNeedsPersist());
    exp.markWordIndexPersisted(second_gen);
    try testing.expect(!exp.wordIndexNeedsPersist());
}

// ── Snapshot non-git tests ───────────────────────────────────

test "regression-142: word index still works alongside trigram" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("words.zig", "pub fn mySpecialFunction() void {}");

    const hits = try exp.searchWord("mySpecialFunction", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 1);
}

test "issue-363a: searchContent surfaces source-file matches even when doc files dominate the word index" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // To hit Tier 0 of searchContent (explore.zig:1511-1535) the gate
    // `word_hits.len <= max_results * 2` must hold. We pick small numbers:
    // 4 docs × 4 mentions = 16 hits, then 2 source-file hits = 18 total, with
    // max_results=10 → 18 ≤ 20 ✓ → Tier 0 runs.
    var path_buf: [64]u8 = undefined;
    var content_buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        const content = try std.fmt.bufPrint(
            &content_buf,
            "## Notes {d}\n\n" ++
                "The searchContent function is documented here.\n" ++
                "We discuss searchContent at length.\n" ++
                "Note that searchContent is multi-tier.\n" ++
                "Performance: searchContent is fast.\n",
            .{i},
        );
        try explorer.indexFile(path, content);
    }

    // Index the source file LAST so its word-index hits land at the END of
    // the posting list. Pre-fix, Tier 0 fills the result_list with doc hits
    // and returns before reaching source-file hits.
    try explorer.indexFile(
        "src/explore.zig",
        "pub fn searchContent(self: *Explorer, query: []const u8) !void {\n" ++
            "    // searchContent is the multi-tier text search entrypoint.\n" ++
            "    _ = self;\n" ++
            "    _ = query;\n" ++
            "}\n",
    );

    const results = try explorer.searchContent("searchContent", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/explore.zig")) {
            found_source = true;
            break;
        }
    }
    // The source file MUST appear — it's the canonical match for the
    // identifier. Pre-fix, doc-file hits saturated the 10-result quota in
    // Tier 0 and src/explore.zig was dropped.
    try testing.expect(found_source);
}

test "issue-400-bug1: searchContentRanked returns ranked results when skip_file_words=true" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.word_index.skip_file_words = true;
    try explorer.indexFile("a.zig", "apple banana\n");
    try explorer.indexFile("b.zig", "apple\n");
    const results = try explorer.searchContentRanked("apple", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
}

test "issue-400-bug2: total_tokens stays consistent across re-index when skip_file_words=true" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.word_index.skip_file_words = true;
    try explorer.indexFile("a.zig", "one two three four\n");
    try explorer.indexFile("a.zig", "five six seven\n");
    try explorer.indexFile("a.zig", "eight\n");
    try testing.expectEqual(@as(u64, 1), explorer.word_index.total_tokens);
}

// ---------------------------------------------------------------------------
// BM25 stress / recall regression tests (#421 stress-421 branch)
// ---------------------------------------------------------------------------
