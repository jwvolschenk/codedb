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
    const word = if (ctx.args.len > ctx.cmd_args_start) ctx.args[ctx.cmd_args_start] else {
        ctx.out.p("{s}\xe2\x9c\x97{s} usage: codedb [ctx.root] word {s}<identifier>{s}\n", .{
            ctx.s.red, ctx.s.reset, ctx.s.cyan, ctx.s.reset,
        });
        std.process.exit(1);
    };
    const t0 = cio.nanoTimestamp();
    const hits = try ctx.explorer.searchWord(word, ctx.allocator);
    defer ctx.allocator.free(hits);
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    if (hits.len == 0) {
        ctx.out.p("{s}\xe2\x9c\x97{s} no hits for {s}'{s}'{s}\n", .{
            ctx.s.yellow, ctx.s.reset, ctx.s.bold, word, ctx.s.reset,
        });
    } else {
        ctx.out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} hits for {s}'{s}'{s}  {s}{s}{s}\n", .{
            ctx.s.green,                       ctx.s.reset,
            ctx.s.bold,                        hits.len,
            ctx.s.reset,                       ctx.s.bold,
            word,                              ctx.s.reset,
            sty.durationColor(ctx.s, elapsed), sty.formatDuration(&dur_buf, elapsed),
            ctx.s.reset,
        });
        ctx.explorer.mu.lockShared();
        defer ctx.explorer.mu.unlockShared();
        for (hits) |h| {
            ctx.out.p("  {s}{s}{s}:{s}{d}{s}\n", .{
                ctx.s.cyan, ctx.explorer.word_index.hitPath(h), ctx.s.reset,
                ctx.s.dim,  h.line_num,                         ctx.s.reset,
            });
        }
    }
}
