const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../cio.zig");
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const Explorer = @import("../explore.zig").Explorer;
const watcher = @import("../watcher.zig");
const mcp_server = @import("../mcp.zig");
const git_mod = @import("../git.zig");
const TrigramIndex = @import("../index.zig").TrigramIndex;
const MmapTrigramIndex = @import("../index.zig").MmapTrigramIndex;
const snapshot_mod = @import("../snapshot.zig");
const telemetry = @import("../telemetry.zig");
const disk_cache = @import("disk_cache.zig");

pub fn reapLoop(agents: *AgentRegistry, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        // Sleep in 1s increments for responsive shutdown (was 5s)
        for (0..5) |_| {
            if (shutdown.load(.acquire)) return;
            cio.sleepMs(1000);
        }
        agents.reapStale(30_000);
    }
}

pub fn scanBg(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, scan_done: *std.atomic.Value(bool), shutdown: *std.atomic.Value(bool), data_dir: []const u8, abs_root: []const u8, telem: *telemetry.Telemetry, startup_t0: i64) void {
    // The in-repo snapshot must be addressed absolutely: an MCP server's cwd
    // is not the project root (often "/"), so a bare "codedb.snapshot" either
    // failed silently or landed in an unrelated directory (#591 family). The
    // absolute form also makes isRootSnapshot match, so .git/info/exclude
    // gets the codedb.snapshot entry on MCP-spawned scans too.
    var root_snap_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_snapshot_path = std.fmt.bufPrint(&root_snap_buf, "{s}/codedb.snapshot", .{abs_root}) catch "codedb.snapshot";
    const git_head = git_mod.getGitHead(root, allocator) catch null;
    const disk_hdr = TrigramIndex.readDiskHeader(io, data_dir, allocator) catch null;
    const heads_match = blk: {
        const a = git_head orelse break :blk false;
        const b = (disk_hdr orelse break :blk false).git_head orelse break :blk false;
        break :blk std.mem.eql(u8, &a, &b);
    };

    mcp_server.setScanState(.walking);
    watcher.initialScan(io, store, explorer, root, allocator, heads_match) catch |err| {
        std.log.warn("background scan failed: {}", .{err});
    };

    // Phase gate: bail if shutting down after initial scan
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }
    mcp_server.setScanState(.indexing);
    disk_cache.persistWordIndexToDisk(io, explorer, data_dir, git_head);

    if (heads_match) {
        const current_count = @as(u32, @intCast(explorer.outlines.count()));
        if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
            if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                explorer.adoptTrigramIndex(.{ .mmap = loaded });
                scan_done.store(true, .release);
                mcp_server.setScanState(.ready);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, root_snapshot_path, allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
                    explorer.releaseContents();
                    explorer.releaseSecondaryIndexes();
                }
                // Shrink index allocations to reclaim ArrayList over-allocation
                if (explorer.trigram_index.asHeap()) |heap| heap.shrinkPostingLists();
                explorer.word_index.shrinkAllocations();
                return;
            }
            if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
                explorer.adoptTrigramIndex(.{ .heap = loaded });
                scan_done.store(true, .release);
                mcp_server.setScanState(.ready);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, root_snapshot_path, allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
                    explorer.releaseContents();
                    explorer.releaseSecondaryIndexes();
                }
                return;
            }
        }
        explorer.rebuildTrigrams() catch {};
    }

    // Phase gate: bail before disk write if shutting down
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }

    explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
        std.log.warn("could not persist trigram index: {}", .{err});
    };

    // Phase gate: bail before mmap swap if shutting down
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }

    // Compact: swap heap index for mmap — zero RSS, data lives in OS page cache.
    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.adoptTrigramIndex(.{ .mmap = loaded });
    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.adoptTrigramIndex(.{ .heap = loaded });
    }

    scan_done.store(true, .release);
    mcp_server.setScanState(.ready);

    if (shutdown.load(.acquire)) return;

    telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));

    snapshot_mod.writeSnapshotDual(io, explorer, abs_root, root_snapshot_path, allocator) catch |err| {
        std.log.warn("could not auto-write snapshot: {}", .{err});
    };
    const file_count = explorer.outlines.count();
    if (file_count > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
        explorer.releaseContents();
        explorer.releaseSecondaryIndexes();
    }
}
pub fn triggerScanFromRoots(ctx: *mcp_server.DeferredScan, abs_root: []const u8) void {
    const data_dir = disk_cache.getDataDir(ctx.io, ctx.allocator, abs_root) catch {
        ctx.triggered.store(false, .release);
        return;
    };
    defer ctx.allocator.free(data_dir);
    const git_head = git_mod.getGitHead(abs_root, ctx.allocator) catch null;
    mcp_server.setScanState(.loading_snapshot);
    const loaded_snapshot = disk_cache.loadBestSnapshot(ctx.io, ctx.explorer, ctx.store, abs_root, data_dir, git_head, ctx.allocator);
    defer if (loaded_snapshot) |p| ctx.allocator.free(p);
    ctx.resolved_root = abs_root;
    ctx.explorer.setRoot(ctx.io, abs_root);
    ctx.scan_done.store(loaded_snapshot != null, .release);
    if (loaded_snapshot == null) {
        mcp_server.setScanState(.walking);
        const scan_thread = std.Thread.spawn(.{}, scanBg, .{ ctx.io, ctx.store, ctx.explorer, abs_root, ctx.allocator, ctx.scan_done, ctx.shutdown, data_dir, abs_root, ctx.telem, ctx.startup_t0 }) catch return;
        ctx.scan_thread = scan_thread;
    } else {
        const startup_time_ms: u64 = @intCast(@max(cio.milliTimestamp() - ctx.startup_t0, 0));
        disk_cache.loadTrigramFromDiskIfPresent(ctx.io, ctx.explorer, data_dir, ctx.allocator);
        // The snapshot stores outlines but not a faithfully complete
        // TypeIndex/TypeGraph/type-usage dep graph. Rebuild them from the
        // loaded outlines so codedb_deps / codedb_types / codedb_hierarchy
        // serve correct data — mirrors the project= load path (server.zig).
        ctx.explorer.rebuildTypeIndexes();
        // Heal offline edits AFTER disk indexes are adopted (the mmap trigram
        // overlay must mask removals) but BEFORE compaction — indexing into a
        // compacted explorer corrupts dep-graph keys (dangling slices into
        // released content). Runs before .ready so the first query sees it.
        disk_cache.reconcileAfterLoad(ctx.io, loaded_snapshot.?, ctx.explorer, ctx.store, abs_root, ctx.allocator);
        ctx.telem.recordCodebaseStats(ctx.explorer, startup_time_ms);
        disk_cache.compactMcpReadyMemory(ctx.io, ctx.explorer, data_dir, git_head, ctx.allocator);
        mcp_server.setScanState(.ready);
    }
}

