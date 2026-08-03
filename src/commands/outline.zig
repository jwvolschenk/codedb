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
    context_mod.rejectExtraArgs(ctx, 1, "codedb [root] outline <path>");
    const path = if (ctx.args.len > ctx.cmd_args_start) ctx.args[ctx.cmd_args_start] else {
        ctx.out.p("{s}\xe2\x9c\x97{s} usage: codedb [ctx.root] outline {s}<path>{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.cyan, ctx.s.reset,
        });
        std.process.exit(1);
    };
    const t0 = cio.nanoTimestamp();
    var outline = ctx.explorer.getOutline(path, ctx.allocator) catch {
        ctx.out.p("{s}\xe2\x9c\x97{s} {s}{s}{s} \xe2\x80\x94 failed to load outline\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.bold, path, ctx.s.reset,
        });
        std.process.exit(1);
    } orelse {
        ctx.out.p("{s}\xe2\x9c\x97{s} not indexed: {s}{s}{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.bold, path, ctx.s.reset,
        });
        return;
    };
    defer outline.deinit();
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    const lang = @tagName(outline.language);
    ctx.out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  {s}{d} lines{s}  {s}{s}{s}\n", .{
        ctx.s.green,                           ctx.s.reset,
        ctx.s.bold,                            path,
        ctx.s.reset,                           ctx.s.langColor(lang),
        lang,                                  ctx.s.reset,
        ctx.s.dim,                             outline.line_count,
        ctx.s.reset,                           sty.durationColor(ctx.s, elapsed),
        sty.formatDuration(&dur_buf, elapsed), ctx.s.reset,
    });
    for (outline.symbols.items) |sym| {
        const kind = @tagName(sym.kind);
        ctx.out.p("  {s}L{d:<5}{s}  {s}{s:<14}{s}  {s}{s}{s}", .{
            ctx.s.dim,             sym.line_start, ctx.s.reset,
            ctx.s.kindColor(kind), kind,           ctx.s.reset,
            ctx.s.bold,            sym.name,       ctx.s.reset,
        });
        if (sym.return_type) |rt| {
            ctx.out.p(" {s}->{s} {s}", .{ ctx.s.cyan, ctx.s.reset, rt });
        }
        if (sym.param_types.len > 0) {
            ctx.out.p(" {s}({s}", .{ ctx.s.dim, ctx.s.reset });
            for (sym.param_types, 0..) |pt, i| {
                if (i > 0) ctx.out.p(", {s}", .{ctx.s.dim});
                ctx.out.p("{s}", .{pt});
            }
            ctx.out.p("{s}){s}", .{ ctx.s.dim, ctx.s.reset });
        }
        if (sym.detail) |d| {
            ctx.out.p("  {s}{s}{s}", .{ ctx.s.dim, d, ctx.s.reset });
        }
        ctx.out.p("\n", .{});
    }
}
