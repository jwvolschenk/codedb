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

test "trigram index: index and candidate lookup" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("src/store.zig", "pub fn recordSnapshot(self: *Store) void {}");
    try ti.indexFile("src/agent.zig", "pub fn register(self: *Agent) void {}");

    const cands = ti.candidates("recordSnapshot", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 1);
    try testing.expectEqualStrings("src/store.zig", cands.?[0]);
}

test "trigram index: short query returns null" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("hi", testing.allocator);
    try testing.expect(cands == null);
}

test "trigram index: no match returns empty" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "hello world");
    const cands = ti.candidates("zzzzz", testing.allocator);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len == 0);
}

test "trigram index: re-index removes old trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("f.zig", "uniqueOldContent");
    const c1 = ti.candidates("uniqueOld", testing.allocator);
    defer if (c1) |c| testing.allocator.free(c);
    try testing.expect(c1 != null and c1.?.len == 1);

    try ti.indexFile("f.zig", "brandNewStuff");
    const c2 = ti.candidates("uniqueOld", testing.allocator);
    defer if (c2) |c| testing.allocator.free(c);
    try testing.expect(c2 != null and c2.?.len == 0);

    const c3 = ti.candidates("brandNew", testing.allocator);
    defer if (c3) |c| testing.allocator.free(c);
    try testing.expect(c3 != null and c3.?.len == 1);
}

// ── Sparse N-gram tests ─────────────────────────────────────

test "explorer: searchContent with trigram acceleration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("store.zig", "pub fn recordSnapshot(self: *Store) void {}\npub fn init() void {}");
    try explorer.indexFile("agent.zig", "pub fn register(self: *Agent) void {}");

    const results = try explorer.searchContent("recordSnapshot", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("store.zig", results[0].path);
    try testing.expect(results[0].line_num == 1);
}

test "regression #2: searchContent frees trigram candidate slice" {
    // Verifies that the candidates() return value is freed by searchContent.
    // If the defer is missing, the GPA will detect the leak and fail.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("leak-check.zig", "pub fn recordSnapshot(self: *Store) void {}\npub fn init() void {}");
    try explorer.indexFile("other.zig", "pub fn register(self: *Agent) void {}");

    const results = try explorer.searchContent("recordSnapshot", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("leak-check.zig", results[0].path);
}

test "regression #2: searchContent short query skips trigrams" {
    // Queries < 3 chars can't use trigram index — ensure no leak from null path.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("short.zig", "fn ab() void {}");

    const results = try explorer.searchContent("ab", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "regression: searchContent frees empty trigram candidate slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("f.zig", "hello world");

    const results = try explorer.searchContent("zzzzz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 0);
}

test "trigram index: removeFile prunes empty sets" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("only.zig", "xyzUniqueTrigramContent");
    const before = ti.candidates("xyzUniqueTrigramContent", testing.allocator);
    if (before) |b| {
        try testing.expect(b.len > 0);
        testing.allocator.free(b);
    }

    ti.removeFile("only.zig");
    const after = ti.candidates("xyzUniqueTrigramContent", testing.allocator);
    if (after) |a| {
        try testing.expect(a.len == 0);
        testing.allocator.free(a);
    }
}

// ── Atomic edit test ────────────────────────────────────────

test "decomposeRegex: pure literal extracts trigrams" {
    var q = try decomposeRegex("hello", testing.allocator);
    defer q.deinit();
    // "hello" has 3 trigrams: hel, ell, llo
    try testing.expectEqual(@as(usize, 3), q.and_trigrams.len);
    try testing.expectEqual(@as(usize, 0), q.or_groups.len);
}

test "decomposeRegex: short literal yields no trigrams" {
    var q = try decomposeRegex("ab", testing.allocator);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}

test "decomposeRegex: dot breaks trigram chain" {
    var q = try decomposeRegex("he.lo", testing.allocator);
    defer q.deinit();
    // "he" then "lo" — neither long enough for trigrams
    try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
}

test "candidatesRegex: finds files with AND trigrams" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("foo.zig", "pub fn recordSnapshot() void {}");
    try ti.indexFile("bar.zig", "const x = 42;");

    var q = try decomposeRegex("record.*Snapshot", testing.allocator);
    defer q.deinit();
    // Should extract trigrams from "record" and "Snapshot"
    try testing.expect(q.and_trigrams.len > 0);

    const cands = ti.candidatesRegex(&q, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);
    try testing.expect(cands.?.len >= 1);
    // foo.zig should be a candidate
    var found_foo = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "foo.zig")) found_foo = true;
    }
    try testing.expect(found_foo);
}

