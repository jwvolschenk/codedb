const std = @import("std");
const explore_mod = @import("../explore.zig");
const mcpj = @import("mcp").json;
const eql = mcpj.eql;
const path_safety = @import("../path_safety.zig");

pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return explore_mod.matchGlob(pattern, path);
}

pub const isPathSafe = path_safety.isPathSafe;
pub const projectRelPath = path_safety.projectRelPath;
