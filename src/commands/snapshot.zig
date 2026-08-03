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
    context_mod.rejectExtraArgs(ctx, 1, "codedb [root] snapshot [output-path]");
    const t0 = cio.nanoTimestamp();
    const output = if (ctx.args.len > ctx.cmd_args_start) ctx.args[ctx.cmd_args_start] else "codedb.snapshot";
    snapshot_mod.writeSnapshotDual(ctx.io, ctx.explorer, ctx.abs_root, output, ctx.allocator) catch |err| {
        ctx.out.p("{s}\xe2\x9c\x97{s} snapshot failed: {}\n", .{ ctx.s.red, ctx.s.reset, err });
        std.process.exit(1);
    };
    const git_head = git_mod.getGitHead(ctx.abs_root, ctx.allocator) catch null;
    disk_cache.loadWordIndexFromDiskIfPresent(ctx.io, ctx.explorer, ctx.data_dir, git_head, ctx.allocator);
    if (!disk_cache.wordIndexMatchesOutlines(ctx.explorer)) {
        disk_cache.persistWordIndexFromSource(ctx.io, ctx.explorer, ctx.abs_root, ctx.data_dir, git_head, ctx.allocator) catch |err| {
            ctx.out.p("{s}\xe2\x9c\x97{s} word index persist failed: {}\n", .{ ctx.s.red, ctx.s.reset, err });
            std.process.exit(1);
        };
    } else {
        disk_cache.persistWordIndexToDisk(ctx.io, ctx.explorer, ctx.data_dir, git_head);
    }
    const elapsed = cio.nanoTimestamp() - t0;
    var dur_buf: [64]u8 = undefined;
    ctx.out.p("{s}\xe2\x9c\x93{s} {s}snapshot{s}  {s}{s}{s}  {s}{d} files{s}  {s}{s}{s}\n", .{
        ctx.s.green,                       ctx.s.reset,
        ctx.s.bold,                        ctx.s.reset,
        ctx.s.cyan,                        output,
        ctx.s.reset,                       ctx.s.dim,
        ctx.explorer.outlines.count(),     ctx.s.reset,
        sty.durationColor(ctx.s, elapsed), sty.formatDuration(&dur_buf, elapsed),
        ctx.s.reset,
    });
}
