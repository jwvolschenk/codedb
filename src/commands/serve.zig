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
    const port: u16 = blk: {
        const raw = cio.posixGetenv("CODEDB_PORT") orelse break :blk 6767;
        break :blk std.fmt.parseInt(u16, raw, 10) catch 6767;
    };
    var agents = AgentRegistry.init(ctx.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var shutdown = std.atomic.Value(bool).init(false);
    defer shutdown.store(true, .release);
    var scan_already_done = std.atomic.Value(bool).init(true);

    const queue = try ctx.allocator.create(watcher.EventQueue);
    defer ctx.allocator.destroy(queue);
    queue.* = watcher.EventQueue{};
    const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ ctx.io, ctx.store, ctx.explorer, queue, ctx.root, &shutdown, &scan_already_done });
    defer watch_thread.join();

    const reap_thread = try std.Thread.spawn(.{}, scan.reapLoop, .{ &agents, &shutdown });
    defer reap_thread.join();

    std.log.info("codedb: {d} files indexed, listening on :{d}", .{ ctx.store.currentSeq(), port });
    try server.serve(ctx.io, ctx.allocator, ctx.store, &agents, ctx.explorer, queue, port);
}
