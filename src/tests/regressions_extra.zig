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

test "issue-179: Python multi-line docstring with def inside" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("doc.py",
        \\def outer():
        \\    """
        \\    Example:
        \\        def inner_example():
        \\            pass
        \\    """
        \\    return True
    );

    const outer = try explorer.findAllSymbols("outer", alloc);
    defer alloc.free(outer);
    try testing.expect(outer.len == 1);

    const inner = try explorer.findAllSymbols("inner_example", alloc);
    defer alloc.free(inner);
    try testing.expectEqual(@as(usize, 0), inner.len);
}

test "issue-264: early exit at max_results misses valid matches in remaining candidates" {
    // searchContent stops as soon as result_list.items.len >= max_results.
    // The first-indexed file is iterated first (doc_id order).  If it has
    // many matches it fills the quota alone, and later files are never checked.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Index noisy file FIRST — it will be the first trigram candidate.
    try explorer.indexFile("noisy.zig",
        \\fn target_token() void {}
        \\fn target_token_v2() void {}
        \\const target_token_ptr = undefined;
        \\var target_token_state = 0;
        \\test "target_token works" {}
        \\// calls target_token internally
    );

    // Index quiet file SECOND — it will be a later candidate.
    try explorer.indexFile("quiet.zig", "fn target_token() void {}");

    // max_results=5: noisy.zig has 6 matches, fills the quota.
    const results = try explorer.searchContent("target_token", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // quiet.zig must be represented in results even though noisy.zig
    // has enough matches to fill max_results by itself.
    var found_quiet = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "quiet.zig")) found_quiet = true;
    }
    try testing.expect(found_quiet);
}

// ── DependencyGraph tests ──────────────────────────────────

test "issue-445: dep-graph dedupes multi-aliased forward imports" {
    // A file that imports the same dep under multiple aliases
    //   const idx = @import("index.zig");
    //   const Index = @import("index.zig").Foo;
    //   const reset = @import("index.zig").resetFrequencyTable;
    // produces multiple "index.zig" entries in outline.imports, which
    // rebuildDepsFor previously appended verbatim — so getForwardDeps
    // returned "index.zig" 5 times for src/main.zig in this very repo.
    // The depends_on list should be unique by path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("index.zig", "pub fn build() void {}");
    try explorer.indexFile("main.zig",
        \\const idx = @import("index.zig");
        \\const Index = @import("index.zig").Foo;
        \\const reset = @import("index.zig").resetFrequencyTable;
        \\pub fn main() void {}
    );

    explorer.mu.lockShared();
    const fwd_opt = explorer.dep_graph.getForwardDeps("main.zig");
    explorer.mu.unlockShared();

    try testing.expect(fwd_opt != null);
    const fwd = fwd_opt.?;
    try testing.expectEqual(@as(usize, 1), fwd.len);
    try testing.expectEqualStrings("index.zig", fwd[0]);
}

// ── Symbol index tests ─────────────────────────────────────

test "issue-207: ScanState round-trips through atomic" {
    const initial = mcp_mod.getScanState();
    defer mcp_mod.setScanState(initial);

    mcp_mod.setScanState(.loading_snapshot);
    try testing.expectEqual(mcp_mod.ScanState.loading_snapshot, mcp_mod.getScanState());

    mcp_mod.setScanState(.walking);
    try testing.expectEqual(mcp_mod.ScanState.walking, mcp_mod.getScanState());

    mcp_mod.setScanState(.indexing);
    try testing.expectEqual(mcp_mod.ScanState.indexing, mcp_mod.getScanState());

    mcp_mod.setScanState(.ready);
    try testing.expectEqual(mcp_mod.ScanState.ready, mcp_mod.getScanState());
}

test "issue-207: ScanState.name covers all states" {
    try testing.expectEqualStrings("loading_snapshot", mcp_mod.ScanState.loading_snapshot.name());
    try testing.expectEqualStrings("walking", mcp_mod.ScanState.walking.name());
    try testing.expectEqualStrings("indexing", mcp_mod.ScanState.indexing.name());
    try testing.expectEqualStrings("ready", mcp_mod.ScanState.ready.name());
}

