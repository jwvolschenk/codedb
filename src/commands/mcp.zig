const std = @import("std");
const cio = @import("../cio.zig");
const sty = @import("../style.zig");
const Context = @import("context.zig").Context;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const watcher = @import("../watcher.zig");
const server = @import("../server.zig");
const mcp_server = @import("../mcp.zig");
const git_mod = @import("../git.zig");
const snapshot_mod = @import("../snapshot.zig");
const telemetry = @import("../telemetry.zig");
const update_mod = @import("../update.zig");
const disk_cache = @import("../cli/disk_cache.zig");
const scan = @import("../cli/scan.zig");

pub fn run(ctx: *Context) !void {
    // Background auto-update check (no-op when CODEDB_NO_AUTO_UPDATE is set
    // or when the last check was within the last 24h). Detached thread, so
    // this doesn't block server startup.
    update_mod.maybeAutoUpdate(ctx.io, ctx.allocator);

    var agents = AgentRegistry.init(ctx.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    const root_from_cwd = ctx.mcp_deferred_root;

    // When mcp_auto_index is false (from .codedbrc config), set the lazy flag
    // so triggerDeferredScanWithFallback won't auto-index CWD on startup.
    // The server stays idle until the agent explicitly calls codedb_index.
    // CODEDB_LAZY=1 env var overrides config for quick testing.
    mcp_server.setLazyStart(blk: {
        if (cio.posixGetenv("CODEDB_LAZY")) |v| {
            break :blk std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
        }
        break :blk !ctx.mcp_auto_index;
    });

    disk_cache.saveProjectInfo(ctx.io, ctx.allocator, ctx.data_dir, ctx.abs_root) catch {};

    // Set up query tracking WAL
    const query_log = std.fmt.allocPrint(ctx.allocator, "{s}/queries.log", .{ctx.data_dir}) catch null;
    if (query_log) |ql| mcp_server.setQueryLogPath(ql);

    const startup_t0 = cio.milliTimestamp();
    var telemetry_disabled = false;
    for (ctx.args[ctx.cmd_args_start..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-telemetry")) {
            telemetry_disabled = true;
            break;
        }
    }

    var telem = telemetry.Telemetry.init(ctx.io, ctx.data_dir, ctx.allocator, telemetry_disabled);
    defer telem.deinit();
    telem.recordSessionStart();

    var shutdown = std.atomic.Value(bool).init(false);

    const queue = try ctx.allocator.create(watcher.EventQueue);
    defer ctx.allocator.destroy(queue);
    queue.* = watcher.EventQueue{};

    var scan_thread: ?std.Thread = null;
    var watch_thread: std.Thread = undefined;

    var deferred: mcp_server.DeferredScan = undefined;
    var maybe_deferred: ?*mcp_server.DeferredScan = null;

    if (root_from_cwd) {
        deferred = .{
            .io = ctx.io,
            .allocator = ctx.allocator,
            .store = ctx.store,
            .explorer = ctx.explorer,
            .scan_done = try ctx.allocator.create(std.atomic.Value(bool)),
            .shutdown = &shutdown,
            .telem = &telem,
            .queue = queue,
            .startup_t0 = startup_t0,
            .fallback_cwd = ctx.abs_root,
            .triggerFn = scan.triggerScanFromRoots,
        };
        deferred.scan_done.* = std.atomic.Value(bool).init(false);
        maybe_deferred = &deferred;
        mcp_server.setScanState(.loading_snapshot);
        watch_thread = try std.Thread.spawn(.{}, scan.watcherDeferredLoop, .{&deferred});
    } else {
        const git_head = git_mod.getGitHead(ctx.abs_root, ctx.allocator) catch null;
        mcp_server.setScanState(.loading_snapshot);
        const snapshot_loaded = disk_cache.loadBestSnapshot(ctx.io, ctx.explorer, ctx.store, ctx.abs_root, ctx.data_dir, git_head, ctx.allocator);
        var scan_done = std.atomic.Value(bool).init(snapshot_loaded);
        if (!snapshot_loaded) {
            mcp_server.setScanState(.walking);
            scan_thread = try std.Thread.spawn(.{}, scan.scanBg, .{ ctx.io, ctx.store, ctx.explorer, ctx.root, ctx.allocator, &scan_done, &shutdown, ctx.data_dir, ctx.abs_root, &telem, startup_t0 });
        } else {
            const startup_time_ms: u64 = @intCast(@max(cio.milliTimestamp() - startup_t0, 0));
            disk_cache.loadTrigramFromDiskIfPresent(ctx.io, ctx.explorer, ctx.data_dir, ctx.allocator);
            // Rebuild TypeIndex/TypeGraph/type-usage deps from the loaded
            // outlines (the snapshot doesn't preserve them completely).
            // Matches the project= load path and triggerScanFromRoots.
            ctx.explorer.rebuildTypeIndexes();
            telem.recordCodebaseStats(ctx.explorer, startup_time_ms);
            disk_cache.compactMcpReadyMemory(ctx.io, ctx.explorer, ctx.data_dir, git_head, ctx.allocator);
            mcp_server.setScanState(.ready);
        }
        watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ ctx.io, ctx.store, ctx.explorer, queue, ctx.root, &shutdown, &scan_done });
    }

    const idle_thread = try std.Thread.spawn(.{}, scan.idleWatchdog, .{&shutdown});

    std.log.info("codedb mcp: ctx.root={s} files={d} data={s} scan={s}", .{ ctx.abs_root, ctx.store.currentSeq(), ctx.data_dir, mcp_server.getScanState().name() });

    mcp_server.run(ctx.io, ctx.allocator, ctx.store, ctx.explorer, &agents, ctx.abs_root, &telem, maybe_deferred);

    shutdown.store(true, .release);
    if (scan_thread) |st| st.join();
    if (maybe_deferred) |d| {
        if (d.scan_thread) |st| st.join();
    }
    watch_thread.join();
    idle_thread.join();
}