pub fn watcherDeferredLoop(ctx: *mcp_server.DeferredScan) void {
    const t0 = cio.milliTimestamp();
    const fallback_after_ms: i64 = 3000;
    var fallback_attempted = false;
    while (!ctx.scan_done.load(.acquire) and !ctx.shutdown.load(.acquire)) {
        cio.sleepMs(50);
        if (!fallback_attempted and cio.milliTimestamp() - t0 >= fallback_after_ms) {
            fallback_attempted = true;
            // Client never sent indexable roots — fall back to cwd so the
            // server doesn't sit in loading_snapshot forever.
            const empty_roots: []const mcp_server.Root = &.{};
            _ = mcp_server.triggerDeferredScanWithFallback(ctx, empty_roots, ctx.fallback_cwd);
        }
    }
    if (ctx.shutdown.load(.acquire)) return;
    watcher.incrementalLoop(ctx.io, ctx.store, ctx.explorer, ctx.queue, ctx.resolved_root, ctx.shutdown, ctx.scan_done);
}

pub fn idleWatchdog(shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        // Quick liveness check: detect stdin disconnect (client gone).
        // Do not close a healthy stdio transport just because it is idle:
        // MCP stdio sessions are not resumable, and hosts such as Codex do
        // not necessarily respawn a dead server inside an existing chat.
        if (comptime builtin.os.tag != .windows) {
            // POSIX: poll stdin for POLLHUP (client disconnected).
            const stdin = cio.File.stdin();
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = stdin.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, 0) catch 0;
            if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.HUP) != 0) {
                std.log.info("stdin closed (client disconnected), exiting", .{});
                _ = std.c.close(stdin.handle);
                shutdown.store(true, .release);
                return;
            }
        }
        // Windows: stdin pipe detection not implemented yet.
        // The MCP host (Hermes, Claude, etc.) will terminate the process
        // when the session ends, and codedb responds to MCP shutdown
        // notifications through the protocol layer.

        cio.sleepMs(mcp_server.dead_client_poll_ms);
    }
}