test "issue-359: globPaths matches files by glob pattern" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/mcp.zig", "pub fn a() void {}");
    try explorer.indexFile("src/explore.zig", "pub fn b() void {}");
    try explorer.indexFile("src/sub/inner.zig", "pub fn c() void {}");
    try explorer.indexFile("tests/test_main.py", "def t(): pass");
    try explorer.indexFile("README.md", "# readme");

    // ** matches across path separators
    const zigs = try explorer.globPaths(testing.allocator, "src/**/*.zig", 100);
    defer testing.allocator.free(zigs);
    try testing.expectEqual(@as(usize, 3), zigs.len);

    // single * does not cross path separators
    const top_zigs = try explorer.globPaths(testing.allocator, "src/*.zig", 100);
    defer testing.allocator.free(top_zigs);
    try testing.expectEqual(@as(usize, 2), top_zigs.len);

    // top-level extension match
    const md = try explorer.globPaths(testing.allocator, "*.md", 100);
    defer testing.allocator.free(md);
    try testing.expectEqual(@as(usize, 1), md.len);
    try testing.expectEqualStrings("README.md", md[0]);

    // results are sorted
    const all_zigs = try explorer.globPaths(testing.allocator, "**/*.zig", 100);
    defer testing.allocator.free(all_zigs);
    try testing.expect(all_zigs.len >= 2);
    var i: usize = 1;
    while (i < all_zigs.len) : (i += 1) {
        try testing.expect(std.mem.order(u8, all_zigs[i - 1], all_zigs[i]) == .lt);
    }
}

test "issue-359: lsDir returns immediate children with file metadata" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/mcp.zig", "pub fn a() void {}");
    try explorer.indexFile("src/explore.zig", "pub fn b() void {}");
    try explorer.indexFile("src/sub/inner.zig", "pub fn c() void {}");
    try explorer.indexFile("tests/test_main.py", "def t(): pass");
    try explorer.indexFile("README.md", "# readme");

    // Top-level: 1 file (README.md) + 2 dirs (src/, tests/)
    const top = try explorer.lsDir(testing.allocator, "", false);
    defer {
        for (top) |e| if (!e.is_dir and e.descriptor.len > 0) testing.allocator.free(e.descriptor);
        testing.allocator.free(top);
    }
    try testing.expectEqual(@as(usize, 3), top.len);

    var saw_readme = false;
    var saw_src_dir = false;
    var saw_tests_dir = false;
    for (top) |e| {
        if (std.mem.eql(u8, e.name, "README.md")) {
            try testing.expect(!e.is_dir);
            saw_readme = true;
        }
        if (std.mem.eql(u8, e.name, "src")) {
            try testing.expect(e.is_dir);
            saw_src_dir = true;
        }
        if (std.mem.eql(u8, e.name, "tests")) {
            try testing.expect(e.is_dir);
            saw_tests_dir = true;
        }
    }
    try testing.expect(saw_readme and saw_src_dir and saw_tests_dir);

    // Inside src/: 2 files (mcp.zig, explore.zig) + 1 dir (sub/)
    const src_children = try explorer.lsDir(testing.allocator, "src", false);
    defer {
        for (src_children) |e| if (!e.is_dir and e.descriptor.len > 0) testing.allocator.free(e.descriptor);
        testing.allocator.free(src_children);
    }
    try testing.expectEqual(@as(usize, 3), src_children.len);

    var saw_sub_dir = false;
    var file_count: usize = 0;
    for (src_children) |e| {
        if (e.is_dir) {
            if (std.mem.eql(u8, e.name, "sub")) saw_sub_dir = true;
        } else {
            file_count += 1;
            try testing.expect(e.line_count >= 1);
        }
    }
    try testing.expect(saw_sub_dir);
    try testing.expectEqual(@as(usize, 2), file_count);
}

