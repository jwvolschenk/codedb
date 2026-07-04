// Tests for mcp.zig — ProjectCache, BenchContext, SnapshotCache.
//
// Extracted from mcp.zig to keep the server file focused on implementation.
// Tests are picked up by the test runner via `@import("tests.zig")` which
// pulls in mcp.zig, which in turn references this file via a comptime
// `_ = @import("mcp/tests.zig")` block.

const std = @import("std");
const testing = std.testing;
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
