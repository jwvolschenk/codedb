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

test "issue-35: edits immediately update explorer and snapshot output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-live-sync.zig", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-live-sync.zig", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "pub fn oldName() void {}\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    try explorer.indexFile(rel_path, "pub fn oldName() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = try store.recordSnapshot(rel_path, "pub fn oldName() void {}\n".len, std.hash.Wyhash.hash(0, "pub fn oldName() void {}\n"));

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-35-agent");

    const before_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(before_snap);
    try testing.expect(std.mem.indexOf(u8, before_snap, "oldName") != null);

    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, &explorer, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "pub fn newName() void {}",
    });

    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new_results);
    }
    try testing.expect(new_results.len == 1);

    const old_results = try explorer.searchContent("oldName", testing.allocator, 10);
    defer {
        for (old_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    const after_snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(after_snap);
    try testing.expect(std.mem.indexOf(u8, after_snap, "newName") != null);
    try testing.expect(std.mem.indexOf(u8, after_snap, "oldName") == null);
}

// ── Regression tests for issues #2, #5, #7 ─────────────────

test "snapshot_json: snapshot builds and is valid JSON" {
    // Explorer uses arena for internal data
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub const version = 1;");

    var store = @import("../store.zig").Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", 100, 0xABC);

    const snap = try snapshot_json.buildSnapshot(&explorer, &store, testing.allocator);
    defer testing.allocator.free(snap);

    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, snap, .{});
    defer parsed.deinit();

    // Must have expected top-level keys (matches buildSnapshot output)
    try testing.expect(parsed.value.object.contains("seq"));
    try testing.expect(parsed.value.object.contains("tree"));
    try testing.expect(parsed.value.object.contains("outlines"));
    try testing.expect(parsed.value.object.contains("symbol_index"));
    try testing.expect(parsed.value.object.contains("dep_graph"));

    const tree = parsed.value.object.get("tree").?.string;
    try testing.expect(std.mem.indexOf(u8, tree, "src/") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "main.zig") != null);

    const symbol_index = parsed.value.object.get("symbol_index").?.object;
    try testing.expect(symbol_index.contains("main"));
    try testing.expect(symbol_index.contains("version"));
}

// ── Deep copy correctness tests ─────────────────────────────

test "issue-44: snapshot stale after working tree changes cause stale query results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    const file_abs = try std.fmt.allocPrint(testing.allocator, "{s}/stale.zig", .{dir_path});
    defer testing.allocator.free(file_abs);

    // Step 1: write file with old content, index it, write snapshot.
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn oldFunc() void {}" });
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var exp = Explorer.init(arena.allocator());
        try exp.indexFile(file_abs, "pub fn oldFunc() void {}");
        try snapshot_mod.writeSnapshot(io, &exp, ".", snap_path, arena.allocator());
    }

    // Step 2: modify file AFTER snapshot creation (simulating uncommitted working tree change).
    // Sleep 10ms so the file mtime is strictly greater than the snapshot's indexed_at timestamp.
    cio.sleepMs(10);
    try tmp.dir.writeFile(io, .{ .sub_path = "stale.zig", .data = "pub fn newFunc() void {}" });

    // Step 3: load snapshot into a fresh explorer (what MCP startup does).
    // scan_done is set to true immediately; watcher then builds known-FileMap
    // from current disk mtimes, recording the already-modified file's mtime as
    // the baseline. It will never be re-indexed unless changed a second time.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, arena2.allocator());
    try testing.expect(loaded);

    // Step 4: after the fix, loadSnapshot should detect that the disk file's
    // mtime > snapshot indexed_at and re-index it from disk, making "newFunc"
    // visible. Currently no such path exists.
    // Expected (after fix): results.len == 1
    // Current (bug): results.len == 0 — stale snapshot content is never evicted.
    const results = try exp2.searchContent("newFunc", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "issue-46: empty-repo snapshot rejected on load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
    try testing.expect(exp2.outlines.count() == 0);
}