test "issue-359: globPaths recall — every matching path survives at every depth" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Plant files at varying depths under src/, plus a few outside it.
    const planted = [_][]const u8{
        "src/a.zig",
        "src/b.zig",
        "src/sub/c.zig",
        "src/sub/d.zig",
        "src/sub/deep/e.zig",
        "src/sub/deep/f.zig",
        "src/sub/deep/deeper/g.zig",
        "tests/h.zig",
        "src/notes.md",
        "src/sub/notes.md",
    };
    for (planted) |p| try explorer.indexFile(p, "pub fn x() void {}");

    // src/**/*.zig must reach every depth — this is the case the old
    // iterative matcher silently dropped (single star slot lost the
    // outer ** position when the inner *.zig star ran).
    const all_src_zigs = try explorer.globPaths(testing.allocator, "src/**/*.zig", 100);
    defer testing.allocator.free(all_src_zigs);
    try testing.expectEqual(@as(usize, 7), all_src_zigs.len);

    // Single * does not cross /: only the two top-level src zigs.
    const top = try explorer.globPaths(testing.allocator, "src/*.zig", 100);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 2), top.len);

    // **/*.md should find both markdown files no matter their depth.
    const md = try explorer.globPaths(testing.allocator, "**/*.md", 100);
    defer testing.allocator.free(md);
    try testing.expectEqual(@as(usize, 2), md.len);

    // Anchored deep match: src/**/g.zig must find the deepest one only.
    const g = try explorer.globPaths(testing.allocator, "src/**/g.zig", 100);
    defer testing.allocator.free(g);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqualStrings("src/sub/deep/deeper/g.zig", g[0]);

    // Pipeline filter must agree path-for-path with globPaths, since it
    // now routes through the same matcher. Spot-check a few.
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/sub/deep/deeper/g.zig"));
    try testing.expect(mcp_mod.globMatch("**/*.md", "src/sub/notes.md"));
    try testing.expect(!mcp_mod.globMatch("src/**/*.zig", "tests/h.zig"));
}

// ── Retrieval-quality test ────────────────────────────────────────────────
//
// Plants a small corpus where the ground-truth set of files matching each
// query is fully known, then exercises every retrieval surface of the
// Explorer (full-text search, exact word lookup, symbol-by-name, fuzzy
// file find, glob, and dependency edges) and asserts perfect recall — i.e.
// every expected file shows up. Catches silent-drop regressions across
// the trigram index, sparse-ngram index, word index, symbol index, and
// dep graph in one place.

test "issue-357: bundle surfaces received keys when an op is missing required path" {
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

    // Bundle with a wrong key name ('file_path' instead of 'path'). The op must
    // fail (path is missing), but the bundle wrapper must surface the keys it
    // received so the caller can tell whether codedb dropped the arg or the
    // client sent it under the wrong name.
    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{"file_path":"src/main.zig"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // The error itself must still appear (legitimate — path is missing).
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path' argument") != null);
    // And the bundle must surface what the op actually contained, naming the
    // bad key so the caller can self-diagnose.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "file_path") != null);
}

test "issue-423: bundle emits 'received keys' exactly once per failing op" {
    // Regression: handler (handleSearch etc) appends the diagnostic, AND the
    // bundle dispatch loop also appends it — caller saw the line twice in a
    // row. Must appear exactly once per failing op.
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

    const bundle_json =
        \\{"ops":[{"tool":"codedb_search","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, idx, "received keys:")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "issue-367: openDataLog truncates orphan bytes from prior session" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    const orphan = "ORPHAN_SECRET_TOKEN_FROM_PRIOR_SESSION";
    {
        const f = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, orphan, 0);
    }

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.openDataLog(io, log_path);

    const f = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    try testing.expectEqual(@as(u64, 0), len);
    try testing.expectEqual(@as(u64, 0), store.data_log_pos);

    const diff = "fresh diff";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0xABCD, diff.len, diff);

    var buf: [128]u8 = undefined;
    const f2 = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer f2.close(io);
    const new_len = try f2.length(io);
    try testing.expectEqual(@as(u64, diff.len), new_len);
    const read_len = try f2.readPositionalAll(io, buf[0..diff.len], 0);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
}

test "issue-367-dx: tty summary surfaces received keys on missing-arg error" {
    const args_json =
        \\{"file_path":"src/main.zig","weird_key":"x"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    const raw_output = "error: missing 'path' argument\nreceived keys: [file_path, weird_key]";

    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(testing.allocator);

    mcp_mod.mcpGenerateSummary(
        testing.allocator,
        "codedb_outline",
        &parsed.value.object,
        raw_output,
        true,
        &summary,
    );

    try testing.expect(std.mem.indexOf(u8, summary.items, "received") != null);
    try testing.expect(std.mem.indexOf(u8, summary.items, "file_path") != null);
}

test "issue-bug2: index-dependent tools refuse to answer while scan is in progress" {
    // Old behavior: a query issued mid-scan ran anyway; "0 results" got a hint
    // note appended, but a PARTIAL non-empty result carried no warning at all —
    // an agent could not distinguish "doesn't exist" from "not indexed yet".
    // New contract: after a bounded wait, an in-progress scan yields an
    // explicit refusal instead of a silently incomplete answer.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const mcp_server = @import("../mcp/server.zig");
    const prev_timeout = mcp_server.scan_wait_timeout_ms;
    defer mcp_server.scan_wait_timeout_ms = prev_timeout;
    mcp_server.scan_wait_timeout_ms = 100;

    const prev_state = mcp_mod.getScanState();
    defer mcp_mod.setScanState(prev_state);
    mcp_mod.setScanState(.walking);

    const args_json =
        \\{"query":"some_unknown_symbol_that_will_not_match"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "scan still in progress") != null);
    // The query must NOT have run — a mid-scan "0 results" is indistinguishable
    // from an authoritative empty answer.
    try testing.expect(std.mem.indexOf(u8, out.items, "0 results") == null);
}

test "issue-bug2b: lazy server with empty index returns explicit error, not empty results" {
    // scan=lazy is terminal — no scan is coming. Serving a well-formed
    // "0 results" from a zero-file index reads as "symbol does not exist";
    // the honest answer is an explicit no-project-indexed error.
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
    mcp_mod.setScanState(.lazy);

    const args_json =
        \\{"query":"anything"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "no project indexed") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "0 results") == null);
}

