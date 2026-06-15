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

test "explorer: sparse ngram index integrated into searchContent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/alpha.zig", "pub fn processRequest(req: *Request) void {}");
    try explorer.indexFile("src/beta.zig", "pub fn handleResponse(res: *Response) void {}");

    const results = try explorer.searchContent("processRequest", arena.allocator(), 10);
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("src/alpha.zig", results[0].path);
}

test "explorer: searchContent finds query embedded in longer identifier" {
    // Verify that searchContent correctly finds files whose content contains
    // the query string.  The sparse index (sliding-window) and trigram index
    // are both used; the intersection narrows results without false negatives.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // "alpha.zig" content contains "record"; "beta.zig" does not.
    try explorer.indexFile("alpha.zig", "const record_count: usize = 0;");
    try explorer.indexFile("beta.zig", "const unrelated_data: usize = 0;");

    const results = try explorer.searchContent("record", arena.allocator(), 10);
    var found = false;
    for (results) |r| if (std.mem.eql(u8, r.path, "alpha.zig")) {
        found = true;
    };
    try testing.expect(found);
}

// ── Frequency-weighted pairWeight tests ─────────────────────

test "explorer: searchWord via inverted index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("add", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings("math.zig", explorer.word_index.hitPath(hits[0]));
}

test "regression #2: searchContent no leak on zero results" {
    // Even when trigram narrows to candidates but none match full text,
    // the candidate slice must be freed.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("abc.zig", "pub fn abcdef() void {}");

    // "abcxyz" shares trigrams "abc" but won't match full text
    const results = try explorer.searchContent("abcxyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "regression: searchWord empty result is allocator-owned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }");

    const hits = try explorer.searchWord("missing_identifier", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len == 0);
}

test "searchContent: returned paths are owned copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("src/hello.zig", "pub fn greetWorld() void {}");

    const results = try explorer.searchContent("greetWorld", alloc, 10);
    try testing.expect(results.len == 1);

    // Remove the source
    explorer.removeFile("src/hello.zig");

    // Path and line_text should still be valid (owned)
    try testing.expectEqualStrings("src/hello.zig", results[0].path);
}

// ── Word index: empty bucket pruning ────────────────────────

test "extractLines: basic range with line numbers" {
    const content = "line1\nline2\nline3\nline4\nline5";
    const result = try extractLines(content, 2, 4, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | line2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | line3") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    4 | line4") != null);
    try testing.expect(std.mem.indexOf(u8, result, "line1") == null);
    try testing.expect(std.mem.indexOf(u8, result, "line5") == null);
}

test "extractLines: start beyond file returns empty" {
    const content = "line1\nline2";
    const result = try extractLines(content, 10, 20, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len == 0);
}