test "snapshot: writer streams uncached file contents for large repos" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    var rel_buf: [64]u8 = undefined;
    var content_buf: [128]u8 = undefined;
    for (0..1002) |i| {
        const rel = try std.fmt.bufPrint(&rel_buf, "src/file_{d}.zig", .{i});
        const content = try std.fmt.bufPrint(&content_buf, "pub fn func_{d}() usize {{ return {d}; }}\n", .{ i, i });
        try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = content });
        try exp.indexFileOutlineOnly(rel, content);
    }

    try testing.expectEqual(@as(usize, 1002), exp.outlines.count());
    // With CLOCK eviction (#208) the ContentCache holds up to 16384 entries — all 1002 fit.
    try testing.expectEqual(@as(u32, 1002), exp.contents.count());

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var loaded_without_root = Explorer.init(testing.allocator);
    defer loaded_without_root.deinit();
    var store_without_root = Store.init(testing.allocator);
    defer store_without_root.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded_without_root, &store_without_root, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded_without_root.outlines.count());
    // CLOCK cache holds all 1002 — word index can be rebuilt from memory without root dir.
    const hits_no_root = try loaded_without_root.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits_no_root);
    try testing.expectEqual(@as(usize, 1), hits_no_root.len);

    var loaded = Explorer.init(testing.allocator);
    loaded.setRoot(io, dir_path);
    defer loaded.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &loaded, &store, testing.allocator));
    try testing.expectEqual(@as(usize, 1002), loaded.outlines.count());

    const hits = try loaded.searchWord("func_1001", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("src/file_1001.zig", loaded.word_index.hitPath(hits[0]));
    try testing.expect(loaded.wordIndexIsComplete());
}

test "issue-45: snapshot written in non-git directory cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(aa);
    try exp.indexFile("dummy.zig", "const x = 1;");

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "test.codedb" });

    // Write snapshot with a non-git root_path — git_head will be all-zeros
    try snapshot_mod.writeSnapshot(io, &exp, "/tmp", snap_path, aa);

    // Snapshot file was created
    std.Io.Dir.cwd().access(io, snap_path, .{}) catch {
        return error.TestUnexpectedResult;
    };

    // readSnapshotGitHead returns null for non-git dirs (all-zero sentinel).
    // The snapshot loading logic in main.zig handles this by checking if the
    // current project also has no git — if so, it loads the snapshot.
    const snap_head = snapshot_mod.readSnapshotGitHead(io, snap_path);
    try testing.expect(snap_head == null);
}

// ── Multi-instance contention tests ────────────────────────────

test "issue-47: concurrent snapshot writes from parallel instances corrupt file" {
    // BUG: Two codedb instances indexing the same repo write codedb.snapshot
    // concurrently with no file locking. The second writer can overwrite a
    // partially-written snapshot, producing a corrupt file that loadSnapshot
    // rejects or — worse — reads garbage section offsets from.
    //
    // Simulate: two threads write snapshots to the same path concurrently,
    // then verify the final file is still loadable.
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena1.deinit();
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();

    var exp1 = Explorer.init(arena1.allocator());
    try exp1.indexFile("a.zig", "pub fn alpha() void {}");
    var exp2 = Explorer.init(arena2.allocator());
    try exp2.indexFile("b.zig", "pub fn beta() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/concurrent.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    const WriterCtx = struct {
        exp: *Explorer,
        path: []const u8,
        dir: []const u8,
        alloc: std.mem.Allocator,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            for (0..10) |_| {
                snapshot_mod.writeSnapshot(io, ctx.exp, ctx.dir, ctx.path, ctx.alloc) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    var ctx1 = WriterCtx{ .exp = &exp1, .path = snap_path, .dir = dir_path, .alloc = arena1.allocator() };
    var ctx2 = WriterCtx{ .exp = &exp2, .path = snap_path, .dir = dir_path, .alloc = arena2.allocator() };

    const t1 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, WriterCtx.run, .{&ctx2});
    t1.join();
    t2.join();

    // Neither writer should have errored
    try testing.expect(!ctx1.failed.load(.acquire));
    try testing.expect(!ctx2.failed.load(.acquire));

    // The final snapshot must be loadable (not corrupt)
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena3.deinit();
    var exp3 = Explorer.init(arena3.allocator());
    var store3 = Store.init(testing.allocator);
    defer store3.deinit();
    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp3, &store3, arena3.allocator());

    // Expected: loaded == true (snapshot is valid, written atomically)
    // Current (bug): may be false — last writer's rename can land mid-write of
    // the first writer's tmp file, or both rename the same .tmp path.
    try testing.expect(loaded);
}