test "issue-389: FilteredWalker yields symlinked source files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "src");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/target.zig", .data = "pub fn linked() void {}\n// MARKER_LINE\n" });

    // Create an in-workspace symlink: src/alias.zig -> target.zig (relative).
    var src_dir = try tmp_dir.dir.openDir(io, "src", .{ .iterate = true });
    defer src_dir.close(io);
    src_dir.symLink(io, "target.zig", "alias.zig", .{}) catch |err| switch (err) {
        // If the OS denies symlinks (e.g. CI without privilege on Windows),
        // skip the test rather than report a false negative.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);

    // Both the real file and the symlinked alias must be indexed. The bug at
    // src/watcher.zig:319 drops every entry whose kind != .file, silently
    // skipping symlinks even when they point at in-workspace source files.
    try testing.expect(explorer.contents.contains("src/target.zig"));
    try testing.expect(explorer.contents.contains("src/alias.zig"));
}

test "issue-405: FilteredWalker walks directory symlinks safely (cycle + escape)" {
    // Follow-up to #389. The current FilteredWalker.next() (src/watcher.zig:319-323)
    // treats sym_link entries as files when statFile reports .file, but silently
    // drops sym_link entries whose target is a directory. Real repos rely on
    // directory symlinks (monorepo package links, vendored deps, dotfile configs),
    // so the indexer must walk them — but only safely. This test pins three things:
    //   1. A file inside a symlinked subdirectory is indexed.
    //   2. A symlink that introduces a cycle does not hang or duplicate entries.
    //   3. (Implicit) The walker terminates in bounded time on the fixture.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Real directory `pkg/` with one source file.
    try tmp_dir.dir.createDirPath(io, "pkg");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "pkg/inside.zig", .data = "pub fn inside() void {}\n" });

    // A real directory `app/` that holds a directory-symlink `linked_pkg -> ../pkg`.
    // We expect the walker to descend into `linked_pkg` and yield `app/linked_pkg/inside.zig`.
    try tmp_dir.dir.createDirPath(io, "app");
    var app_dir = try tmp_dir.dir.openDir(io, "app", .{ .iterate = true });
    defer app_dir.close(io);
    app_dir.symLink(io, "../pkg", "linked_pkg", .{}) catch |err| switch (err) {
        // Skip on platforms / CI configurations that deny symlink creation.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    // Cycle: `app/loop -> ..` points back at the workspace root. Without cycle
    // detection a naive walker recurses forever via app/loop/app/loop/app/...
    app_dir.symLink(io, "..", "loop", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store, &explorer, root, testing.allocator, false, 1);

    // 1. The in-target file must appear under the symlinked path. This is the
    //    behaviour gap left by #389 — directory symlinks are currently ignored,
    //    so this assertion fails on main.
    try testing.expect(explorer.contents.contains("app/linked_pkg/inside.zig"));

    // 2. The real path must also be indexed exactly once.
    try testing.expect(explorer.contents.contains("pkg/inside.zig"));

    // 3. The cycle must not have produced a deeply-nested duplicate entry.
    //    If cycle detection is missing, paths like
    //    `app/loop/app/loop/app/linked_pkg/inside.zig` would appear (or the
    //    scan would never terminate). Assert no path contains "loop/app/loop".
    var it = explorer.contents.iterator();
    while (it.next()) |kv| {
        const p = kv.key_ptr.*;
        try testing.expect(std.mem.indexOf(u8, p, "loop/app/loop") == null);
    }
}

