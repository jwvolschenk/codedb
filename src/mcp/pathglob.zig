const std = @import("std");
const explore_mod = @import("../explore.zig");
const mcpj = @import("mcp").json;
const eql = mcpj.eql;

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return explore_mod.matchGlob(pattern, path);
}

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    // Block null bytes (path truncation attack)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // Block backslash separators
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}