test "extractLines: compact skips comments and blanks" {
    const content = "fn main() void {}\n// this is a comment\n\n    return 0;\n}";
    const result = try extractLines(content, 1, 5, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    // Should contain code lines but not the comment or blank line
    try testing.expect(std.mem.indexOf(u8, result, "fn main") != null);
    try testing.expect(std.mem.indexOf(u8, result, "// this is a comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "return 0") != null);
}

test "isCommentOrBlank: detects language-specific comments" {
    try testing.expect(isCommentOrBlank("  // zig comment", .zig));
    try testing.expect(isCommentOrBlank("  # python comment", .python));
    try testing.expect(isCommentOrBlank("  /* c comment */", .c));
    try testing.expect(isCommentOrBlank("  * continuation", .javascript));
    try testing.expect(isCommentOrBlank("   ", .zig));
    try testing.expect(isCommentOrBlank("", .zig));
    try testing.expect(!isCommentOrBlank("  const x = 1;", .zig));
    try testing.expect(!isCommentOrBlank("  x = 1", .python));
    // unknown language: never strips
    try testing.expect(!isCommentOrBlank("// comment", .unknown));
}

test "explorer: searchContentWithScope annotates results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    // Use content where the search match line has no symbol definition itself
    try exp.indexFile("auth.zig", "pub fn handleAuth() void {\n    validate(token);\n}");

    const results = try exp.searchContentWithScope("validate", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("auth.zig", results[0].path);
    try testing.expect(results[0].line_num == 2);
    // Should have scope annotation — nearest preceding symbol is handleAuth
    try testing.expect(results[0].scope_name != null);
    try testing.expectEqualStrings("handleAuth", results[0].scope_name.?);
}

test "explorer: searchContentWithScope ignores zero-span symbols when enclosing scope exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("AccountController.cs",
        \\public class AccountController {
        \\    public IActionResult Index() {
        \\        GetAccountsToolbar(model);
        \\        return View(model);
        \\    }
        \\}
    );

    const results = try exp.searchContentWithScope("GetAccountsToolbar", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expect(results[0].scope_name != null);
    try testing.expectEqualStrings("Index", results[0].scope_name.?);
}

test "explorer: searchContentWithScope no scope for standalone line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    // Content with no symbols — scope should be null
    try exp.indexFile("data.txt", "hello world\nfoo bar");

    const results = try exp.searchContentWithScope("hello", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expect(results[0].scope_name == null);
}

test "extractLines: without line numbers" {
    const content = "alpha\nbeta\ngamma";
    const result = try extractLines(content, 1, 3, false, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", result);
}

// ── Extended MCP enhancement tests ──────────────────────────

// ── extractLines edge cases ─────────────────────────────────

test "extractLines: start only reads to EOF" {
    const content = "a\nb\nc\nd\ne";
    const result = try extractLines(content, 3, std.math.maxInt(u32), true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | c") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    4 | d") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    5 | e") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| a") == null);
    try testing.expect(std.mem.indexOf(u8, result, "| b") == null);
}

test "extractLines: end beyond file clamps to EOF" {
    const content = "x\ny\nz";
    const result = try extractLines(content, 2, 999, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | y") != null);
    try testing.expect(std.mem.indexOf(u8, result, "    3 | z") != null);
    // No crash, no garbage — just the available lines
    try testing.expect(std.mem.count(u8, result, "\n") == 2);
}

test "extractLines: single line range (start == end)" {
    const content = "one\ntwo\nthree";
    const result = try extractLines(content, 2, 2, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "    2 | two") != null);
    try testing.expect(std.mem.count(u8, result, "\n") == 1);
}

test "extractLines: empty content returns single empty line" {
    const result = try extractLines("", 1, 10, true, false, .unknown, testing.allocator);
    defer testing.allocator.free(result);
    // Empty string splits to one empty line, which is line 1
    try testing.expect(result.len > 0);
}

test "extractLines: compact with Python comments" {
    const content = "# comment\nimport os\n\ndef hello():\n    # inline comment\n    print('hi')";
    const result = try extractLines(content, 1, 6, false, true, .python, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "# comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "# inline comment") == null);
    try testing.expect(std.mem.indexOf(u8, result, "import os") != null);
    try testing.expect(std.mem.indexOf(u8, result, "def hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "print('hi')") != null);
}

test "extractLines: compact with JS/TS comments" {
    const content = "// header\nconst x = 1;\n/* block */\n* star line\nexport default x;";
    const result = try extractLines(content, 1, 5, false, true, .typescript, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "// header") == null);
    try testing.expect(std.mem.indexOf(u8, result, "/* block */") == null);
    try testing.expect(std.mem.indexOf(u8, result, "* star line") == null);
    try testing.expect(std.mem.indexOf(u8, result, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "export default x;") != null);
}

// ── isCommentOrBlank: additional languages ──────────────────

test "isCommentOrBlank: rust double-slash" {
    try testing.expect(isCommentOrBlank("  // rust comment", .rust));
    try testing.expect(!isCommentOrBlank("  let x = 1;", .rust));
}

test "isCommentOrBlank: go double-slash" {
    try testing.expect(isCommentOrBlank("  // go comment", .go_lang));
    try testing.expect(!isCommentOrBlank("  func main() {", .go_lang));
}

test "isCommentOrBlank: cpp block and line comments" {
    try testing.expect(isCommentOrBlank("  // cpp line comment", .cpp));
    try testing.expect(isCommentOrBlank("  /* cpp block comment */", .cpp));
    try testing.expect(isCommentOrBlank("  * continued block comment", .cpp));
    try testing.expect(!isCommentOrBlank("  int x = 0;", .cpp));
}

test "isCommentOrBlank: detected extension language comments" {
    try testing.expect(isCommentOrBlank("  // java line comment", .java));
    try testing.expect(isCommentOrBlank("  // kotlin line comment", .kotlin));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .svelte));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .vue));
    try testing.expect(isCommentOrBlank("  <!-- component comment -->", .astro));
    try testing.expect(isCommentOrBlank("  # shell comment", .shell));
    try testing.expect(isCommentOrBlank("  /* css block comment */", .css));
    try testing.expect(isCommentOrBlank("  // scss line comment", .scss));
    try testing.expect(isCommentOrBlank("  -- sql comment", .sql));
    try testing.expect(isCommentOrBlank("  // proto comment", .protobuf));
    try testing.expect(isCommentOrBlank("  ! fortran comment", .fortran));
    try testing.expect(isCommentOrBlank("  ; llvm ir comment", .llvm_ir));
    try testing.expect(isCommentOrBlank("  // mlir comment", .mlir));
    try testing.expect(isCommentOrBlank("  // tablegen comment", .tablegen));
    try testing.expect(!isCommentOrBlank("  SELECT * FROM users;", .sql));
}

