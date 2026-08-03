const std = @import("std");
const cio = @import("../cio.zig");
const sty = @import("../style.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
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
    context_mod.rejectExtraArgs(ctx, 1, "codedb [root] find <symbol>");
    const name = if (ctx.args.len > ctx.cmd_args_start) ctx.args[ctx.cmd_args_start] else {
        ctx.out.p("{s}\xe2\x9c\x97{s} usage: codedb [ctx.root] find {s}<symbol>{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.cyan, ctx.s.reset,
        });
        std.process.exit(1);
    };
    const t0 = cio.nanoTimestamp();
    if (try ctx.explorer.findSymbol(name, ctx.allocator)) |r| {
        defer {
            ctx.allocator.free(r.path);
            ctx.allocator.free(r.symbol.name);
            if (r.symbol.detail) |d| ctx.allocator.free(d);
            if (r.symbol.return_type) |rt| ctx.allocator.free(rt);
            for (r.symbol.param_types) |pt| ctx.allocator.free(pt);
            if (r.symbol.param_types.len > 0) ctx.allocator.free(r.symbol.param_types);
        }
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        const kind = @tagName(r.symbol.kind);
        ctx.out.p("{s}\xe2\x9c\x93{s} {s}{s}{s} {s}{s}{s}  {s}{s}{s}:{s}{d}{s}  {s}{s}{s}\n", .{
            ctx.s.green,                       ctx.s.reset,
            ctx.s.kindColor(kind),             kind,
            ctx.s.reset,                       ctx.s.bold,
            name,                              ctx.s.reset,
            ctx.s.dim,                         r.path,
            ctx.s.reset,                       ctx.s.cyan,
            r.symbol.line_start,               ctx.s.reset,
            sty.durationColor(ctx.s, elapsed), sty.formatDuration(&dur_buf, elapsed),
            ctx.s.reset,
        });
        if (r.symbol.return_type) |rt| {
            ctx.out.p("  {s}->{s} {s}\n", .{ ctx.s.cyan, ctx.s.reset, rt });
        }
        if (r.symbol.param_types.len > 0) {
            ctx.out.p("  {s}params:{s} ", .{ ctx.s.dim, ctx.s.reset });
            for (r.symbol.param_types, 0..) |pt, i| {
                if (i > 0) ctx.out.p(", ", .{});
                ctx.out.p("{s}", .{pt});
            }
            ctx.out.p("\n", .{});
        }
        if (r.symbol.detail) |d| {
            ctx.out.p("  {s}{s}{s}\n", .{ ctx.s.dim, d, ctx.s.reset });
        }
    } else {
        ctx.out.p("{s}\xe2\x9c\x97{s} not found: {s}{s}{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.bold, name, ctx.s.reset,
        });
    }
}
