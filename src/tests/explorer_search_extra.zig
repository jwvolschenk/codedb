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

test "issue-290: searchContent with hyphen query does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    try explorer.indexFile("a.zig", "const x = \"test-case\";\n");
    const results = try explorer.searchContent("test-case", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
}

test "issue-292: searchContent with pipe query does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    try explorer.indexFile("a.zig", "const x = \"timestamp|activity|filter\";\n");
    const results = try explorer.searchContent("timestamp|activity|filter", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
}

test "issue-359/360: retrieval recall — search/word/symbol/fuzzy/glob/deps all return ground truth" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Flat paths so dep_graph keys (raw import strings) line up with file paths.
    try explorer.indexFile(
        "auth.zig",
        \\const std = @import("std");
        \\
        \\pub fn authenticate(token: []const u8) bool {
        \\    _ = token;
        \\    return true;
        \\}
        \\pub fn validateToken(token: []const u8) bool {
        \\    return authenticate(token);
        \\}
        ,
    );
    try explorer.indexFile(
        "handler.zig",
        \\const auth = @import("auth.zig");
        \\
        \\pub fn handleLogin() void {
        \\    if (auth.authenticate("x")) return;
        \\}
        ,
    );
    try explorer.indexFile(
        "auth_test.zig",
        \\const auth = @import("auth.zig");
        \\
        \\test "auth round-trip" {
        \\    _ = auth.authenticate("x");
        \\}
        ,
    );
    try explorer.indexFile(
        "unrelated.zig",
        \\pub fn formatNumber(n: i64) []const u8 {
        \\    _ = n;
        \\    return "0";
        \\}
        ,
    );
    try explorer.indexFile("README.md", "# project\nauthenticate description here");

    // 1. Full-text search: every file containing `authenticate` must appear.
    {
        const expected = [_][]const u8{ "auth.zig", "handler.zig", "auth_test.zig", "README.md" };
        const results = try explorer.searchContent("authenticate", testing.allocator, 50);
        defer {
            for (results) |r| {
                testing.allocator.free(r.line_text);
                testing.allocator.free(r.path);
            }
            testing.allocator.free(results);
        }
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        for (results) |r| try seen.put(r.path, {});
        for (expected) |e| try testing.expect(seen.contains(e));
        try testing.expect(!seen.contains("unrelated.zig"));
    }

    // 2. Word index: exact token `authenticate` must reach the same 4 files.
    {
        const hits = try explorer.searchWord("authenticate", testing.allocator);
        defer testing.allocator.free(hits);
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        for (hits) |h| try seen.put(explorer.word_index.hitPath(h), {});
        const expected = [_][]const u8{ "auth.zig", "handler.zig", "auth_test.zig", "README.md" };
        for (expected) |e| try testing.expect(seen.contains(e));
    }

    // 3. Symbol index: `authenticate` is defined once, in auth.zig.
    {
        const results = try explorer.findAllSymbols("authenticate", testing.allocator);
        defer {
            for (results) |r| {
                testing.allocator.free(r.path);
                testing.allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| testing.allocator.free(d);
                if (r.symbol.return_type) |rt| testing.allocator.free(rt);
                for (r.symbol.param_types) |pt| testing.allocator.free(pt);
                if (r.symbol.param_types.len > 0) testing.allocator.free(r.symbol.param_types);
            }
            testing.allocator.free(results);
        }
        try testing.expect(results.len >= 1);
        var found_def = false;
        for (results) |r| {
            if (std.mem.eql(u8, r.path, "auth.zig")) found_def = true;
        }
        try testing.expect(found_def);
    }

    // 4. Fuzzy file find: query "auth" must reach both auth.zig and auth_test.zig.
    {
        const results = try explorer.fuzzyFindFiles("auth", testing.allocator, 50);
        defer testing.allocator.free(results);
        var seen = std.StringHashMap(void).init(testing.allocator);
        defer seen.deinit();
        for (results) |r| try seen.put(r.path, {});
        try testing.expect(seen.contains("auth.zig"));
        try testing.expect(seen.contains("auth_test.zig"));
    }

    // 5. Glob: `auth*.zig` must include auth.zig and auth_test.zig only.
    {
        const matches = try explorer.globPaths(testing.allocator, "auth*.zig", 50);
        defer testing.allocator.free(matches);
        var found_auth = false;
        var found_test = false;
        for (matches) |m| {
            if (std.mem.eql(u8, m, "auth.zig")) found_auth = true;
            if (std.mem.eql(u8, m, "auth_test.zig")) found_test = true;
            try testing.expect(!std.mem.eql(u8, m, "unrelated.zig"));
            try testing.expect(!std.mem.eql(u8, m, "handler.zig"));
        }
        try testing.expect(found_auth);
        try testing.expect(found_test);
    }

    // 6. Dependency graph: handler.zig and auth_test.zig both import auth.zig.
    {
        const importers = try explorer.getImportedBy("auth.zig", testing.allocator);
        defer {
            for (importers) |p| testing.allocator.free(p);
            testing.allocator.free(importers);
        }
        var saw_handler = false;
        var saw_test = false;
        for (importers) |p| {
            if (std.mem.eql(u8, p, "handler.zig")) saw_handler = true;
            if (std.mem.eql(u8, p, "auth_test.zig")) saw_test = true;
        }
        try testing.expect(saw_handler);
        try testing.expect(saw_test);
    }
}

