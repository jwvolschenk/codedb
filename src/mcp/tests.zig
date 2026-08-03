// Tests for mcp.zig — ProjectCache, BenchContext, SnapshotCache.
//
// Extracted from mcp.zig to keep the server file focused on implementation.
// Tests are picked up by the test runner via `@import("tests.zig")` which
// pulls in mcp.zig, which in turn references this file via a comptime
// `_ = @import("mcp/tests.zig")` block.

const std = @import("std");
const testing = std.testing;
const cio = @import("../cio.zig");
const mcp = @import("../mcp.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const snapshot_mod = @import("../snapshot.zig");
const ProjectCache = mcp.ProjectCache;
const BenchContext = mcp.BenchContext;
const handleRead = mcp.handleRead;
const getProjectDataDir = mcp.getProjectDataDir;

test "issue-258: cached project reads use the project root after contents are released" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "const project = \"secondary\";\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    var snapshot_src = Explorer.init(testing.allocator);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "const project = \"secondary\";\n");

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{project_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &snapshot_src, project_path, snap_path, testing.allocator);

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];

    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    ctx.explorer.releaseContents();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/main.zig\"}", .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    handleRead(io, testing.allocator, &parsed.value.object, &out, ctx.explorer, project_path);

    try testing.expect(std.mem.indexOf(u8, out.items, "const project = \"secondary\";") != null);
}

test "ProjectCache loads project from central snapshot cache" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn cachedProject() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "pub fn cachedProject() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    const root_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{project_path});
    defer testing.allocator.free(root_snapshot);
    if (std.Io.Dir.cwd().access(io, root_snapshot, .{})) |_| {
        return error.UnexpectedRootSnapshot;
    } else |_| {}

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];

    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(ctx.explorer.outlines.contains("src/main.zig"));
}

test "issue-353: explicit default project loads snapshot when default explorer is empty" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn issue353() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/main.zig", "pub fn issue353() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    default_explorer.setRoot(io, project_path);
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, project_path);
    defer cache.deinit();

    const ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(ctx.explorer != &default_explorer);
    try testing.expect(ctx.explorer.outlines.contains("src/main.zig"));
    try testing.expectEqual(@as(u64, 0), default_store.currentSeq());
}

test "issue-353: project cache invalidation reloads newly written snapshots" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    const data_dir = getProjectDataDir(testing.allocator, project_path) orelse return error.OutOfMemory;
    defer testing.allocator.free(data_dir);
    const central_snapshot = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{data_dir});
    defer testing.allocator.free(central_snapshot);
    const project_txt = try std.fmt.allocPrint(testing.allocator, "{s}/project.txt", .{data_dir});
    defer testing.allocator.free(project_txt);
    defer {
        std.Io.Dir.cwd().deleteFile(io, central_snapshot) catch {};
        std.Io.Dir.cwd().deleteFile(io, project_txt) catch {};
        std.Io.Dir.cwd().deleteDir(io, data_dir) catch {};
    }

    var snapshot_src = Explorer.init(testing.allocator);
    defer snapshot_src.deinit();
    snapshot_src.setRoot(io, project_path);
    try snapshot_src.indexFile("src/old.zig", "pub fn oldSymbol() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_src, project_path, testing.allocator);

    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, "/Users/example/default");
    defer cache.deinit();

    const old_ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(old_ctx.explorer.outlines.contains("src/old.zig"));

    var snapshot_next = Explorer.init(testing.allocator);
    defer snapshot_next.deinit();
    snapshot_next.setRoot(io, project_path);
    try snapshot_next.indexFile("src/new.zig", "pub fn newSymbol() void {}\n");
    try snapshot_mod.writeProjectCacheSnapshot(io, &snapshot_next, project_path, testing.allocator);

    cache.invalidate(project_path);

    const new_ctx = try cache.get(io, project_path, &default_explorer, &default_store);
    try testing.expect(!new_ctx.explorer.outlines.contains("src/old.zig"));
    try testing.expect(new_ctx.explorer.outlines.contains("src/new.zig"));
}

