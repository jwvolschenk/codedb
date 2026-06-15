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
        w.print("error: sort needs prior step\n", .{}) catch {};
        return false;
    }
    const by = getStr(step, "by") orelse "path";
    if (std.mem.eql(u8, by, "path")) {
        std.mem.sort([]const u8, ctx.file_set.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
    }
    // "score" sorting is implicit from find — no re-sort needed
    return true;
}
