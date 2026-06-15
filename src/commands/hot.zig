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
    const t0 = cio.nanoTimestamp();
    const hot = try ctx.explorer.getHotFiles(ctx.store, ctx.allocator, 10);
    defer {
        for (hot) |path| ctx.allocator.free(path);
        ctx.allocator.free(hot);
    }
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    ctx.out.p("{s}\xe2\x9c\x93{s} {s}recently modified{s}  {s}{s}{s}\n", .{
        ctx.s.green,                       ctx.s.reset,
        ctx.s.bold,                        ctx.s.reset,
        sty.durationColor(ctx.s, elapsed), sty.formatDuration(&dur_buf, elapsed),
        ctx.s.reset,
    });
    for (hot, 1..) |path, i| {
        ctx.out.p("  {s}{d}{s}  {s}{s}{s}\n", .{
            ctx.s.dim,  i,    ctx.s.reset,
            ctx.s.cyan, path, ctx.s.reset,
        });
    }
}