test "issue-411: tryLock grants new locks to a crashed agent" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("zombie");

    // Force the agent into the crashed state via reapStale.
    const a = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    a.last_seen = 0;
    agents.reapStale(0);
    try testing.expectEqual(@as(@TypeOf(a.state), .crashed), a.state);

    // A crashed agent should not be allowed to acquire new advisory locks
    // until it heartbeats back to .active. Today tryLock ignores .state and
    // happily grants the lock — leaving the registry inconsistent (a
    // .crashed agent suddenly holds fresh locks again).
    const got = try agents.tryLock(id, "post-crash.zig", 60_000);
    try testing.expect(got == false);
}

test "issue-406: root_policy blocks /private/etc (macOS realpath of /etc)" {
    const root_policy = @import("../root_policy.zig");
    // /etc is in the system_prefixes deny list, but on macOS /etc is a symlink
    // to /private/etc. Callers feed isIndexableRoot a path resolved by
    // realPathFile (see handleIndex in src/mcp.zig), which turns "/etc" into
    // "/private/etc" — and then this textual prefix check accepts it. The
    // canonical form must be blocked too, otherwise the deny list is bypassed
    // by the very normalization step the callers depend on.
    try testing.expect(!root_policy.isIndexableRoot("/private/etc"));
    try testing.expect(!root_policy.isIndexableRoot("/private/etc/ssh"));
}

test "issue-407: root_policy blocks /var and its non-folders subtree" {
    const root_policy = @import("../root_policy.zig");
    // The system_prefixes list explicitly blocks /var/folders and /var/tmp,
    // but not /var itself or /var/log, /var/lib, /var/db, /var/spool, etc.
    // On Linux those hold logs, mail, and package state; on macOS realPathFile
    // turns /var into /private/var (also unblocked). Accidentally pointing
    // the indexer at /var/log on a server pulls in GBs of secrets and is
    // never a valid "project root".
    try testing.expect(!root_policy.isIndexableRoot("/var"));
    try testing.expect(!root_policy.isIndexableRoot("/var/log"));
    try testing.expect(!root_policy.isIndexableRoot("/var/lib"));
    try testing.expect(!root_policy.isIndexableRoot("/private/var"));
    try testing.expect(!root_policy.isIndexableRoot("/private/var/log"));
}

test "issue-409: replacing whole file with empty content leaves a stray newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-409.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Single-line file with trailing newline.
    const original = "abc\n";
    var file = try tmp.dir.createFile(io, "edit-409.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-409-agent");

    // Replace the only line with empty content. The caller's intent is "make
    // this file empty" — content has zero bytes.
    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // Expectation: the file is empty. Currently the file ends up as "\n"
    // because applyEdit unconditionally restores the trailing newline that
    // existed in the source, even after the replacement reduced the file
    // to a single empty line.
    try testing.expectEqual(@as(usize, 0), after.len);
    try testing.expectEqual(@as(u64, 0), result.new_size);
}

test "issue-412: bundle reports 'missing tool' for tool field of wrong type" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":123,"arguments":{"path":"x.zig"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'tool' field") == null);
}

