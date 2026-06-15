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
    // Expand file set by adding dependents/dependencies of current files.
    // Accepts optional 'path' for standalone use without a prior seeding step.
    if (!ctx.have_set.*) {
        if (getStr(step, "path")) |p| {
            const duped = ctx.alloc.dupe(u8, p) catch {
                w.print("error: ctx.out of memory\n", .{}) catch {};
                return false;
            };
            ctx.file_set.append(ctx.alloc, duped) catch {
                ctx.alloc.free(duped);
                w.print("error: ctx.out of memory\n", .{}) catch {};
                return false;
            };
            ctx.have_set.* = true;
        } else {
            w.print("error: deps needs prior step or 'path' param\n", .{}) catch {};
            return false;
        }
    }
    const direction = getStr(step, "direction") orelse "imported_by";
    const transitive = getBool(step, "transitive");
    const max_depth_val: ?u32 = if (getInt(step, "max_depth")) |n| @intCast(@max(1, n)) else null;
    const is_forward = std.mem.eql(u8, direction, "depends_on");

    var expanded = std.StringHashMap(void).init(ctx.alloc);
    defer expanded.deinit();
    for (ctx.file_set.items) |path| expanded.put(path, {}) catch {};

    // Snapshot current file set since we'll append to it
    const current_len = ctx.file_set.items.len;
    for (ctx.file_set.items[0..current_len]) |path| {
        var deps_result: []const []const u8 = &.{};
        var needs_free = false;

        if (is_forward) {
            if (transitive) {
                deps_result = ctx.explorer.getTransitiveDependencies(path, ctx.alloc, max_depth_val) catch continue;
                needs_free = true;
            } else {
                ctx.explorer.mu.lockShared();
                const fwd = ctx.explorer.dep_graph.getForwardDeps(path);
                ctx.explorer.mu.unlockShared();
                if (fwd) |deps| {
                    var res: std.ArrayList([]const u8) = .empty;
                    for (deps) |dep| {
                        const d = ctx.alloc.dupe(u8, dep) catch continue;
                        res.append(ctx.alloc, d) catch {
                            ctx.alloc.free(d);
                            continue;
                        };
                    }
                    deps_result = res.toOwnedSlice(ctx.alloc) catch &.{};
                    needs_free = true;
                }
            }
        } else {
            if (transitive) {
                deps_result = ctx.explorer.getTransitiveDependents(path, ctx.alloc, max_depth_val) catch continue;
            } else {
                deps_result = ctx.explorer.getImportedBy(path, ctx.alloc) catch continue;
            }
            needs_free = true;
        }

        defer if (needs_free) {
            for (deps_result) |dep| ctx.alloc.free(dep);
            ctx.alloc.free(deps_result);
        };

        for (deps_result) |dep| {
            if (!expanded.contains(dep)) {
                expanded.put(dep, {}) catch {};
                ctx.file_set.append(ctx.alloc, dep) catch {};
            }
        }
    }
    return true;
}