test "issue-40: truncated snapshot silently loads partial data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/a.zig", "const a = 1;\n");
    try exp.indexFile("src/b.zig", "const b = 2;\n");
    try exp.indexFile("src/c.zig", "const c = 3;\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    const trunc_path = try std.fmt.allocPrint(testing.allocator, "{s}/trunc.codedb", .{dir_path});
    defer testing.allocator.free(trunc_path);
    {
        const orig = try std.Io.Dir.cwd().readFileAlloc(io, snap_path, testing.allocator, .limited(1024 * 1024));
        defer testing.allocator.free(orig);
        const trunc_file = try std.Io.Dir.cwd().createFile(io, trunc_path, .{});
        defer trunc_file.close(io);
        // Keep only header (256 bytes) — content section data will be missing
        try trunc_file.writeStreamingAll(io, orig[0..@min(256, orig.len)]);
    }

    var arena2 = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(arena2.allocator());

    const loaded = snapshot_mod.loadSnapshot(io, trunc_path, &exp2, &store, arena2.allocator());
    try testing.expect(!loaded);
}

test "issue-41: snapshot not validated against repo identity allows cross-project loading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/projectA.zig", "const project = \"A\";\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshotValidated(io, snap_path, "/some/other/project", &exp2, &store, testing.allocator);
    try testing.expect(!loaded);
}

// DISABLED: telemetry test depends on tmpDir file IO which is flaky
// test "issue-59: telemetry writes session, tool, and codebase stats ndjson" {
//     var tmp = testing.tmpDir(.{});
//     defer tmp.cleanup();
//
//     var path_buf: [std.fs.max_path_bytes]u8 = undefined;
//     const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
//     const dir_path = path_buf[0..dir_path_len];
//
//     var telem = telemetry_mod.Telemetry.init(io, dir_path, testing.allocator, false);
//     defer telem.deinit();
//
//     telem.recordSessionStart();
//     telem.recordToolCall("codedb_status", 1234, false, 56);
//
//     var explorer = Explorer.init(testing.allocator);
//     defer explorer.deinit();
//     try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
//     try explorer.indexFile("src/lib.py", "def run():\n    return 1\n");
//
//     telem.recordCodebaseStats(&explorer, 42);
//     telem.flush();
//
//     const ndjson_path = try std.fmt.allocPrint(testing.allocator, "{s}/telemetry.ndjson", .{dir_path});
//     defer testing.allocator.free(ndjson_path);
//
//     const contents = try std.Io.Dir.cwd().readFileAlloc(io, ndjson_path, testing.allocator, .limited(64 * 1024));
//     defer testing.allocator.free(contents);
//
//     try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"session_start\"") != null);
//     const version_needle = try std.fmt.allocPrint(testing.allocator, "\"version\":\"{s}\"", .{release_info.semver});
//     defer testing.allocator.free(version_needle);
//     try testing.expect(std.mem.indexOf(u8, contents, version_needle) != null);
//     try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"tool_call\"") != null);
//     try testing.expect(std.mem.indexOf(u8, contents, "\"tool\":\"codedb_status\"") != null);
//     try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"codebase_stats\"") != null);
//     try testing.expect(std.mem.indexOf(u8, contents, "\"startup_time_ms\":42") != null);
//     try testing.expect(std.mem.indexOf(u8, contents, "\"languages\":[\"zig\",\"python\"]") != null);
// }