test "issue-413: bundle truncation drops subsequent ops without telling the caller" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Index a single large file (~120KB) so two reads exceed the 200KB
    // bundle cap. Bundle truncates and breaks out of the loop after op[1],
    // emitting a TRUNCATED note — but op[2] is silently dropped.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    while (big.items.len < 120 * 1024) {
        try big.appendSlice(testing.allocator, "pub fn placeholder() void { _ = 0; }\n");
    }
    try explorer.indexFile("big.zig", big.items);
    try explorer.indexFile("small.zig", "pub fn small() void {}\n");

    // Three reads: first two exceed 200KB → truncate. op[2] is small.zig
    // and should still surface — at minimum, the bundle output must
    // mention it (e.g. as another truncated entry) so the caller knows
    // their request had three ops, not one.
    const bundle_json =
        \\{"ops":[
        \\  {"tool":"codedb_read","arguments":{"path":"big.zig"}},
        \\  {"tool":"codedb_read","arguments":{"path":"big.zig"}},
        \\  {"tool":"codedb_outline","arguments":{"path":"small.zig"}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // op[2] (index 2) was sent — caller deserves to see something for it.
    // Either its result, or an explicit "[2]" entry noting it was dropped.
    try testing.expect(std.mem.indexOf(u8, out.items, "[2]") != null);
}

test "issue-424-B: bundle falls through to inline args when arguments is empty object" {
    // Forge-style buggy clients sometimes send `arguments: {}` AND put the
    // real args inline at the op level. The dispatcher currently sees the
    // empty `arguments` and stops looking — resulting in a misleading
    // "missing 'path'" with `received keys: []` even though `path` is
    // sitting right there in the op.
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

    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{},"path":"src/main.zig"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Should succeed: path was discoverable inline even though `arguments` was empty.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys: []") == null);
}

test "issue-424-D: received-keys diagnostic hints at inline-args workaround when empty" {
    // When a sub-op fails with truly-empty args, the diagnostic should
    // point users at the inline-args fallback so a broken client wrapper
    // can be routed around without a server change.
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

    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Original error stays.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    // The diagnostic should fire (received-keys line present) and surface
    // the inline-shape hint, since no real sub-op args were observed.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "inline shape") != null);
}

test "issue-424-A: bundle envelope errors carry the 'error:' prefix consistently" {
    // Pre-fix the bundle dispatcher emits 'op must be an object' and
    // 'missing 'tool' field' WITHOUT the 'error:' prefix that per-tool
    // handlers and TTY-summary parsing both expect. Normalize.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Op is a string, not an object.
    const bad_shape =
        \\{"ops":["not-an-object"]}
    ;
    const parsed1 = try std.json.parseFromSlice(std.json.Value, testing.allocator, bad_shape, .{});
    defer parsed1.deinit();
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed1.value.object, &out1, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, out1.items, "error: op must be an object") != null);

    // Op missing 'tool' field.
    const no_tool =
        \\{"ops":[{"arguments":{}}]}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, no_tool, .{});
    defer parsed2.deinit();
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed2.value.object, &out2, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, out2.items, "error: missing 'tool'") != null);
}

test "issue-430: Tier 0 markdown dominance starves canonical source file" {
    // Tier 0 of searchContent (explore.zig:1525-1554) iterates the word
    // index posting list in insertion order with a per-file cap of
    // max(1, max_results/5). When a handful of markdown documents
    // (CHANGELOG.md, benchmarks/*.md, design docs) each mention the query
    // many times AND happen to appear earlier in the posting list than the
    // canonical source file, they saturate result_list before the source
    // file is reached. The existing #363a fix asserted *presence* with a
    // small corpus; this is the high-density regime where presence still
    // fails because Tier 0 hits max_results before the source file's
    // posting-list entries are processed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // 5 markdown files each with 10 mentions of fooBar — indexed FIRST so
    // they land at the head of the posting list. With max_results=50 and
    // per-file cap=10, these 5 files alone fill all 50 slots.
    const md_block = "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n" ++
        "fooBar mentioned here.\nfooBar mentioned here.\n";
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        try explorer.indexFile(path, md_block);
    }

    // Source file with the canonical definition + several real call sites,
    // indexed LAST so its posting-list entries come after the markdown noise.
    try explorer.indexFile("src/foo.zig", "pub fn fooBar() void {}\n" ++
        "pub fn caller1() void { fooBar(); }\n" ++
        "pub fn caller2() void { fooBar(); }\n" ++
        "pub fn caller3() void { fooBar(); }\n");

    const results = try explorer.searchContent("fooBar", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/foo.zig")) {
            found_source = true;
            break;
        }
    }
    // The canonical source file MUST appear in the results. Pre-fix it does
    // not: 5 markdown files × 10 hits = 50 entries fill result_list before
    // the source file is reached, then Tier 0 returns at max_results.
    try testing.expect(found_source);
}