test "bloom: reduces candidates vs pure trigram intersection" {
    // This is the key test: prove bloom filtering actually eliminates
    // files that trigram intersection alone would not.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "pub fn init" — common trigrams "pub", "ub ", "b f", " fn", "fn ", "n i", " in", "ini", "nit"
    // We'll create files that share many of these trigrams but NOT adjacently.
    try ti.indexFile("real.zig", "pub fn init() void {}"); // actual match
    try ti.indexFile("shuffled1.zig", "fn publish(nit_pick: bool) void {}"); // has "pub","fn ","nit" but not adjacently
    try ti.indexFile("shuffled2.zig", "fn pubNitInit() void {}"); // has "pub","nit","ini" but wrong order
    try ti.indexFile("unrelated.zig", "const x = 42;"); // no overlap

    const cands = ti.candidates("pub fn init", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // real.zig MUST be found (soundness)
    var found_real = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "real.zig")) found_real = true;
    }
    try testing.expect(found_real);

    // unrelated.zig must NOT be found
    var found_unrelated = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "unrelated.zig")) found_unrelated = true;
    }
    try testing.expect(!found_unrelated);

    // Count how many candidates we got — should be fewer than all files
    // that share trigrams. At minimum, "unrelated.zig" is excluded.
    try testing.expect(cands.?.len < 4);
}

test "regex regression: trigram extraction counts" {
    // Verify exact trigram counts for known patterns.
    // If decomposition logic changes, these catch it.
    {
        var q = try decomposeRegex("handleRequest", testing.allocator);
        defer q.deinit();
        // 13 chars → 11 trigrams, all AND
        try testing.expectEqual(@as(usize, 11), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 0), q.or_groups.len);
    }
    {
        var q = try decomposeRegex("foo.*bar.*baz", testing.allocator);
        defer q.deinit();
        // "foo", "bar", "baz" — each 3 chars = 1 trigram each = 3 AND trigrams
        try testing.expectEqual(@as(usize, 3), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 0), q.or_groups.len);
    }
    {
        var q = try decomposeRegex("alpha|beta|gamma", testing.allocator);
        defer q.deinit();
        // No AND trigrams — all in OR groups
        try testing.expectEqual(@as(usize, 0), q.and_trigrams.len);
        try testing.expectEqual(@as(usize, 1), q.or_groups.len);
        // alpha=3 + beta=2 + gamma=3 = 8 trigrams in the OR group
        try testing.expectEqual(@as(usize, 8), q.or_groups[0].len);
    }
}

test "thread-safe: concurrent TrigramIndex.candidates() with per-thread allocators" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();
    try ti.indexFile("a.zig", "pub fn handleRequest(ctx: *Context) void {}");
    try ti.indexFile("b.zig", "pub fn processData(buf: []u8) void {}");
    try ti.indexFile("c.zig", "pub fn handleRequest(req: Request) !void {}");
    const ThreadCtx = struct {
        ti: *TrigramIndex,
        errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn run(ctx: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            for (0..200) |_| {
                const cands = ctx.ti.candidates("handleRequest", alloc) orelse continue;
                defer alloc.free(cands);
                var found = false;
                for (cands) |p| {
                    if (std.mem.eql(u8, p, "a.zig") or std.mem.eql(u8, p, "c.zig")) found = true;
                }
                if (!found) _ = ctx.errors.fetchAdd(1, .monotonic);
            }
        }
    };
    var ctx = ThreadCtx{ .ti = &ti };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctx});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), ctx.errors.load(.monotonic));
}

test "issue-43: trigram_index swap in scanBg races with concurrent MCP queries" {
    // Regression: the scanBg disk-load path must serialize trigram_index swaps
    // with readers by taking exp.mu.lock() before replacing the index.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("a.zig", "pub fn handleAuth(token: []const u8) bool { return token.len > 0; }");

    exp.mu.lockShared();

    const SwapCtx = struct {
        exp: *Explorer,
        swapped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(ctx: *@This()) void {
            ctx.exp.mu.lock();
            defer ctx.exp.mu.unlock();
            ctx.exp.trigram_index.deinit();
            ctx.exp.trigram_index = .{ .heap = TrigramIndex.init(ctx.exp.allocator) };
            ctx.swapped.store(true, .release);
        }
    };
    var sctx = SwapCtx{ .exp = &exp };
    const t = try std.Thread.spawn(.{}, SwapCtx.run, .{&sctx});
    cio.sleepMs(10);
    const raced = sctx.swapped.load(.acquire);
    exp.mu.unlockShared();
    t.join();
    try testing.expect(!raced);
}