test "issue-363b: fuzzyFindFiles ranks exact basename match above unrelated lib.rs" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Reproducer from #363: indexing the codegraff workspace, querying 'cli.rs'
    // returned four `lib.rs` files before the actual `crates/forge_main/src/cli.rs`.
    // Path layout matches the user's report.
    try explorer.indexFile("crates/forge_ci/src/lib.rs", "pub fn ci() {}\n");
    try explorer.indexFile("crates/forge_fs/src/lib.rs", "pub fn fs() {}\n");
    try explorer.indexFile("crates/forge_app/src/lib.rs", "pub fn app_lib() {}\n");
    try explorer.indexFile("crates/forge_api/src/lib.rs", "pub fn api() {}\n");
    try explorer.indexFile(
        "crates/forge_main/src/cli.rs",
        "pub fn parse_args() -> Args {\n    Args {}\n}\n",
    );

    const matches = try explorer.fuzzyFindFiles("cli.rs", testing.allocator, 5);
    defer testing.allocator.free(matches);

    try testing.expect(matches.len > 0);
    // Exact-basename match should be #1, not buried below unrelated lib.rs files.
    try testing.expectEqualStrings("crates/forge_main/src/cli.rs", matches[0].path);
}

test "issue-378: search waits briefly for scan to reach ready instead of returning empty" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const prev_state = mcp_mod.getScanState();
    defer mcp_mod.setScanState(prev_state);
    mcp_mod.setScanState(.walking);

    const Flipper = struct {
        fn run(exp: *Explorer) void {
            cio.sleepMs(100);
            exp.indexFile("src/late.zig", "fn waitsForScanMarker() void {}\n") catch return;
            mcp_mod.setScanState(.ready);
        }
    };
    const t = try std.Thread.spawn(.{}, Flipper.run, .{&explorer});
    defer t.join();

    const args_json =
        \\{"query":"waitsForScanMarker"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "src/late.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "scan still in progress") == null);
}