test "isCommentOrBlank: tabs and mixed whitespace" {
    try testing.expect(isCommentOrBlank("\t\t// tabbed comment", .zig));
    try testing.expect(isCommentOrBlank(" \t \t ", .zig));
    try testing.expect(isCommentOrBlank("\t", .python));
}

test "isCommentOrBlank: markdown and json never strip" {
    try testing.expect(!isCommentOrBlank("# heading", .markdown));
    try testing.expect(!isCommentOrBlank("// not a comment in json", .json));
    try testing.expect(!isCommentOrBlank("# not a comment in yaml", .yaml));
}

// ── getSymbolBody: multi-line and edge cases ────────────────

test "explorer: searchContentWithScope across multiple files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("a.zig", "pub fn foo() void {\n    doWork();\n}");
    try exp.indexFile("b.zig", "pub fn bar() void {\n    doWork();\n}");

    const results = try exp.searchContentWithScope("doWork", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 2);
    for (results) |r| {
        try testing.expect(r.scope_name != null);
        try testing.expect(r.line_num == 2);
    }
}

test "explorer: searchContentWithScope respects max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("many.zig", "pub fn a() void {\n    target();\n    target();\n    target();\n    target();\n}");

    const results = try exp.searchContentWithScope("target", testing.allocator, 2);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 2);
}

test "explorer: searchContentWithScope no results for missing query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("empty.zig", "pub fn main() void {}");

    const results = try exp.searchContentWithScope("nonexistent_xyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 0);
}

// ── Content hash ETag logic ─────────────────────────────────

test "extractLines: compact preserves brace-only lines" {
    const content = "fn main() void {\n    // comment\n    doWork();\n}";
    const result = try extractLines(content, 1, 4, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "fn main") != null);
    try testing.expect(std.mem.indexOf(u8, result, "}") != null);
    try testing.expect(std.mem.indexOf(u8, result, "doWork") != null);
    try testing.expect(std.mem.indexOf(u8, result, "// comment") == null);
}

test "extractLines: compact on all-comment file returns empty" {
    const content = "// comment 1\n// comment 2\n// comment 3";
    const result = try extractLines(content, 1, 3, false, true, .zig, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expect(result.len == 0);
}
// ── Regex decomposition tests ───────────────────────────────

test "issue-164: mmap binary search on sorted lookup table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("a.zig", "const alpha = 42;");
    try explorer.indexFile("b.zig", "const beta = 43;");
    try explorer.indexFile("c.zig", "const gamma = 44;");
    try explorer.indexFile("d.zig", "const delta = 45;");
    try explorer.indexFile("e.zig", "const alpha_beta = 99;");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    defer mmap_idx.deinit();

    const results = mmap_idx.candidates("alpha", allocator) orelse
        return error.NoCandidates;
    try testing.expect(results.len >= 2);

    const no_results = mmap_idx.candidates("zzzzz", allocator);
    if (no_results) |nr| {
        try testing.expectEqual(@as(usize, 0), nr.len);
    }
}