test "issue-449: popular markdown should not disable Tier 0 code-first behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    const md_block =
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n" ++
        "fooBar mentioned here.\n";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "docs/notes_{d}.md", .{i});
        try explorer.indexFile(path, md_block);
    }

    try explorer.indexFile("src/foo.zig", "pub fn fooBar() void {}\n" ++
        "pub fn caller1() void { fooBar(); }\n" ++
        "pub fn caller2() void { fooBar(); }\n" ++
        "pub fn caller3() void { fooBar(); }\n");

    const results = try explorer.searchContent("fooBar", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    var found_source = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "src/foo.zig")) found_source = true;
    }
    try testing.expect(found_source);
}

test "issue-450: prefix tier respects max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "const abcx = 1;\n");
    try explorer.indexFile("b.zig", "const abcy = 1;\n");
    try explorer.indexFile("c.zig", "const zzabczz = 1;\n");

    const results = try explorer.searchContent("abc", testing.allocator, 2);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len <= 2);
}

test "issue-208: content cache evicts cold entries under pressure" {
    const ContentCache = @import("../hot_cache.zig").ContentCache;
    const cap = 50;
    var cache = try ContentCache.initAlloc(testing.allocator, cap);
    defer cache.deinit();

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // Insert 100 keys into a cache with capacity 50.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }

    // Cache must not exceed capacity.
    try testing.expect(cache.len() <= cap);

    // Touch keys 0..10 to mark them hot (set ref bit).
    i = 0;
    while (i < 10) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        _ = cache.get(k);
    }

    // Insert 20 more keys to trigger further eviction.
    i = 100;
    while (i < 120) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }

    // Still bounded by capacity.
    try testing.expect(cache.len() <= cap);

    // Evictions must have fired.
    const s = cache.stats();
    try testing.expect(s.evictions > 0);
}

test "deps: DI registration generic args create type-usage edges" {
    // `services.AddTransient<IReportStorageService, ReportAzureStorageService>()`
    // in Startup.cs is a hard compile-time dependency on both type args, but
    // lives in a method body — return/param type extraction never sees it.
    // Renaming the interface with codedb's blast radius then misses the DI
    // registration and the build breaks.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("Services/IStorageService.cs",
        \\namespace M {
        \\    public interface IReportStorageService
        \\    {
        \\        void Save();
        \\    }
        \\}
        \\
    );
    try explorer.indexFile("Startup.cs",
        \\namespace M {
        \\    public class Startup
        \\    {
        \\        public void ConfigureServices(IServiceCollection services)
        \\        {
        \\            services.AddTransient<IReportStorageService, ReportAzureStorageService>();
        \\        }
        \\    }
        \\}
        \\
    );

    explorer.mu.lockShared();
    const fwd_opt = explorer.dep_graph.getForwardDeps("Startup.cs");
    explorer.mu.unlockShared();
    try testing.expect(fwd_opt != null);
    var found = false;
    for (fwd_opt.?) |dep| {
        if (std.mem.eql(u8, dep, "Services/IStorageService.cs")) found = true;
    }
    try testing.expect(found);
}