test "issue-393: BM25 ranking surfaces high-density file before single-mention file" {
    // Multi-term content queries today return matches in scan order with only
    // a per-line occurrence count tiebreaker (explore.zig:1674-1688). On a
    // large repo this dumps every match with no notion of which *file* is the
    // most relevant — a file that mentions every query term many times ranks
    // identically to one that mentions a single term once.
    //
    // BM25 over the existing trigram + word index would score documents by
    // (per-term tf * idf) with length normalization, so the file densely
    // covering both terms surfaces above the noise file.
    //
    // Minimum surface contract: Explorer exposes `searchContentRanked` which
    // takes a multi-term query and returns results ordered by descending
    // BM25 score across files (highest-scoring document's match comes first).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // dense.zig: hits both query terms many times across many lines.
    try explorer.indexFile("src/dense.zig",
        \\pub fn parseTokenStream() void {
        \\    const token = nextToken();
        \\    parseToken(token);
        \\    parseToken(token);
        \\    parseToken(token);
        \\    const stream = parseTokenStream();
        \\    parseTokenStream();
        \\    _ = token;
        \\    _ = stream;
        \\}
    );
    // sparse.zig: mentions one term once, in passing.
    try explorer.indexFile("src/sparse.zig",
        \\pub fn unrelated() void {
        \\    // a passing mention of parse here
        \\    return;
        \\}
    );
    // Noise files dilute df-based scoring; BM25 must still rank dense first.
    try explorer.indexFile("src/noise_a.zig", "pub fn a() void {}\n");
    try explorer.indexFile("src/noise_b.zig", "pub fn b() void {}\n");
    try explorer.indexFile("src/noise_c.zig", "pub fn c() void {}\n");

    try testing.expect(@hasDecl(Explorer, "searchContentRanked"));

    const results = try explorer.searchContentRanked("parse Token", testing.allocator, 16);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len > 0);
    // Top-ranked result must come from the dense file.
    try testing.expectEqualStrings("src/dense.zig", results[0].path);
    // Score must be populated and strictly positive when ranking is on.
    try testing.expect(results[0].score > 0.0);
    // Results must be sorted by score descending across distinct documents:
    // the first dense.zig score must exceed the first sparse.zig score.
    var dense_score: f32 = -1.0;
    var sparse_score: f32 = -1.0;
    for (results) |r| {
        if (dense_score < 0 and std.mem.eql(u8, r.path, "src/dense.zig")) dense_score = r.score;
        if (sparse_score < 0 and std.mem.eql(u8, r.path, "src/sparse.zig")) sparse_score = r.score;
    }
    if (sparse_score >= 0) {
        try testing.expect(dense_score > sparse_score);
    }
}

test "issue-400: BM25 ranks both-terms file above single-term files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("both.zig",
        \\pub fn parseToken() void {
        \\    parseToken();
        \\    parseToken();
        \\}
    );
    try explorer.indexFile("only_parse.zig",
        \\pub fn parseFoo() void {
        \\    parse();
        \\}
    );
    try explorer.indexFile("only_token.zig",
        \\pub fn tokenStream() void {
        \\    token();
        \\}
    );

    const results = try explorer.searchContentRanked("parse Token", testing.allocator, 8);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("both.zig", results[0].path);
    try testing.expect(results[0].score > 0.0);
}

test "issue-427: searchContent Tier 1 sort starves the definition-dense file" {
    // searchContent's Tier 1 (explore.zig:1590-1598) sorts trigram candidates
    // by file content length ASCENDING and then applies a per-file cap of
    // max(1, max_results / estimated_total). When several small unrelated
    // files match the query, they each contribute one hit and saturate the
    // result quota before the canonical (large, definition-dense) file is
    // ever scanned — so the file with the most occurrences of the term is
    // missing from the output.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // 8 small files. Each contains one occurrence of the term as a whole
    // word. They sort first under the length-ascending Tier 1 order.
    const small_count: usize = 8;
    var i: usize = 0;
    while (i < small_count) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    // Canonical file: many lines mentioning widgetX, padded so its content
    // length is larger than every small file (sort key: content length).
    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    // padding line for content length, to push this file to the\n" ++
        "    // tail of the length-ascending sort. The reranker should still\n" ++
        "    // surface it because it has the most occurrences of the term.\n" ++
        "    _ = 0;\n" ++
        "}\n";
    try explorer.indexFile("canonical.zig", canonical_content);

    // max_results small enough that 8 small files can saturate the quota.
    // word_hits.len = small_count (8) + canonical occurrences (4) = 12.
    // max_results * 2 = 10. 12 > 10 → Tier 0 gate fails → Tier 1 fires.
    const results = try explorer.searchContent("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // The canonical file MUST appear in the result set. Pre-fix it does not:
    // small files fill all 5 slots first under length-asc order, and the
    // early-return at result_list.len >= max_results returns before the
    // canonical file is ever read.
    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) {
            found_canonical = true;
            break;
        }
    }
    try testing.expect(found_canonical);
}