test "issue-105: large files skip trigram indexing to prevent OOM" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Create content just over 64KB — should be indexed for outline/word but NOT trigram
    const large_content = try testing.allocator.alloc(u8, 65 * 1024);
    defer testing.allocator.free(large_content);
    @memset(large_content, 'a');
    // Make it valid Zig so outline parsing works
    @memcpy(large_content[0..21], "pub fn bigFunc() void");

    // indexFileSkipTrigram should succeed without building trigrams
    try explorer.indexFileSkipTrigram("large.zig", large_content);

    // The file should be in outlines and contents but NOT in the trigram index
    try testing.expect(explorer.outlines.count() == 1);
    try testing.expect(explorer.contents.count() == 1);
    try testing.expect(explorer.trigram_index.fileCount() == 0);

    // A small file should still get trigram-indexed
    try explorer.indexFile("small.zig", "pub fn tiny() void {}");
    try testing.expect(explorer.trigram_index.fileCount() == 1);
}

// ── PHP parser tests ─────────────────────────────────────────────

test "regression-142: trigram index finds all matching files" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("src/main.zig", "pub fn handleRequest(ctx: *Context) !void {}");
    try exp.indexFile("src/server.zig", "fn handleRequest(req: Request) void {}");
    try exp.indexFile("src/util.zig", "pub fn formatDate() []u8 {}");

    const results = try exp.searchContent("handleRequest", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Must find both files containing "handleRequest"
    try testing.expect(results.len == 2);
}

test "regression-142: trigram index returns no false positives" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("a.zig", "pub fn alpha() void {}");
    try exp.indexFile("b.zig", "pub fn beta() void {}");

    const results = try exp.searchContent("gamma", testing.allocator, 50);
    defer testing.allocator.free(results);
    // Must return zero results for non-existent content
    try testing.expect(results.len == 0);
}

test "regression-142: trigram intersection narrows correctly" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("match.zig", "const unique_identifier_xyz = 42;");
    try exp.indexFile("partial.zig", "const unique_other = 99;");
    try exp.indexFile("none.zig", "pub fn foo() void {}");

    const results = try exp.searchContent("unique_identifier_xyz", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Only the exact match file, not the partial
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("match.zig", results[0].path);
}

test "regression-142: trigram handles file removal" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("temp.zig", "pub fn removable() void {}");
    try exp.indexFile("keep.zig", "pub fn permanent() void {}");

    // Remove a file
    exp.removeFile("temp.zig");

    const results = try exp.searchContent("removable", testing.allocator, 50);
    defer testing.allocator.free(results);
    try testing.expect(results.len == 0);

    const results2 = try exp.searchContent("permanent", testing.allocator, 50);
    defer {
        for (results2) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results2);
    }
    try testing.expect(results2.len == 1);
}

test "regression-142: trigram handles re-indexing same file" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("mutable.zig", "pub fn oldContent() void {}");
    try exp.indexFile("mutable.zig", "pub fn newContent() void {}");

    const old = try exp.searchContent("oldContent", testing.allocator, 50);
    defer testing.allocator.free(old);
    try testing.expect(old.len == 0);

    const new = try exp.searchContent("newContent", testing.allocator, 50);
    defer {
        for (new) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new);
    }
    try testing.expect(new.len == 1);
}

test "regression-142: trigram disk roundtrip preserves results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Build index
    var idx1 = TrigramIndex.init(testing.allocator);
    try idx1.indexFile("a.zig", "pub fn searchable() void {}");
    try idx1.indexFile("b.zig", "const value = 42;");

    // Write to disk
    try idx1.writeToDisk(io, dir_path, null);
    idx1.deinit();

    // Read back
    var idx2 = TrigramIndex.readFromDisk(io, dir_path, testing.allocator) orelse return error.TestUnexpectedResult;
    defer idx2.deinit();

    // Must find same results
    const cands = idx2.candidates("searchable", testing.allocator) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(cands);
    try testing.expect(cands.len == 1);
}

