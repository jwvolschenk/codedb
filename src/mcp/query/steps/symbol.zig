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
    const name = getStr(step, "name") orelse {
        w.print("error: symbol needs 'name'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "symbol needs 'name'", step);
        return false;
    };
    const results = ctx.explorer.findAllSymbols(name, ctx.alloc) catch {
        w.print("error: symbol search failed\n", .{}) catch {};
        return false;
    };
    defer {
        for (results) |r| {
            ctx.alloc.free(r.path);
            ctx.alloc.free(r.symbol.name);
            if (r.symbol.detail) |d| ctx.alloc.free(d);
            for (r.symbol.decorators) |decorator| ctx.alloc.free(decorator);
            if (r.symbol.decorators.len > 0) ctx.alloc.free(r.symbol.decorators);
            if (r.symbol.return_type) |rt| ctx.alloc.free(rt);
            for (r.symbol.param_types) |pt| ctx.alloc.free(pt);
            if (r.symbol.param_types.len > 0) ctx.alloc.free(r.symbol.param_types);
        }
        ctx.alloc.free(results);
    }
    var seen = std.StringHashMap(void).init(ctx.alloc);
    defer seen.deinit();
    w.print("{d} symbols '{s}':\n", .{ results.len, name }) catch {};
    for (results) |r| {
        w.print("  {s}:{d} ({s})\n", .{ r.path, r.symbol.line_start, @tagName(r.symbol.kind) }) catch {};
    }
    if (!ctx.have_set.*) {
        ctx.file_set.clearRetainingCapacity();
        for (results) |r| {
            if (!seen.contains(r.path)) {
                const duped = ctx.alloc.dupe(u8, r.path) catch continue;
                seen.put(duped, {}) catch {
                    ctx.alloc.free(duped);
                    continue;
                };
                ctx.file_set.append(ctx.alloc, duped) catch {
                    ctx.alloc.free(duped);
                    continue;
                };
            }
        }
        ctx.have_set.* = true;
    }
    return true;
}
