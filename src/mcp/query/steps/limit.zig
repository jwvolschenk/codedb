const std = @import("std");
const cio = @import("../../../cio.zig");
const explore_mod = @import("../../../explore.zig");
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const globMatch = @import("../../pathglob.zig").globMatch;
const mcp = @import("../../../mcp.zig");
const finishQueryWithFailure = mcp.finishQueryWithFailure;
const combo_boost = @import("../combo_boost.zig");
const shared = @import("../shared.zig");

pub fn run(ctx: *shared.Context, step: *const std.json.ObjectMap, step_i: usize) bool {
    _ = step_i;
    const w = cio.listWriter(ctx.out, ctx.alloc);
    if (!ctx.have_set.*) {
        w.print("error: limit needs prior step\n", .{}) catch {};
        return false;
    }
    const n: usize = if (getInt(step, "n")) |i| @intCast(@max(1, @min(i, 100))) else 10;
    if (ctx.file_set.items.len > n) ctx.file_set.items.len = n;
    return true;
}
