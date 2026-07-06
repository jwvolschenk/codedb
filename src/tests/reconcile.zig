// Tests for the warm-start working-tree reconcile (#591 Task 5):
//   * git status --porcelain -z parser (pure, no subprocess)
//   * snapshot META dirty_paths round-trip
//   * reconcileWorkingTree healing created/modified/deleted-while-down files
//
// Picked up by the test runner via tests.zig, which re-imports this file.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;
const git_mod = @import("../git.zig");
const reconcile = @import("../watcher/reconcile.zig");
const snapshot_mod = @import("../snapshot.zig");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../store.zig").Store;
const cio = @import("../cio.zig");

// ── parseStatusPorcelainZ: pure parser over `git status --porcelain -z` ──

fn expectPaths(actual: []const []u8, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e, a);
    }
}

test "porcelain-z: modified file ( M)" {
    const out = try git_mod.parseStatusPorcelainZ(" M src/main.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"src/main.zig"});
}

test "porcelain-z: staged added (A )" {
    const out = try git_mod.parseStatusPorcelainZ("A  new.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"new.zig"});
}

test "porcelain-z: deleted ( D)" {
    const out = try git_mod.parseStatusPorcelainZ(" D gone.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"gone.zig"});
}

test "porcelain-z: untracked (??)" {
    const out = try git_mod.parseStatusPorcelainZ("?? scratch.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"scratch.zig"});
}

test "porcelain-z: rename yields BOTH new and old path" {
    // -z rename entries are `R<score> <new>\0<old>\0` — two NUL-separated paths.
    const out = try git_mod.parseStatusPorcelainZ("R  new_name.zig\x00old_name.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{ "new_name.zig", "old_name.zig" });
}

test "porcelain-z: copy yields both paths" {
    const out = try git_mod.parseStatusPorcelainZ("C  copy.zig\x00original.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{ "copy.zig", "original.zig" });
}

test "porcelain-z: filename with spaces is NOT quoted in -z mode" {
    const out = try git_mod.parseStatusPorcelainZ(" M dir with space/my file.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"dir with space/my file.zig"});
}

test "porcelain-z: multiple entries" {
    const out = try git_mod.parseStatusPorcelainZ(" M a.zig\x00?? b.zig\x00 D c.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{ "a.zig", "b.zig", "c.zig" });
}

test "porcelain-z: empty output -> empty list" {
    const out = try git_mod.parseStatusPorcelainZ("", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "porcelain-z: malformed short entry is skipped, not crashed on" {
    const out = try git_mod.parseStatusPorcelainZ("XY\x00 M ok.zig\x00", testing.allocator);
    defer git_mod.freePathList(out, testing.allocator);
    try expectPaths(out, &.{"ok.zig"});
}

// ── META dirty_paths round-trip ──────────────────────────────────────

test "meta: dirty_paths absent in legacy snapshot -> empty list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/t.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);

    // A non-git tmp dir: getDirtyPaths returns null, so the writer emits no
    // dirty_paths key — exactly the legacy/absent-key shape.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("a.zig", "pub fn a() void {}");
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, arena.allocator());

    const dirty = snapshot_mod.readSnapshotDirtyPaths(io, snap_path, testing.allocator);
    try testing.expect(dirty == null or dirty.?.len == 0);
    if (dirty) |d| git_mod.freePathList(d, testing.allocator);
}

test "meta: dirty_paths written for a dirty git repo and read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    if (!gitAvailable(dir_path)) return error.SkipZigTest;
    try initGitRepoWithCommit(io, tmp.dir, dir_path);

    // Make the tree dirty: modify the committed file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn a2() void {}" });

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/t.snapshot", .{dir_path});
    defer testing.allocator.free(snap_path);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("a.zig", "pub fn a2() void {}");
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, arena.allocator());

    const dirty = snapshot_mod.readSnapshotDirtyPaths(io, snap_path, testing.allocator) orelse
        return testing.expect(false); // key must exist for a dirty repo
    defer git_mod.freePathList(dirty, testing.allocator);
    var found = false;
    for (dirty) |p| {
        if (std.mem.eql(u8, p, "a.zig")) found = true;
    }
    try testing.expect(found);
}

// ── reconcileWorkingTree: heal offline edits on warm start ───────────

test "reconcile: modified + created + deleted while down are healed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    if (!gitAvailable(dir_path)) return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "mod.zig", .data = "pub fn oldBody() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "del.zig", .data = "pub fn goner() void {}" });
    try initGitRepoWithCommit(io, tmp.dir, dir_path);

    // Index the pre-change state (as if loaded from a snapshot).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    exp.setRoot(io, dir_path);
    try exp.indexFile("mod.zig", "pub fn oldBody() void {}");
    try exp.indexFile("del.zig", "pub fn goner() void {}");
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Offline edits: modify one, create one, delete one.
    try tmp.dir.writeFile(io, .{ .sub_path = "mod.zig", .data = "pub fn newBody() void {}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "created.zig", .data = "pub fn fresh() void {}" });
    tmp.dir.deleteFile(io, "del.zig") catch {};

    reconcile.reconcileWorkingTree(io, &exp, &store, dir_path, &.{}, testing.allocator);

    // Modified content visible.
    {
        const rs = try exp.searchContent("newBody", testing.allocator, 10);
        defer freeSearchResults(rs);
        try testing.expect(rs.len == 1);
    }
    // Created file indexed.
    {
        const rs = try exp.searchContent("fresh", testing.allocator, 10);
        defer freeSearchResults(rs);
        try testing.expect(rs.len == 1);
    }
    // Deleted file evicted.
    try testing.expect(exp.outlines.get("del.zig") == null);
}

test "reconcile: sensitive dirty file is NOT indexed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    if (!gitAvailable(dir_path)) return error.SkipZigTest;
    try initGitRepoWithCommit(io, tmp.dir, dir_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    exp.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // A secrets file appears while the server is down. Reconcile must skip it
    // (skip_rules.shouldSkipFile -> isSensitivePath) — CLAUDE.md security rule.
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "SECRET_TOKEN=hunter2" });

    reconcile.reconcileWorkingTree(io, &exp, &store, dir_path, &.{}, testing.allocator);

    try testing.expect(exp.outlines.get(".env") == null);
    const rs = try exp.searchContent("hunter2", testing.allocator, 10);
    defer freeSearchResults(rs);
    try testing.expect(rs.len == 0);
}

test "reconcile: snapshot dirty_paths (revert case) re-read even when tree is clean now" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    if (!gitAvailable(dir_path)) return error.SkipZigTest;
    try tmp.dir.writeFile(io, .{ .sub_path = "rev.zig", .data = "pub fn committed() void {}" });
    try initGitRepoWithCommit(io, tmp.dir, dir_path);

    // Simulated history: snapshot captured a then-dirty rev.zig ("dirtyBody");
    // user then reverted, so the tree is clean NOW and `git status` is empty.
    // Only the snapshot's recorded dirty list can trigger the re-read.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    exp.setRoot(io, dir_path);
    try exp.indexFile("rev.zig", "pub fn dirtyBody() void {}");
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const snap_dirty = [_][]const u8{"rev.zig"};
    reconcile.reconcileWorkingTree(io, &exp, &store, dir_path, &snap_dirty, testing.allocator);

    const rs = try exp.searchContent("committed", testing.allocator, 10);
    defer freeSearchResults(rs);
    try testing.expect(rs.len == 1);
    const stale = try exp.searchContent("dirtyBody", testing.allocator, 10);
    defer freeSearchResults(stale);
    try testing.expect(stale.len == 0);
}

// ── helpers ─────────────────────────────────────────────────────────

fn gitAvailable(cwd: []const u8) bool {
    const r = cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "--version" },
        .cwd = cwd,
        .max_output_bytes = 256,
    }) catch return false;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    return true;
}

fn runGit(cwd: []const u8, argv: []const []const u8) !void {
    const r = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 64 * 1024,
    });
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    switch (r.term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn initGitRepoWithCommit(test_io: std.Io, dir: std.Io.Dir, dir_path: []const u8) !void {
    // Guarantee at least one committed file so HEAD exists.
    dir.writeFile(test_io, .{ .sub_path = "a.zig", .data = "pub fn a() void {}" }) catch {};
    try runGit(dir_path, &.{ "git", "init", "-q" });
    try runGit(dir_path, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A" });
    try runGit(dir_path, &.{ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init" });
}

fn freeSearchResults(rs: anytype) void {
    for (rs) |r| {
        testing.allocator.free(r.path);
        testing.allocator.free(r.line_text);
    }
    testing.allocator.free(rs);
}
