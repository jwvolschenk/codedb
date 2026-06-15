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
    const w = cio.listWriter(ctx.out, ctx.alloc);
    const query = getStr(step, "query") orelse {
        w.print("error: find needs 'query'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "find needs 'query'", step);
        return false;
    };
    const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
    const matches = ctx.explorer.fuzzyFindFiles(query, ctx.alloc, max) catch {
        w.print("error: find failed\n", .{}) catch {};
        return false;
    };
    defer ctx.alloc.free(matches);
    if (ctx.have_set.*) {
        // Intersect: keep only files from current set that also appear in find results
        var match_set = std.StringHashMap(void).init(ctx.alloc);
        defer match_set.deinit();
        for (matches) |m| match_set.put(m.path, {}) catch {};
        var wr: usize = 0;
        for (ctx.file_set.items) |p| {
            if (match_set.contains(p)) {
                ctx.file_set.items[wr] = p;
                wr += 1;
            }
        }
        ctx.file_set.items.len = wr;
        w.print("{d} files after find intersect\n", .{ctx.file_set.items.len}) catch {};
    } else {
        ctx.file_set.clearRetainingCapacity();
        w.print("{d} files matched:\n", .{matches.len}) catch {};
        for (matches) |m| {
            w.print("  {s}\n", .{m.path}) catch {};
            const duped = ctx.alloc.dupe(u8, m.path) catch continue;
            ctx.file_set.append(ctx.alloc, duped) catch {
                ctx.alloc.free(duped);
                continue;
            };
        }
        ctx.have_set.* = true;
    }
    return true;
}
