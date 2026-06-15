const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const commands = @import("commands/mod.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag == .windows) {
        cio.setProcessArgsWindows(init.args.vector);
    } else {
        cio.setProcessArgs(init.args.vector);
    }
    const stack_size: usize = if (builtin.mode == .Debug) 64 * 1024 * 1024 else 8 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, mainInner, .{});
    thread.join();
}

fn mainInner() void {
    commands.run() catch |err| {
        std.debug.print("fatal: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