test "deps: razor @model and generic helper args create edges to the model's file" {
    // A .cshtml view whose only link to its viewmodel is `@model Ns.Type` (or a
    // `Html.Kendo().Form<Ns.Type>()` helper call) breaks at runtime when the
    // type is renamed — the dependency graph must include the view in the
    // model file's blast radius.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("Models/ViewModels.cs",
        \\namespace M.Models {
        \\    public class ModelSessionViewModel
        \\    {
        \\        public int Id { get; set; }
        \\    }
        \\}
        \\
    );
    try explorer.indexFile("Views/ModelSessions/Index.cshtml",
        \\@model M.Models.ModelSessionViewModel
        \\<div>hi</div>
        \\
    );
    try explorer.indexFile("Views/ModelSessions/Balance.cshtml",
        \\@using Kendo.Mvc.UI
        \\<div>
        \\@(Html.Kendo().Form<M.Models.ModelSessionViewModel>()
        \\    .Name("f"))
        \\</div>
        \\
    );

    explorer.mu.lockShared();
    const model_view = explorer.dep_graph.getForwardDeps("Views/ModelSessions/Index.cshtml");
    const form_view = explorer.dep_graph.getForwardDeps("Views/ModelSessions/Balance.cshtml");
    explorer.mu.unlockShared();

    try testing.expect(model_view != null);
    var found_model = false;
    for (model_view.?) |dep| {
        if (std.mem.eql(u8, dep, "Models/ViewModels.cs")) found_model = true;
    }
    try testing.expect(found_model);

    try testing.expect(form_view != null);
    var found_form = false;
    for (form_view.?) |dep| {
        if (std.mem.eql(u8, dep, "Models/ViewModels.cs")) found_form = true;
    }
    try testing.expect(found_form);
}

test "callers references: @model-only razor view is reported as a reference" {
    // 5 of 12 views referencing ModelSessionViewModel in a real project were
    // dropped because their only reference is the `@model` directive — content
    // search crowded them out and the structural set had no razor edges.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    try explorer.indexFile("Models/ViewModels.cs",
        \\namespace M.Models {
        \\    public class ModelSessionViewModel
        \\    {
        \\        public int Id { get; set; }
        \\    }
        \\}
        \\
    );
    try explorer.indexFile("Views/ModelSessions/Index.cshtml",
        \\@model M.Models.ModelSessionViewModel
        \\<div>hi</div>
        \\
    );

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"name":"ModelSessionViewModel","match_mode":"references"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "Views/ModelSessions/Index.cshtml:1") != null);
}

test "issue-bug5: search under max_results returns all matches despite tier per-file caps" {
    // 9 whole-word hits across 5 files with max_results=10: the tier-0
    // per-file cap (max_results/5 = 2) silently dropped the 3rd hit in the
    // dense files even though the budget had room. "8 results" with no
    // truncation marker reads as complete when it is not — under-budget
    // searches must return every match.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("a.zig",
        \\fn target_token_use1() void { target_token(); }
        \\const target_token_a = 1;
        \\var target_token_b = 2;
    );
    try explorer.indexFile("b.zig",
        \\fn target_token_use2() void { target_token(); }
        \\const target_token_c = 1;
        \\var target_token_d = 2;
    );
    try explorer.indexFile("c.zig", "fn target_token() void {}");
    try explorer.indexFile("d.zig", "const x = target_token;");
    try explorer.indexFile("e.zig", "const y = target_token;");

    const results = try explorer.searchContent("target_token", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 9), results.len);
}

test "issue-bug6: config_xref parses excluded appsettings keys on demand, values never leak" {
    // appsettings*.json is excluded from the index by security policy, so
    // config_xref used to report definitions: 0 and flag every read as
    // missing_definitions — misleading. The tool must parse KEY PATHS on
    // demand from disk (values must never appear in output).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const root = path_buf[0..root_len];

    // ASP.NET appsettings files routinely carry JSONC line comments — the
    // on-demand parser must tolerate them (std.json alone rejects the file).
    try tmp.dir.writeFile(io, .{ .sub_path = "appsettings.json", .data =
    \\{
    \\  "KeyVault": {
    \\    //MenuItemId=112 comment like real-world appsettings
    \\    "DirectoryId": "SECRETVALUE123",
    \\    "ClientSecret": "SECRETVALUE456"
    \\  }
    \\}
    });

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    try explorer.indexFile("Program.cs",
        \\namespace M {
        \\    public class Program
        \\    {
        \\        public void Setup(IConfiguration Configuration)
        \\        {
        \\            var id = Configuration["KeyVault:DirectoryId"];
        \\        }
        \\    }
        \\}
        \\
    );

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, root);
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_config_xref, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "definitions: 2") != null);
    // The read is defined — it must not be flagged missing.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing_definitions:\n    (none)") != null);
    // Values from the excluded file must never appear anywhere in output.
    try testing.expect(std.mem.indexOf(u8, out.items, "SECRETVALUE123") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "SECRETVALUE456") == null);
}
