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
const skip_rules = @import("../../../watcher/skip_rules.zig");

pub fn run(ctx: *shared.Context, step: *const std.json.ObjectMap, step_i: usize) bool {
    const w = cio.listWriter(ctx.out, ctx.alloc);
    const query = getStr(step, "query") orelse {
        w.print("error: search needs 'query'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "search needs 'query'", step);
        return false;
    };
    const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
    const include_generated = getBool(step, "include_generated");
    const exclude_generated = !include_generated;
    const results = ctx.explorer.searchContent(query, ctx.alloc, max) catch {
        w.print("error: search failed\n", .{}) catch {};
        return false;
    };
    defer {
        for (results) |r| {
            ctx.alloc.free(r.line_text);
            ctx.alloc.free(r.path);
        }
        ctx.alloc.free(results);
    }
    if (ctx.have_set.*) {
        // Intersect: only keep files from current set that have search hits
        var hit_set = std.StringHashMap(void).init(ctx.alloc);
        defer hit_set.deinit();
        var path_set = std.StringHashMap(void).init(ctx.alloc);
        defer path_set.deinit();
        for (ctx.file_set.items) |p| path_set.put(p, {}) catch {};
        for (results) |r| {
            if (exclude_generated and skip_rules.isGeneratedPath(r.path)) continue;
            if (path_set.contains(r.path)) {
                w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
                hit_set.put(r.path, {}) catch {};
                shared.recordHitLine(ctx.hit_lines, ctx.alloc, r.path, r.line_num);
            }
        }
        // Narrow ctx.file_set to only files that had hits
        var wr: usize = 0;
        for (ctx.file_set.items) |p| {
            if (hit_set.contains(p)) {
                ctx.file_set.items[wr] = p;
                wr += 1;
            }
        }
        ctx.file_set.items.len = wr;
    } else {
        var seen = std.StringHashMap(void).init(ctx.alloc);
        defer seen.deinit();
        ctx.file_set.clearRetainingCapacity();
        for (results) |r| {
            if (exclude_generated and skip_rules.isGeneratedPath(r.path)) continue;
            w.print("{s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            shared.recordHitLine(ctx.hit_lines, ctx.alloc, r.path, r.line_num);
            if (!seen.contains(r.path)) {
                // Dupe path — search results are freed by the defer above,
                // but ctx.file_set must outlive this step for downstream ops
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
