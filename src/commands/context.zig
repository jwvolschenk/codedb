const std = @import("std");
const cio = @import("../cio.zig");
const shell = @import("../cli/shell.zig");
const sty = @import("../style.zig");
const Store = @import("../store.zig").Store;
const Explorer = @import("../explore.zig").Explorer;

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    out: shell.Out,
    s: sty.Style,
    store: *Store,
    explorer: *Explorer,
    args: []const []const u8,
    cmd_args_start: usize,
    root: []const u8,
    abs_root: []const u8,
    data_dir: []const u8,
    use_color: bool,
    mcp_deferred_root: bool,
    mcp_auto_index: bool,
    require_git_repo: bool,
};

/// Errors and exits 1 if more positional args follow the command name than
/// `max_positional` allows. Closes the "extra or typo'd arguments silently
/// ignored" gap (upstream #528) — e.g. `codedb word foo bar baz` used to
/// search for "foo" and drop "bar baz" without a hint anything was wrong.
pub fn rejectExtraArgs(ctx: *const Context, max_positional: usize, usage: []const u8) void {
    if (ctx.args.len > ctx.cmd_args_start + max_positional) {
        ctx.out.p("{s}\xe2\x9c\x97{s} unexpected argument: {s}{s}{s}\n  usage: {s}\n", .{
            ctx.s.red,      ctx.s.reset,
            ctx.s.bold,     ctx.args[ctx.cmd_args_start + max_positional],
            ctx.s.reset,    usage,
        });
        std.process.exit(1);
    }
}