test "codedb_snapshot cache reuses output until store seq changes" {
    const io = testing.io;
    const alloc = testing.allocator;

    var explorer = Explorer.init(alloc);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(alloc);
    defer store.deinit();
    _ = try store.recordSnapshot("src/main.zig", "pub fn main() void {}\n".len, 0xabc);

    var agents = AgentRegistry.init(alloc);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = BenchContext.init(alloc, ".");
    defer bench_ctx.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    const args = &parsed.value.object;

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &first, &store, &explorer, &agents);

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &second, &store, &explorer, &agents);
    try testing.expectEqualStrings(first.items, second.items);

    try explorer.indexFile("src/main.zig", "pub fn changed() void {}\n");
    _ = try store.recordSnapshot("src/main.zig", "pub fn changed() void {}\n".len, 0xdef);

    var third: std.ArrayList(u8) = .empty;
    defer third.deinit(alloc);
    bench_ctx.runDispatch(io, alloc, .codedb_snapshot, args, &third, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, third.items, "changed") != null);
    try testing.expect(!std.mem.eql(u8, first.items, third.items));
}

fn runGit(cwd: []const u8, argv: []const []const u8) !void {
    const r = try cio.runCapture(.{ .allocator = testing.allocator, .argv = argv, .cwd = cwd, .max_output_bytes = 4096 });
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    switch (r.term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn gitAvailable(cwd: []const u8) bool {
    const r = cio.runCapture(.{ .allocator = testing.allocator, .argv = &.{ "git", "--version" }, .cwd = cwd, .max_output_bytes = 256 }) catch return false;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    return true;
}

test "stale-index guard: ProjectCache reconciles a secondary project=path on first load" {
    const test_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(test_io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    if (!gitAvailable(dir_path)) return error.SkipZigTest;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "sec.zig", .data = "pub fn oldFn() void {}" });
    try runGit(dir_path, &.{ "git", "init", "-q" });
    try runGit(dir_path, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A" });
    try runGit(dir_path, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init" });

    // Write a snapshot capturing the pre-edit state, as if this secondary
    // project was indexed a while ago.
    var snap_src = Explorer.init(testing.allocator);
    defer snap_src.deinit();
    snap_src.setRoot(test_io, dir_path);
    try snap_src.indexFile("sec.zig", "pub fn oldFn() void {}");
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/codedb.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(test_io, &snap_src, dir_path, snap_path, testing.allocator);

    // Offline edit AFTER the snapshot was written, BEFORE any MCP session
    // ever loads this secondary project.
    try tmp.dir.writeFile(test_io, .{ .sub_path = "sec.zig", .data = "pub fn oldFn() void {}\npub fn freshlyAddedFn() void {}" });

    var default_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_path_len = try std.Io.Dir.cwd().realPathFile(test_io, ".", &default_path_buf);
    const default_path = default_path_buf[0..default_path_len];
    var default_explorer = Explorer.init(testing.allocator);
    defer default_explorer.deinit();
    var default_store = Store.init(testing.allocator);
    defer default_store.deinit();

    var cache = ProjectCache.init(testing.allocator, default_path);
    defer cache.deinit();

    // First load of this secondary project: the fresh-load reconcile must
    // see the offline edit immediately, not just after the snapshot was
    // originally written.
    const ctx = try cache.get(test_io, dir_path, &default_explorer, &default_store);
    const rs = try ctx.explorer.searchContent("freshlyAddedFn", testing.allocator, 10);
    defer {
        for (rs) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(rs);
    }
    try testing.expect(rs.len == 1);
}

test "token guard: outline collapses a consecutive import run into one summary line" {
    const explore_tools = @import("explore_tools.zig");
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("main.zig",
        \\const std = @import("std");
        \\const os = @import("os.zig");
        \\const json = @import("json.zig");
        \\
        \\pub fn main() void {}
        \\
    );

    var args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"main.zig\"}", .{});
    defer args.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    explore_tools.handleOutline(testing.allocator, &args.value.object, &out, &explorer);

    try testing.expect(std.mem.indexOf(u8, out.items, "imports: std, os, json") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "(x3)") != null);
    // Individual per-line import entries are gone.
    try testing.expect(std.mem.indexOf(u8, out.items, "L1: import") == null);
}

test "token guard: handleRead caps a rangeless whole-file dump but not a raw read" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        try content.appendSlice(testing.allocator, "line of filler content here\n");
    }
    try testing.expect(content.items.len > Explorer.full_read_cap);
    try explorer.indexFile("big.txt", content.items);

    var capped_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"big.txt\"}", .{});
    defer capped_args.deinit();
    var capped_out: std.ArrayList(u8) = .empty;
    defer capped_out.deinit(testing.allocator);
    handleRead(testing.io, testing.allocator, &capped_args.value.object, &capped_out, &explorer, "/project");
    try testing.expect(capped_out.items.len < content.items.len);
    try testing.expect(std.mem.indexOf(u8, capped_out.items, "more lines elided") != null);

    // raw=true stays byte-exact — no cap, no elision note (#632).
    var raw_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"big.txt\",\"raw\":true}", .{});
    defer raw_args.deinit();
    var raw_out: std.ArrayList(u8) = .empty;
    defer raw_out.deinit(testing.allocator);
    handleRead(testing.io, testing.allocator, &raw_args.value.object, &raw_out, &explorer, "/project");
    try testing.expectEqualStrings(content.items, raw_out.items);
}

