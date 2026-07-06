// Warm-start working-tree reconcile (#591 Task 5).
//
// A snapshot load is gated on git-HEAD equality, so tracked-and-clean files
// are known-good. What a warm start can NOT trust:
//   * files dirty NOW (edited/created/deleted while the server was down) —
//     `git status --porcelain -z` enumerates them;
//   * files that were dirty AT SNAPSHOT-WRITE time but are clean now (the
//     revert case) — the snapshot's META records that list as `dirty_paths`.
// Reconciling the union of both closes the warm-start staleness hole that
// used to require `codedb_index force=true`.
//
// Non-git projects: getDirtyPaths returns null and snapshot_dirty is empty,
// so this no-ops; the watcher seed sweep and the loader's mtime re-read are
// the safety net there.

const std = @import("std");
const Explorer = @import("../explore.zig").Explorer;
const Store = @import("../store.zig").Store;
const git_mod = @import("../git.zig");
const skip_rules = @import("skip_rules.zig");
const incremental = @import("incremental.zig");

/// For each path in (getDirtyPaths(abs_root) ∪ snapshot_dirty): stat under
/// abs_root — exists → re-read + index + store.recordSnapshot; missing →
/// explorer.removeFile + store.recordDelete. All indexing routes through
/// incremental.indexFileContent, which applies the same skip rules as every
/// other indexing path (skip_rules.shouldSkipFile includes isSensitivePath —
/// sensitive files stay excluded; CLAUDE.md security requirement).
/// Best-effort: any per-path failure is skipped, never fatal to startup.
pub fn reconcileWorkingTree(
    io: std.Io,
    explorer: *Explorer,
    store: *Store,
    abs_root: []const u8,
    snapshot_dirty: []const []const u8,
    alloc: std.mem.Allocator,
) void {
    const dirty_now: ?[][]u8 = git_mod.getDirtyPaths(abs_root, alloc);
    defer if (dirty_now) |d| git_mod.freePathList(d, alloc);

    // Union the two lists (paths can appear in both — e.g. still dirty).
    var set = std.StringHashMap(void).init(alloc);
    defer set.deinit();
    if (dirty_now) |d| {
        for (d) |p| set.put(p, {}) catch return;
    }
    for (snapshot_dirty) |p| set.put(p, {}) catch return;
    if (set.count() == 0) return;

    const dir = std.Io.Dir.cwd().openDir(io, abs_root, .{}) catch return;
    defer dir.close(io);

    var reindexed: usize = 0;
    var removed: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |key| {
        const path = key.*;
        // Directory-level skips (node_modules/, .git/, …). File-level skips
        // (extensions, lockfiles, sensitive paths, generated code, size cap,
        // binary sniff) are applied inside indexFileContent.
        if (skip_rules.shouldSkip(path)) continue;

        const stat = dir.statFile(io, path, .{}) catch {
            // Deleted while down (or the old half of a rename): evict.
            const was_indexed = blk: {
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                break :blk explorer.outlines.contains(path);
            };
            if (was_indexed) {
                _ = store.recordDelete(path, 0) catch {};
                explorer.removeFile(path);
                removed += 1;
            }
            continue;
        };
        if (stat.kind == .directory) continue;

        incremental.indexFileContent(io, explorer, dir, path, alloc, false) catch continue;
        _ = store.recordSnapshot(path, stat.size, 0) catch {};
        reindexed += 1;
    }

    if (reindexed > 0 or removed > 0) {
        std.log.info("codedb: warm-start reconcile — {d} re-indexed, {d} removed under {s}", .{ reindexed, removed, abs_root });
    }
}