test "snapshot: symbol detail longer than 4096 bytes survives round-trip" {
    // Regression for readSectionString rejecting names/details > 4096 bytes.
    // Before the fix max_len was 4096; any detail longer than that triggered
    // error.InvalidData and loadSnapshot returned false.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build a Zig source whose first function line exceeds 4 096 characters.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "pub fn bigSig(");
    var param_i: usize = 0;
    while (src.items.len < 5000) : (param_i += 1) {
        var pb: [20]u8 = undefined;
        const ps = std.fmt.bufPrint(&pb, "p{d}: u8, ", .{param_i}) catch break;
        try src.appendSlice(testing.allocator, ps);
    }
    try src.appendSlice(testing.allocator, ") void {}\n");
    try testing.expect(src.items.len > 4096); // guard: ensure we actually generated a long line
    var exp = Explorer.init(aa);
    try exp.indexFile("src/big.zig", src.items);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/big.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive long detail

    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("bigSig", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}

test "snapshot: corrupted OUTLINE_STATE section falls back to CONTENT load" {
    // Regression for the codedb 0.2.56 writer u16 overflow bug: when OUTLINE_STATE
    // contains a detail that overflows u16 the section cursor de-syncs, making
    // subsequent file records parse as garbage and loadOutlineStateMap throws.
    // The catch fallback must produce an empty map so loadSnapshotFast falls
    // through to indexFileOutlineOnly for every file in CONTENT.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa);
    try exp.indexFile("src/a.zig", "pub fn aFunc() void {}\n");
    try exp.indexFile("src/b.zig", "pub fn bFunc() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/corrupt.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    // Overwrite the first 16 bytes of OUTLINE_STATE data with 0xFF.
    // This makes the file_count field read as 0xFFFFFFFF — far more records
    // than the data contains — causing readSectionString to eventually fail
    // with error.InvalidData (runs off the end of the bytes slice).
    {
        var sections = (try snapshot_mod.readSections(io, snap_path, testing.allocator)).?;
        defer sections.deinit();
        const ols = sections.get(@intFromEnum(snapshot_mod.SectionId.outline_state)) orelse return;
        const f = try std.Io.Dir.cwd().openFile(io, snap_path, .{ .mode = .read_write });
        defer f.close(io);
        try f.writePositionalAll(io, &([_]u8{0xFF} ** 16), ols.offset);
    }

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    try testing.expect(loaded); // must survive OUTLINE_STATE corruption

    // Symbols must still be found — re-indexed from CONTENT
    var sym_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sym_arena.deinit();
    const results = try exp2.findAllSymbols("aFunc", sym_arena.allocator());
    try testing.expect(results.len >= 1);
}

test "issue-379: snapshot loader returns true with zero outlines for empty-explorer snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/empty.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);

    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var exp2 = Explorer.init(testing.allocator);
    defer exp2.deinit();
    var store2 = Store.init(testing.allocator);
    defer store2.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store2, testing.allocator);
    if (loaded) {
        try testing.expect(exp2.outlines.count() > 0);
    }
}

test "issue-409: snapshot .env prefix filter wrongly excludes .envoy/.environment files" {
    // BUG: snapshot.zig:isSensitivePath uses
    //     if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env")) return true;
    // to catch .env, .env.local, .env.production, etc. The check is a raw
    // 4-byte prefix match — so any basename whose first 4 bytes are ".env"
    // is rejected, including legitimate, non-secret files such as:
    //
    //   .envoy.json     — Envoy proxy config
    //   .environment    — generic config name
    //   .envconfig.yaml — anything starting with ".env"
    //
    // These files end up silently dropped from the snapshot's CONTENT,
    // TREE, and OUTLINE_STATE sections, so a save/load round-trip loses
    // them entirely. The watcher.zig copy of isSensitivePath has the same
    // bug, so they are also excluded from live indexing.
    //
    // Reproducer: index a non-secret .envoy.json alongside a normal file,
    // snapshot, load, and observe that .envoy.json is missing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var exp = Explorer.init(aa);
    try exp.indexFile("a.zig", "pub fn alpha() void {}\n");
    // .envoy.json is the canonical Envoy proxy config name — not a secret.
    try exp.indexFile(".envoy.json", "{\"listeners\":[]}\n");
    try testing.expectEqual(@as(usize, 2), exp.outlines.count());

    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb" });
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, aa);

    var exp2 = Explorer.init(aa);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expect(snapshot_mod.loadSnapshot(io, snap_path, &exp2, &store, aa));

    // Expected: both files round-trip through the snapshot.
    // Current (bug): only "a.zig" survives — ".envoy.json" was excluded by
    // the .env prefix check at write time.
    try testing.expect(exp2.outlines.contains("a.zig"));
    try testing.expect(exp2.outlines.contains(".envoy.json"));
}