test "issue-429-a: searchContent rerank boosts files whose basename matches the query" {
    // Two files, same hit count, same content length. The current rerank
    // (explore.zig:1700-1712) sorts ties by path-asc, so a file named
    // "unrelated.zig" outranks "widgetX.zig" even though the latter's
    // basename matches the query exactly. The basename match is a strong
    // intent signal — the developer is asking about that file's subject.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/unrelated.zig", "pub fn process() void { _ = widgetX; }\n");
    try explorer.indexFile("src/widgetX.zig", "pub fn process() void { _ = widgetX; }\n");

    const results = try explorer.searchContent("widgetX", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/widgetX.zig", results[0].path);
}

test "issue-429-b: searchContent rerank penalizes test/vendor/examples paths" {
    // Two files, same hit count, same content. Pre-fix the path-asc
    // tiebreaker promotes "examples/sample.zig" (e < s) above
    // "src/sample.zig". Post-fix path priors push code roots above
    // example/test/vendor directories so the source-of-truth lands first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("examples/sample.zig", "pub fn x() void { _ = someTerm; }\n");
    try explorer.indexFile("src/sample.zig", "pub fn x() void { _ = someTerm; }\n");

    const results = try explorer.searchContent("someTerm", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/sample.zig", results[0].path);
}

test "issue-431: searchContent does not crash when query is longer than content" {
    // searchInContent (explore.zig:3881) computes
    //   const end = content.len - query.len + 1;
    // without checking that query.len <= content.len. When the query is
    // longer than the file content, the subtraction underflows in usize
    // and the binary panics with integer overflow (or aborts with SIGBUS
    // in ReleaseFast). Reproducer: index a tiny file, search for a query
    // longer than the file's content.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "fn x() void {}\n");

    var q_buf: [256]u8 = undefined;
    @memset(&q_buf, 'a');
    const q = q_buf[0..256];

    const results = try explorer.searchContent(q, testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "issue-429-d: searchContent rerank boosts path-segment match" {
    // Two files, same hit count, same content. The query "parser" appears
    // as a directory segment of one path. Pre-fix the alphabetic tiebreak
    // promotes "src/handlers/foo.zig" (h < p). Post-fix the path-segment
    // match boost surfaces "src/parser/foo.zig" first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/handlers/foo.zig", "// parser is mentioned here\n");
    try explorer.indexFile("src/parser/foo.zig", "// parser is mentioned here\n");

    const results = try explorer.searchContent("parser", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/parser/foo.zig", results[0].path);
}

test "issue-429-e: searchContent rerank penalises doc-language files so code beats markdown noise" {
    // CHANGELOG.md and benchmark docs often mention an identifier many times
    // in a single line, which under per-line frequency outscores any single
    // code call site. The reranker now halves doc-language scores so a code
    // call site with one occurrence still wins.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // Doc file with the identifier mentioned four times on one line —
    // pre-fix this scores 4 on per-line frequency.
    try explorer.indexFile(
        "CHANGELOG.md",
        "# Changelog\n\nfooBar — fooBar fooBar fooBar in the changelog.\n",
    );
    // Code call site with the identifier mentioned once.
    try explorer.indexFile(
        "src/caller.zig",
        "pub fn caller() void {\n    fooBar();\n}\n",
    );

    const results = try explorer.searchContent("fooBar", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/caller.zig", results[0].path);
}

test "issue-448-a: rerank boosts basename when query contains stem" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/aaa.zig", "// Explorer is mentioned here\n");
    try explorer.indexFile("src/explore.zig", "// Explorer is mentioned here\n");

    const results = try explorer.searchContent("Explorer", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("src/explore.zig", results[0].path);
}

test "issue-448-b: rerank symbol definition boost is case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("aaa.zig", "// store is mentioned here\n");
    try explorer.indexFile("zzz.zig", "pub const Store = struct {};\n");

    const results = try explorer.searchContent("store", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("zzz.zig", results[0].path);
}

test "rerank-trace: appends one JSON line per searchContent when enabled" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/rerank-traces.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    try explorer.indexFile("src/widgetX.zig", "pub fn process() void { _ = widgetX; }\n");
    try explorer.indexFile("src/unrelated.zig", "pub fn process() void { _ = widgetX; }\n");

    const results = try explorer.searchContent("widgetX", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const size = try f.length(tmp_io);
    try testing.expect(size > 0);

    const data = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(data);
    _ = try f.readPositionalAll(tmp_io, data, 0);

    try testing.expectEqual(@as(u8, '\n'), data[data.len - 1]);
    var nl_count: usize = 0;
    for (data) |c| if (c == '\n') {
        nl_count += 1;
    };
    try testing.expectEqual(@as(usize, 1), nl_count);

    try testing.expect(std.mem.indexOf(u8, data, "\"query\":\"widgetX\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "src/widgetX.zig") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"results\":[") != null);
}

test "rerank-trace: disabled by default — no file is created" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const probe_path = try std.fmt.allocPrint(testing.allocator, "{s}/should-not-exist.jsonl", .{tmp_path});
    defer testing.allocator.free(probe_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    explorer.io = tmp_io;
    // rerank_trace_path stays null — opt-in only.

    try explorer.indexFile("a.zig", "pub fn t() void { _ = sym; }\n");
    try explorer.indexFile("b.zig", "pub fn t() void { _ = sym; }\n");

    const results = try explorer.searchContent("sym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 1);

    const open_err = std.Io.Dir.cwd().openFile(tmp_io, probe_path, .{});
    try testing.expectError(error.FileNotFound, open_err);
}

test "rerank-trace: clobbers when file exceeds size limit" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    {
        const f = try std.Io.Dir.cwd().createFile(tmp_io, trace_path, .{ .truncate = true });
        defer f.close(tmp_io);
        const target_size: u64 = 11 * 1024 * 1024;
        var chunk: [4096]u8 = undefined;
        @memset(&chunk, 'x');
        var written: u64 = 0;
        while (written < target_size) : (written += chunk.len) {
            try f.writePositionalAll(tmp_io, &chunk, written);
        }
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    try explorer.indexFile("a.zig", "pub fn t() void { _ = sym; }\n");
    try explorer.indexFile("b.zig", "pub fn t() void { _ = sym; }\n");

    const results = try explorer.searchContent("sym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const new_size = try f.length(tmp_io);
    try testing.expect(new_size > 0);
    try testing.expect(new_size < 16 * 1024);
}

test "rerank-trace: single-result query records non-zero rerank score" {
    // Pre-fix: rerankAndFinalize only scored when items.len > 1, so a
    // single-result trace logged score=0.0 — misleading for offline analysis
    // because it looked identical to a zero-confidence match. The fix runs
    // scoring unconditionally and only sorts when there's more than one item.
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(tmp_io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    const trace_path = try std.fmt.allocPrint(testing.allocator, "{s}/single.jsonl", .{tmp_path});
    defer testing.allocator.free(trace_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    explorer.io = tmp_io;
    explorer.rerank_trace_path = trace_path;

    // Only one file mentions the query — guarantees results.len == 1.
    try explorer.indexFile("src/loneSym.zig", "pub fn loneSym() void {}\n");
    try explorer.indexFile("src/other.zig", "pub fn unrelated() void {}\n");

    const results = try explorer.searchContent("loneSym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    // Symbol-def boost (+5) + basename-substring boost (+8) + per-line freq
    // means score is well above zero — verifies scoring actually ran.
    try testing.expect(results[0].score > 1.0);

    const f = try std.Io.Dir.cwd().openFile(tmp_io, trace_path, .{});
    defer f.close(tmp_io);
    const size = try f.length(tmp_io);
    const data = try testing.allocator.alloc(u8, @intCast(size));
    defer testing.allocator.free(data);
    _ = try f.readPositionalAll(tmp_io, data, 0);

    try testing.expect(std.mem.indexOf(u8, data, "\"score\":0.0000") == null);
    try testing.expect(std.mem.indexOf(u8, data, "src/loneSym.zig") != null);
}
