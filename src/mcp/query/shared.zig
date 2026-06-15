const std = @import("std");
const explore_mod = @import("../../explore.zig");
pub const Explorer = explore_mod.Explorer;
pub const Store = @import("../../store.zig").Store;

pub const Context = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    store: *Store,
    file_set: *std.ArrayList([]const u8),
    hit_lines: *std.StringHashMap(std.ArrayList(usize)),
    have_set: *bool,
};

pub fn recordHitLine(hit_map: *std.StringHashMap(std.ArrayList(usize)), al: std.mem.Allocator, path: []const u8, line: u32) void {
    const gop = hit_map.getOrPut(path) catch return;
    if (!gop.found_existing) {
        const key = al.dupe(u8, path) catch return;
        gop.key_ptr.* = key;
        gop.value_ptr.* = .empty;
    }
    gop.value_ptr.append(al, @as(usize, @intCast(line))) catch {};
}