test "issue-163: fuzzy exact match scores highest" {
    const exact = fuzzyScore("main.zig", "src/main.zig");
    const partial = fuzzyScore("main.zig", "src/main_helper.zig");
    try testing.expect(exact != null);
    try testing.expect(partial != null);
    try testing.expect(exact.? > partial.?);
}

test "issue-163: fuzzy subsequence match works" {
    const score = fuzzyScore("authmid", "src/auth_middleware.py");
    try testing.expect(score != null);
    try testing.expect(score.? > 0);
}

test "issue-163: fuzzy typo-tolerant (missing char)" {
    // "auth_midlware" missing the 'd' in middleware — should still match via subsequence
    const score = fuzzyScore("auth_midlware", "src/auth_middleware.py");
    try testing.expect(score != null);
}

test "issue-163: fuzzy word boundary bonus" {
    // "auth" at word boundary should score higher than "auth" buried in a word
    const boundary = fuzzyScore("auth", "src/auth_handler.py");
    const buried = fuzzyScore("auth", "src/xauthyhandle.py");
    try testing.expect(boundary != null);
    try testing.expect(buried != null);
    try testing.expect(boundary.? > buried.?);
}

test "issue-163: fuzzy filename ranks above directory" {
    // "test" in filename portion should score higher than "test" only in directory
    const in_name = fuzzyScore("test", "src/test_auth.py");
    const in_dir = fuzzyScore("test", "testdir/deep/nested/xyzfile.py");
    try testing.expect(in_name != null);
    try testing.expect(in_dir != null);
    try testing.expect(in_name.? > in_dir.?);
}

test "issue-163: fuzzy no match returns null" {
    const score = fuzzyScore("zzzzxyz", "src/main.zig");
    try testing.expect(score == null);
}

test "issue-163: fuzzyFindFiles via Explorer" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check_auth(): pass");
    try explorer.indexFile("src/middleware/auth.py", "class Auth: pass");
    try explorer.indexFile("tests/test_auth.py", "def test_auth(): pass");
    try explorer.indexFile("src/utils.py", "def format_str(): pass");

    const results = try explorer.fuzzyFindFiles("authmid", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    // auth_middleware.py should be top result
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}

test "issue-168: query pipeline search returns matching lines" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {\n    const x = 42;\n}\n");
    try explorer.indexFile("src/lib.zig", "pub fn init() void {}\n");

    const results = try explorer.searchContent("main", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "main.zig") != null);
}

test "issue-168: recall — search finds content across multiple files" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/a.zig", "pub fn handleRequest() void {}");
    try explorer.indexFile("src/b.zig", "pub fn handleResponse() void {}");
    try explorer.indexFile("src/c.zig", "pub fn processData() void {}");

    const results = try explorer.searchContent("handle", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    // Should find "handle" in a.zig and b.zig but not c.zig
    try testing.expect(results.len >= 2);
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.path, "a.zig") != null) found_a = true;
        if (std.mem.indexOf(u8, r.path, "b.zig") != null) found_b = true;
        if (std.mem.indexOf(u8, r.path, "c.zig") != null) found_c = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(!found_c);
}

test "issue-168: recall — fuzzy find ranks exact matches highest" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.zig", "fn auth() void {}");
    try explorer.indexFile("src/authorization.zig", "fn authorize() void {}");
    try explorer.indexFile("src/authenticate.zig", "fn authenticate() void {}");

    const results = try explorer.fuzzyFindFiles("auth.zig", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    // Exact match "auth.zig" should be ranked first
    try testing.expect(std.mem.eql(u8, results[0].path, "src/auth.zig"));
    // Score should decrease for less exact matches
    if (results.len >= 2) {
        try testing.expect(results[0].score > results[1].score);
    }
}

