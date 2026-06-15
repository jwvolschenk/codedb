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
    const tree = try ctx.explorer.getTree(ctx.allocator, ctx.use_color);
    defer ctx.allocator.free(tree);
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    ctx.out.p("{s}", .{tree});
    ctx.out.p("{s}{s}{s}\n", .{
        sty.durationColor(ctx.s, elapsed), sty.formatDuration(&dur_buf, elapsed), ctx.s.reset,
    });
}
