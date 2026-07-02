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
};