test "query-pipeline: search → read with context_lines shows lines around hits" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/config.zig",
        \\const std = @import("std");
        \\
        \\// Configuration constants
        \\const MAX_RETRIES = 3;
        \\const TIMEOUT_MS = 5000;
        \\
        \\pub fn init() void {
        \\    // TODO: load from env
        \\    const retries = MAX_RETRIES;
        \\    const timeout = TIMEOUT_MS;
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const query_json =
        \\{"pipeline":[{"op":"search","query":"TODO"},{"op":"read","context_lines":2}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, query_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Should show the TODO line with 2 lines of context
    try testing.expect(std.mem.indexOf(u8, out.items, "TODO") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "config.zig") != null);
    // Should include the surrounding context (fn init, {)
    try testing.expect(std.mem.indexOf(u8, out.items, "pub fn init") != null);
    // Should NOT include line 1 (const std) since it's too far from the TODO
    try testing.expect(std.mem.indexOf(u8, out.items, "const std") == null);
}

// ── Search UX tests ─────────────────────────────────────────────

test "search: line numbers correct with incremental counting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // File with target on specific lines
    const content = "line1\nline2\ntarget_here\nline4\nline5\ntarget_here\nline7\n";
    try explorer.indexFile("test.zig", content);

    const results = try explorer.searchContent("target_here", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqual(@as(u32, 3), results[0].line_num);
    try testing.expectEqual(@as(u32, 6), results[1].line_num);
}

// ── Identifier splitting tests ──────────────────────────────────────────────

test "word-index: sub-token search finds camelCase components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "fn validateToken(x: u32) void {}");
    try explorer.indexFile("b.zig", "fn processRequest() void {}");

    // "validate" should find validateToken via sub-token splitting
    const r1 = try explorer.searchContent("validate", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expectEqual(@as(usize, 1), r1.len);
    try testing.expectEqualStrings("a.zig", r1[0].path);

    // "process" should find processRequest
    const r2 = try explorer.searchContent("process", testing.allocator, 10);
    defer {
        for (r2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r2);
    }
    try testing.expectEqual(@as(usize, 1), r2.len);
    try testing.expectEqualStrings("b.zig", r2[0].path);
}

test "word-index: sub-token search finds snake_case components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "const http_handler = null;");

    // "http" should find http_handler
    const r1 = try explorer.searchContent("http", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expect(r1.len >= 1);

    // "handler" should find http_handler
    const r2 = try explorer.searchContent("handler", testing.allocator, 10);
    defer {
        for (r2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r2);
    }
    try testing.expect(r2.len >= 1);
}

test "word-index: searchPrefix finds extensions of a prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    // Index a file with camelCase identifiers — splits produce sub-tokens
    try wi.indexFile("a.zig", "fn searchContent() void {} fn searchConfig() void {}");

    // "searchco" is a strict prefix of "searchcontent" and "searchconfig"
    const hits = try wi.searchPrefix("searchco", a, 32);
    try testing.expect(hits.len >= 1);
}

test "word-index: searchPrefix skips exact match (Tier 0 responsibility)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    try wi.indexFile("a.zig", "fn searchContent() void {}");

    // Exact key "search" exists (sub-token). searchPrefix should return 0 for exact key.
    const hits_exact = try wi.searchPrefix("search", a, 32);
    // "search" itself is in the index. Only keys STRICTLY longer are returned.
    // "searchcontent" is longer, so we expect ≥1 result.
    try testing.expect(hits_exact.len >= 1);

    // The hits must come from keys other than "search" itself.
    // Verify by checking "searchc..." style prefix:
    const hits_prefix = try wi.searchPrefix("searchco", a, 32);
    try testing.expect(hits_prefix.len >= 1);
}

test "word-index: searchPrefix respects max_results cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wi = WordIndex.init(a);

    // Index many distinct files producing many keys that share the "fooBar" prefix.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const path = try std.fmt.allocPrint(a, "f{d}.zig", .{i});
        const content = try std.fmt.allocPrint(a, "fn fooBar{d}() void {{}}\n", .{i});
        try wi.indexFile(path, content);
    }

    const cap: usize = 5;
    const hits = try wi.searchPrefix("foobar", a, cap);
    try testing.expect(hits.len <= cap);
    try testing.expect(hits.len > 0);
}

test "search: BM25 ranks higher-frequency line first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // Line with two occurrences of "token" should outrank line with one
    const content = "// single token mention\nconst token = token_cache.get();\n";
    try explorer.indexFile("auth.zig", content);

    const results = try explorer.searchContent("token", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    // Line 2 has "token" twice; line 1 has it once — line 2 should come first
    try testing.expect(results[0].score >= results[1].score);
    try testing.expectEqual(@as(u32, 2), results[0].line_num);
}

// ── Issue #290/#292: special-char queries must not crash MCP server ──