test "convergence governor: repeating an identical signature triggers the nudge at WARN_AT" {
    var gov = mcp.ConvergenceGovernor{};
    const sig_a: u64 = 111;
    const sig_b: u64 = 222;

    try testing.expect(mcp.convergenceNudge(gov.record(sig_a)) == null); // 1st: no nudge
    try testing.expect(mcp.convergenceNudge(gov.record(sig_b)) == null); // different sig, no nudge
    try testing.expect(mcp.convergenceNudge(gov.record(sig_a)) != null); // 2nd occurrence of A: nudge
}

test "convergence governor: ring buffer forgets calls older than HISTORY" {
    var gov = mcp.ConvergenceGovernor{};
    const sig: u64 = 42;
    _ = gov.record(sig);
    // Push HISTORY distinct signatures to fully evict `sig` from the window.
    var i: u64 = 1000;
    while (i < 1000 + mcp.ConvergenceGovernor.HISTORY) : (i += 1) {
        _ = gov.record(i);
    }
    // `sig` is no longer in the window, so recording it again is a fresh 1st occurrence.
    try testing.expect(mcp.convergenceNudge(gov.record(sig)) == null);
}

test "convergence governor: query-tool reformulation nudge fires at NAME_WARN_AT" {
    var gov = mcp.ConvergenceGovernor{};
    const name_sig: u64 = std.hash.Wyhash.hash(0, "codedb_search");
    var occurrences: usize = 0;
    var i: usize = 0;
    while (i < mcp.ConvergenceGovernor.NAME_WARN_AT - 1) : (i += 1) {
        occurrences = gov.recordName(name_sig);
        try testing.expect(mcp.convergenceStrategyNudge(occurrences) == null);
    }
    occurrences = gov.recordName(name_sig);
    try testing.expect(mcp.convergenceStrategyNudge(occurrences) != null);
}

test "MCP 2026-07-28: negotiateProtocolVersion picks exact/newest/oldest" {
    try testing.expectEqualStrings("2025-06-18", mcp.negotiateProtocolVersion("2025-06-18").?);
    try testing.expectEqualStrings("2026-07-28", mcp.negotiateProtocolVersion("2026-07-28").?);
    // Unknown future date (lex-greater than our newest) -> newest known.
    try testing.expectEqualStrings("2026-07-28", mcp.negotiateProtocolVersion("2099-01-01").?);
    // Unknown old-shaped date (lex-less than newest, not in our list) -> oldest known.
    try testing.expectEqualStrings("2024-11-05", mcp.negotiateProtocolVersion("2020-01-01").?);
    try testing.expect(mcp.negotiateProtocolVersion("") == null);
}

test "MCP 2026-07-28: unsupportedMetaProtocolVersion detects an unsupported params._meta pin" {
    var supported = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}}
    , .{});
    defer supported.deinit();
    try testing.expect(mcp.unsupportedMetaProtocolVersion(&supported.value.object) == null);

    var unsupported = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}
    , .{});
    defer unsupported.deinit();
    try testing.expectEqualStrings("2099-01-01", mcp.unsupportedMetaProtocolVersion(&unsupported.value.object).?);

    // Legacy clients never send params._meta — must be a no-op, not an error.
    var legacy = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"params":{}}
    , .{});
    defer legacy.deinit();
    try testing.expect(mcp.unsupportedMetaProtocolVersion(&legacy.value.object) == null);
}

test "MCP 2026-07-28: discover_result is well-formed JSON advertising our version list" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, mcp.discover_result, .{});
    defer parsed.deinit();
    const obj = &parsed.value.object;
    try testing.expectEqualStrings("complete", obj.get("resultType").?.string);
    try testing.expect(obj.get("supportedVersions").?.array.items.len == 4);
    try testing.expectEqualStrings("2026-07-28", obj.get("supportedVersions").?.array.items[0].string);
    try testing.expect(obj.get("_meta") != null);
}