test "issue-164: mmap trigram index returns same candidates as heap index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.zig", "pub fn handleAuth(req: *Request) !void { validate(req); }");
    try explorer.indexFile("src/gate.zig", "pub fn checkGate(ctx: *Context) !bool { return ctx.authenticated; }");
    try explorer.indexFile("src/util.zig", "pub fn formatStr(buf: []u8, args: anytype) !void {}");

    const heap_results = explorer.trigram_index.candidates("handleAuth", allocator) orelse
        return error.NoCandidates;

    try testing.expect(heap_results.len >= 1);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    var mmap_idx = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    defer mmap_idx.deinit();

    const mmap_results = mmap_idx.candidates("handleAuth", allocator) orelse
        return error.NoCandidates;

    try testing.expect(mmap_results.len >= 1);
    try testing.expectEqual(heap_results.len, mmap_results.len);
    try testing.expectEqual(explorer.trigram_index.fileCount(), mmap_idx.fileCount());
    try testing.expect(mmap_idx.containsFile("src/auth.zig"));
    try testing.expect(mmap_idx.containsFile("src/gate.zig"));
    try testing.expect(!mmap_idx.containsFile("nonexistent.zig"));
}

test "issue-246: TrigramIndex.removeFile cleans stale path_to_id left by failed indexFile" {
    // Reproduces the corrupted state an OOM mid-way through indexFile leaves:
    //   removeFile cleared file_trigrams, getOrCreateDocId wrote to path_to_id,
    //   then an allocation failure meant file_trigrams.put never completed.
    // Fix: removeFile must purge path_to_id even when file_trigrams has no entry.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    // Plant the invariant-violating state OOM would leave behind.
    try idx.path_to_id.put("ghost.zig", 0);
    try idx.id_to_path.append(testing.allocator, "ghost.zig");
    // file_trigrams intentionally has NO entry for "ghost.zig".

    idx.removeFile("ghost.zig");

    // Currently FAILS: removeFile returns early at the second file_trigrams.getPtr
    // check, leaving path_to_id permanently dirty.
    try testing.expectEqual(@as(usize, 0), idx.path_to_id.count());
}

test "issue-247: TrigramIndex.id_to_path does not grow on re-index of same file" {
    // removeFile removes path_to_id[path] but leaves the id_to_path slot intact.
    // getOrCreateDocId then appends a new slot since path_to_id misses.
    // After N re-indexes id_to_path.items.len must equal the number of *unique* files.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    const src = "fn alpha() void {} fn beta() void {} const X = 1;";
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try idx.indexFile("f.zig", src);
    }

    // Currently FAILS: id_to_path.items.len == 5 (grows by 1 per re-index).
    try testing.expectEqual(@as(usize, 1), idx.id_to_path.items.len);
}

test "issue-227: TrigramIndex.id_to_path stays bounded across many files re-indexed" {
    // Broader regression: ensure re-indexing multiple distinct files also doesn't
    // accumulate dead id_to_path slots.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();

    const files = [_][]const u8{ "a.zig", "b.zig", "c.zig" };
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        for (files) |f| try idx.indexFile(f, "fn foo() void {}");
    }

    // 3 unique files × 4 rounds = 12 slots currently; fix should keep it at 3.
    try testing.expectEqual(@as(usize, files.len), idx.id_to_path.items.len);
}

