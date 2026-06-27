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
const mcp_tools = @import("../mcp/explore_tools.zig");

test "callers: semantic match keeps real invocations and drops strings/comments" {
    try testing.expect(mcp_tools.callerLineMatches("    service.Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("    Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("    Probe<string>(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    logger.LogInformation(\"Probe(request)\");", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    // Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    var x = nameof(Probe);", "Probe", .c_sharp, "semantic"));
}

test "callers: text match mode preserves whole-word behavior" {
    try testing.expect(mcp_tools.callerLineMatches("    logger.LogInformation(\"Probe\");", "Probe", .c_sharp, "text"));
    try testing.expect(!mcp_tools.callerLineMatches("    ProbeRepository.Do();", "Probe", .c_sharp, "text"));
}
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

test "issue-290: codedb_search guidance does not warn on plain hyphen" {
    const args_json = "{\"query\":\"test-case\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") == null);
}

// ── Issue #207: serve-first scan state ─────────────────────────────────────

test "issue-356-1: codedb_query returns partial results when a step fails" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Pipeline: step 0 (find) succeeds, step 1 (search) is missing 'query'.
    // Pre-fix: bails on step 1, dropping step 0's output entirely.
    // Post-fix: returns step 0's matched files + a "--- partial ---" tail
    // naming the failing step.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"search"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Step 0's output (file matches) must survive even though step 1 failed.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    // The partial-results tail must name the failing step so callers can
    // recover instead of guessing what went wrong.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- partial ---") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "failed_at: 1") != null);
}

test "issue-356-3: codedb_query surfaces received keys on missing-arg errors" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Single-step pipeline: search step missing 'query' but provided 'q'
    // (common typo). The error should name the keys actually received so
    // the caller can self-diagnose, mirroring the #357 bundle diagnostic.
    const pipe_json =
        \\{"pipeline":[{"op":"search","q":"main"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // The legitimate missing-arg error must still appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "search needs 'query'") != null);
    // And the diagnostic must surface what the step actually contained.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "q") != null);
}

test "issue-356-p2: codedb_search missing query surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"q":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'query'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}

test "issue-356-p3: codedb_query emits per-stage summary tail on success" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Two-step pipeline that succeeds. Phase 3 emits a summary tail so
    // callers can see which step did what without re-parsing the
    // unstructured per-step output above it.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"sort","by":"path"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Stage summary appears at the end of a successful pipeline.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- stages ---") != null);
    // Lists each step with op and outgoing file count.
    try testing.expect(std.mem.indexOf(u8, out.items, "0: find") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1: sort") != null);
}

test "issue-356-p3: codedb_outline includes actionable hint when parser fails" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Outline a path that's NOT indexed (no setRoot, so disk read won't
    // help either). The "file not indexed" error already gets fuzzy
    // suggestions from phase 1. This test pins that the hint format is
    // actionable — specifically that a 'try codedb_index' suggestion
    // appears so users know how to recover from a stale index.
    const args_json =
        \\{"path":"src/notindexed.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "file not indexed") != null);
    // Phase 3 adds a 'codedb_index' hint so callers know how to recover
    // from a stale index in addition to the 'did you mean' suggestions.
    try testing.expect(std.mem.indexOf(u8, out.items, "codedb_index") != null);
}

test "issue-recall: codedb_search supports path_glob filter" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "received keys foo\n");
    try explorer.indexFile("CHANGELOG.md", "received keys diagnostic\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"received keys","path_glob":"*.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "CHANGELOG.md") == null);
}

test "issue-bug7: codedb_search rejects empty query" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":""}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "empty") != null);
}

test "issue-bug7: codedb_search rejects negative max_results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"foo","max_results":-3}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "max_results") != null);
}

test "issue-390: codedb_search scope=true caps matches per file" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Build a "dominant" file with 20 matches plus several files with 1 match
    // each. Without a per-file cap on the scope=true path, the dominant file
    // alone drowns the response. The plain/regex branches already enforce
    // max_per_file=5 (mcp.zig:1141, 1198), but the scope=true branch does not.
    var dominant_buf: std.ArrayList(u8) = .empty;
    defer dominant_buf.deinit(testing.allocator);
    try dominant_buf.appendSlice(testing.allocator, "pub fn dominant() void {\n");
    for (0..20) |_| try dominant_buf.appendSlice(testing.allocator, "    // FROBNICATE token\n");
    try dominant_buf.appendSlice(testing.allocator, "}\n");
    try explorer.indexFile("src/dominant.zig", dominant_buf.items);
    try explorer.indexFile("src/a.zig", "// FROBNICATE here\npub fn a() void {}\n");
    try explorer.indexFile("src/b.zig", "// FROBNICATE here\npub fn b() void {}\n");
    try explorer.indexFile("src/c.zig", "// FROBNICATE here\npub fn c() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"FROBNICATE","scope":true,"max_results":100}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // Count "src/dominant.zig:" occurrences (one per emitted match line).
    var dominant_lines: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, i, "src/dominant.zig:")) |pos| {
        dominant_lines += 1;
        i = pos + 1;
    }
    // The plain-search per-file cap is 5; scope=true should match. Without
    // any cap, all 20 matches surface and starve the smaller files.
    try testing.expect(dominant_lines <= 5);
    // The other files still surface — the cap shouldn't tank recall, just
    // bound the dominant file's share.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/a.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/b.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/c.zig:") != null);
}

test "codedb_ls ranked annotates and sorts by hotspot score" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("src/core.ts", "export function core() {}\nexport function helper() {}\n");
    try explorer.indexFile("src/leaf.ts", "export function leaf() {}\n");
    try explorer.indexFile("src/consumerA.ts", "import { core } from './core'\ncore();\n");
    try explorer.indexFile("src/consumerB.ts", "import { core } from './core'\ncore();\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src\",\"ranked\":true}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &parsed.value.object, &out, &store, &explorer, &agents);

    const core_pos = std.mem.indexOf(u8, out.items, "core.ts") orelse return error.TestUnexpectedResult;
    const leaf_pos = std.mem.indexOf(u8, out.items, "leaf.ts") orelse return error.TestUnexpectedResult;
    try testing.expect(core_pos < leaf_pos);
    try testing.expect(std.mem.indexOf(u8, out.items, "2 deps") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "score") != null);
}
