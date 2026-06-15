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
    var use_regex = false;
    var query_arg_start = ctx.cmd_args_start;
    if (ctx.args.len > ctx.cmd_args_start and std.mem.eql(u8, ctx.args[ctx.cmd_args_start], "--regex")) {
        use_regex = true;
        query_arg_start = ctx.cmd_args_start + 1;
    }
    const query = if (ctx.args.len > query_arg_start) ctx.args[query_arg_start] else {
        ctx.out.p("{s}\xe2\x9c\x97{s} usage: codedb [ctx.root] search [--regex] {s}<query>{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.cyan, ctx.s.reset,
        });
        std.process.exit(1);
    };
    const t0 = cio.nanoTimestamp();
    const results = if (use_regex)
        try ctx.explorer.searchContentRegex(query, ctx.allocator, 50)
    else
        try ctx.explorer.searchContent(query, ctx.allocator, 50);
    defer {
        for (results) |r| {
            ctx.allocator.free(r.path);
            ctx.allocator.free(r.line_text);
        }
        ctx.allocator.free(results);
    }
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    if (results.len == 0) {
        ctx.out.p("{s}\xe2\x9c\x97{s} no results for {s}\"{s}\"{s}\n", .{
            ctx.s.yellow, ctx.s.reset, ctx.s.bold, query, ctx.s.reset,
        });
    } else {
        const mode_label: []const u8 = if (use_regex) " (regex)" else "";
        ctx.out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} results for {s}\"{s}\"{s}{s}  {s}{s}{s}\n", .{
            ctx.s.green,                           ctx.s.reset,
            ctx.s.bold,                            results.len,
            ctx.s.reset,                           ctx.s.bold,
            query,                                 ctx.s.reset,
            mode_label,                            sty.durationColor(ctx.s, elapsed),
            sty.formatDuration(&dur_buf, elapsed), ctx.s.reset,
        });
        for (results) |r| {
            ctx.out.p("  {s}{s}{s}:{s}{d}{s}  {s}\n", .{
                ctx.s.cyan,  r.path,     ctx.s.reset,
                ctx.s.dim,   r.line_num, ctx.s.reset,
                r.line_text,
            });
        }
    }
}
