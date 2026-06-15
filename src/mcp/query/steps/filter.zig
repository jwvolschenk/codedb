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
    if (!ctx.have_set.*) {
        ctx.explorer.mu.lockShared();
        var iter = ctx.explorer.outlines.keyIterator();
        while (iter.next()) |k| {
            const duped = ctx.alloc.dupe(u8, k.*) catch continue;
            ctx.file_set.append(ctx.alloc, duped) catch {
                ctx.alloc.free(duped);
                continue;
            };
        }
        ctx.explorer.mu.unlockShared();
        ctx.have_set.* = true;
    }
    const ext = getStr(step, "ext");
    const glob_pat = getStr(step, "glob");
    var wr: usize = 0;
    for (ctx.file_set.items) |path| {
        var keep = true;
        if (ext) |e| {
            if (!std.mem.endsWith(u8, path, e)) keep = false;
        }
        if (keep) if (glob_pat) |g| {
            if (!globMatch(g, path)) keep = false;
        };
        if (keep) {
            ctx.file_set.items[wr] = path;
            wr += 1;
        }
    }
    ctx.file_set.items.len = wr;
    return true;
}