test "issue-250: searchContent finds content in files skipped by trigram index" {
    // Files indexed with skip_trigram=true (e.g. past the 15k cap) must still be
    // reachable via the fallback full-scan path in searchContent.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFileSkipTrigram("large.zig", "fn unique_zzz_sentinel() void {}");

    const results = try explorer.searchContent("unique_zzz_sentinel", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
}

test "issue-262: sparse+trigram intersection drops files only in trigram index" {
    // When both sparse and trigram indices return candidates, searchContent
    // intersects them.  A file present in trigram candidates but absent from
    // sparse candidates is silently dropped — a recall loss.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Index two files — both contain the query.
    try explorer.indexFile("a.zig", "fn recall_target_alpha() void {}");
    try explorer.indexFile("b.zig", "fn recall_target_alpha() void {} // more text here for variety");

    // Simulate sparse index missing file "b.zig" (e.g. boundary misalignment).
    // File b.zig remains in the trigram index but not in sparse.
    explorer.sparse_ngram_index.removeFile("b.zig");

    const results = try explorer.searchContent("recall_target_alpha", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    // Both files contain the query — both must appear.
    try testing.expectEqual(@as(usize, 2), results.len);
}

test "issue-263: skip_trigram_files searched before max_results exhausted" {
    // Files indexed with skip_trigram=true are only searched after all
    // trigram/sparse/word paths are exhausted.  When a single normal file
    // has enough matches to fill max_results, the skip_trigram file is
    // never checked — even though it contains relevant content.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Normal file with 6 matches (one per line).
    try explorer.indexFile("noisy.zig",
        \\fn my_unique_func() void {}
        \\fn my_unique_func_v2() void {}
        \\const my_unique_func_ptr = undefined;
        \\var my_unique_func_state = 0;
        \\test "my_unique_func works" {}
        \\// calls my_unique_func internally
    );

    // skip-trigram file with 1 match.
    try explorer.indexFileSkipTrigram("large.zig", "fn my_unique_func() void {}");

    // max_results=5: the normal file fills the quota, skip_trigram never searched.
    const results = try explorer.searchContent("my_unique_func", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    // The skip_trigram file must be represented in results.
    var found_large = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "large.zig")) found_large = true;
    }
    try testing.expect(found_large);
}

test "issue-615: adoptTrigramIndex prunes skip_trigram_files the index covers" {
    // Snapshot restore parks every file in skip_trigram_files (it can't know
    // what a disk trigram index covers). Without reconciliation, tier 3
    // content-scans the ENTIRE project on each fall-through query even though
    // the loaded index already answers for those files. adoptTrigramIndex must
    // prune every skip-set entry the new index covers.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Two files land in skip_trigram_files via the skip path.
    try explorer.indexFileSkipTrigram("a.zig", "fn searchable_token_alpha() void {}");
    try explorer.indexFileSkipTrigram("b.zig", "fn searchable_token_beta() void {}");
    try testing.expect(explorer.skip_trigram_files.contains("a.zig"));
    try testing.expect(explorer.skip_trigram_files.contains("b.zig"));

    // Build a heap index that covers "a.zig" only. adoptTrigramIndex takes
    // ownership, so do NOT defer-deinit it here.
    var covered = TrigramIndex.init(testing.allocator);
    try covered.indexFile("a.zig", "fn searchable_token_alpha() void {}");
    explorer.adoptTrigramIndex(.{ .heap = covered });

    // "a.zig" is covered -> pruned. "b.zig" is not -> retained.
    try testing.expect(!explorer.skip_trigram_files.contains("a.zig"));
    try testing.expect(explorer.skip_trigram_files.contains("b.zig"));
    try testing.expect(explorer.trigram_index.containsFile("a.zig"));
}

test "issue-388: TrigramIndex.removeFile frees owned path on tombstone" {
    // owns_paths=true means getOrCreateDocId duped the path so callers can
    // free their copy. removeFile must release that dup before tombstoning
    // the slot — otherwise every snapshot-loaded session leaks one path
    // allocation per file removed/re-indexed.
    var idx = TrigramIndex.init(testing.allocator);
    defer idx.deinit();
    idx.owns_paths = true;

    const path = "src/leaky.zig";
    try idx.indexFile(path, "pub fn leaky() void {}\n");
    idx.removeFile(path);

    // testing.allocator reports any unfreed bytes when this scope exits via
    // deinit. The bug leaks the dup on the tombstoned id_to_path slot
    // (cleared to ""), so deinit's `if (p.len > 0) free(p)` misses it.
}

test "issue-451: scope search surfaces skip-trigram canonical file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "}\n";
    try explorer.indexFileSkipTrigram("canonical.zig", canonical_content);

    const results = try explorer.searchContentWithScope("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }

    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) found_canonical = true;
    }
    try testing.expect(found_canonical);
}

test "issue-447: searchContent surfaces large (>64KB) skip-trigram files for common identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "small_{d}.zig", .{i});
        try explorer.indexFile(path, "fn s() void { _ = widgetX; }\n");
    }

    const canonical_content =
        "fn canonical() void {\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "    _ = widgetX;\n" ++
        "}\n";
    try explorer.indexFileSkipTrigram("canonical.zig", canonical_content);

    const results = try explorer.searchContent("widgetX", testing.allocator, 5);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    var found_canonical = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "canonical.zig")) found_canonical = true;
    }
    try testing.expect(found_canonical);
}
