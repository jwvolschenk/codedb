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
    const word = getStr(step, "word") orelse {
        w.print("error: word needs 'word'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "word needs 'word'", step);
        return false;
    };
    const include_generated = getBool(step, "include_generated");
    const exclude_generated = !include_generated;
    const hits = ctx.explorer.searchWord(word, ctx.alloc) catch {
        w.print("error: word search failed\n", .{}) catch {};
        return false;
    };
    defer ctx.alloc.free(hits);
    if (ctx.have_set.*) {
        // Intersect: only show hits from files in current set
        var path_set = std.StringHashMap(void).init(ctx.alloc);
        defer path_set.deinit();
        var hit_set = std.StringHashMap(void).init(ctx.alloc);
        defer hit_set.deinit();
        for (ctx.file_set.items) |p| path_set.put(p, {}) catch {};
        ctx.explorer.mu.lockShared();
        defer ctx.explorer.mu.unlockShared();
        for (hits) |h| {
            const hp = ctx.explorer.word_index.hitPath(h);
            if (exclude_generated and skip_rules.isGeneratedPath(hp)) continue;
            if (path_set.contains(hp)) {
                w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
                hit_set.put(hp, {}) catch {};
                shared.recordHitLine(ctx.hit_lines, ctx.alloc, hp, h.line_num);
            }
        }
        var wr: usize = 0;
        for (ctx.file_set.items) |p| {
            if (hit_set.contains(p)) {
                ctx.file_set.items[wr] = p;
                wr += 1;
            }
        }
        ctx.file_set.items.len = wr;
    } else {
        ctx.explorer.mu.lockShared();
        defer ctx.explorer.mu.unlockShared();
        var seen = std.StringHashMap(void).init(ctx.alloc);
        defer seen.deinit();
        w.print("{d} word hits for '{s}':\n", .{ hits.len, word }) catch {};
        ctx.file_set.clearRetainingCapacity();
        for (hits) |h| {
            const hp = ctx.explorer.word_index.hitPath(h);
            if (exclude_generated and skip_rules.isGeneratedPath(hp)) continue;
            w.print("  {s}:{d}\n", .{ hp, h.line_num }) catch {};
            shared.recordHitLine(ctx.hit_lines, ctx.alloc, hp, h.line_num);
            if (!seen.contains(hp)) {
                const duped = ctx.alloc.dupe(u8, hp) catch continue;
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
