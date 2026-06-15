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

pub fn run(ctx: *shared.Context, step: *const std.json.ObjectMap, step_i: usize, op: []const u8) bool {
    const w = cio.listWriter(ctx.out, ctx.alloc);
    if (std.mem.eql(u8, op, "type_search")) {
        const return_type = getStr(step, "return_type");
        const param_type = getStr(step, "param_type");
        if (return_type == null and param_type == null) {
            w.print("error: type_search needs 'return_type' or 'param_type'\n", .{}) catch {};
            finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "type_search needs 'return_type' or 'param_type'", step);
            return false;
        }
        const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 1000))) else 50;
        var shown: usize = 0;
        if (return_type) |rt| {
            const hits = ctx.explorer.type_index.findByReturnType(rt);
            for (hits) |hit| {
                if (shown >= max) break;
                if (ctx.have_set.*) {
                    var in_set = false;
                    for (ctx.file_set.items) |p| {
                        if (std.mem.eql(u8, p, hit.path)) {
                            in_set = true;
                            break;
                        }
                    }
                    if (!in_set) continue;
                }
                w.print("  {s}:{d} {s} -> {s}\n", .{ hit.path, hit.line_start, hit.symbol_name, rt }) catch {};
                shown += 1;
                // Track hit line for context-aware reads
                shared.recordHitLine(ctx.hit_lines, ctx.alloc, hit.path, hit.line_start);
            }
        }
        if (param_type) |pt| {
            const hits = ctx.explorer.type_index.findByParamType(pt);
            for (hits) |hit| {
                if (shown >= max) break;
                if (ctx.have_set.*) {
                    var in_set = false;
                    for (ctx.file_set.items) |p| {
                        if (std.mem.eql(u8, p, hit.path)) {
                            in_set = true;
                            break;
                        }
                    }
                    if (!in_set) continue;
                }
                w.print("  {s}:{d} {s} ({s})\n", .{ hit.path, hit.line_start, hit.symbol_name, pt }) catch {};
                shown += 1;
                shared.recordHitLine(ctx.hit_lines, ctx.alloc, hit.path, hit.line_start);
            }
        }
        // Narrow ctx.file_set to files with type hits
        if (ctx.have_set.*) {
            // Already filtered by intersection above
        } else {
            // Build file set from hits
            var seen_types = std.StringHashMap(void).init(ctx.alloc);
            defer seen_types.deinit();
            if (return_type) |rt| {
                for (ctx.explorer.type_index.findByReturnType(rt)) |hit| {
                    if (!seen_types.contains(hit.path)) {
                        seen_types.put(hit.path, {}) catch continue;
                        const duped = ctx.alloc.dupe(u8, hit.path) catch continue;
                        ctx.file_set.append(ctx.alloc, duped) catch {
                            ctx.alloc.free(duped);
                            continue;
                        };
                    }
                }
            }
            if (param_type) |pt| {
                for (ctx.explorer.type_index.findByParamType(pt)) |hit| {
                    if (!seen_types.contains(hit.path)) {
                        seen_types.put(hit.path, {}) catch continue;
                        const duped = ctx.alloc.dupe(u8, hit.path) catch continue;
                        ctx.file_set.append(ctx.alloc, duped) catch {
                            ctx.alloc.free(duped);
                            continue;
                        };
                    }
                }
            }
            ctx.have_set.* = true;
        }
        w.print("{d} type hits\n", .{shown}) catch {};
    } else if (std.mem.eql(u8, op, "type_compat")) {
        // Find all types that implement/extend a given base type
        const base_name = getStr(step, "name") orelse {
            w.print("error: type_compat needs 'name'\n", .{}) catch {};
            finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "type_compat needs 'name'", step);
            return false;
        };
        const derived = ctx.explorer.type_graph.getDerived(base_name);
        if (derived.len == 0) {
            w.print("no types implementing '{s}' found\n", .{base_name}) catch {};
        } else {
            w.print("{d} types implementing '{s}':\n", .{ derived.len, base_name }) catch {};
            for (derived) |d| {
                w.print("  {s}\n", .{d}) catch {};
            }
        }
        // Build file set from derived types' definitions
        if (!ctx.have_set.*) {
            for (derived) |derived_name| {
                const hits = ctx.explorer.type_index.findByReturnType(derived_name);
                for (hits) |hit| {
                    const duped = ctx.alloc.dupe(u8, hit.path) catch continue;
                    ctx.file_set.append(ctx.alloc, duped) catch {
                        ctx.alloc.free(duped);
                        continue;
                    };
                }
            }
            ctx.have_set.* = true;
        }
    }
    return true;
}
