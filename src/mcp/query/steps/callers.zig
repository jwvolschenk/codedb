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
        w.print("error: callers needs 'name'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "callers needs 'name'", step);
        return false;
    };
    const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;

    // Find definitions to exclude from caller results
    const defs = ctx.explorer.findAllSymbols(name, ctx.alloc) catch {
        w.print("error: symbol lookup failed\n", .{}) catch {};
        return false;
    };
    defer {
        for (defs) |d| {
            ctx.alloc.free(d.path);
            ctx.alloc.free(d.symbol.name);
            if (d.symbol.detail) |dd| ctx.alloc.free(dd);
            for (d.symbol.decorators) |decorator| ctx.alloc.free(decorator);
            if (d.symbol.decorators.len > 0) ctx.alloc.free(d.symbol.decorators);
            if (d.symbol.return_type) |rt| ctx.alloc.free(rt);
            for (d.symbol.param_types) |pt| ctx.alloc.free(pt);
            if (d.symbol.param_types.len > 0) ctx.alloc.free(d.symbol.param_types);
        }
        ctx.alloc.free(defs);
    }

    // Search for all occurrences with scope info
    const results = ctx.explorer.searchContentWithScope(name, ctx.alloc, max) catch {
        w.print("error: callers search failed\n", .{}) catch {};
        return false;
    };
    defer {
        for (results) |r| {
            ctx.alloc.free(r.line_text);
            ctx.alloc.free(r.path);
            if (r.scope_name) |sn| ctx.alloc.free(sn);
        }
        ctx.alloc.free(results);
    }

    // Helper: check if a result is a call site (not a definition)
    const CallSiteFilter = struct {
        fn isCallSite(r: explore_mod.Explorer.ScopedSearchResult, definition_list: []const explore_mod.SymbolResult, nm: []const u8) bool {
            if (!mcp.langHasCallSites(explore_mod.detectLanguage(r.path))) return false;
            for (definition_list) |d| {
                if (r.line_num == d.symbol.line_start and std.mem.eql(u8, r.path, d.path))
                    return false;
            }
            return mcp.hasWholeWordMatch(r.line_text, nm);
        }
    };

    if (ctx.have_set.*) {
        // Intersect: only show callers in files from current set
        var path_set = std.StringHashMap(void).init(ctx.alloc);
        defer path_set.deinit();
        for (ctx.file_set.items) |p| path_set.put(p, {}) catch {};

        var caller_files = std.StringHashMap(void).init(ctx.alloc);
        defer caller_files.deinit();

        var shown: usize = 0;
        for (results) |r| {
            if (!CallSiteFilter.isCallSite(r, defs, name)) continue;
            if (!path_set.contains(r.path)) continue;
            shown += 1;
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s}]\n", .{ r.path, r.line_num, r.line_text, sn }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            caller_files.put(r.path, {}) catch {};
            shared.recordHitLine(ctx.hit_lines, ctx.alloc, r.path, r.line_num);
        }
        // Narrow ctx.file_set to only files that had callers
        var wr: usize = 0;
        for (ctx.file_set.items) |p| {
            if (caller_files.contains(p)) {
                ctx.file_set.items[wr] = p;
                wr += 1;
            }
        }
        ctx.file_set.items.len = wr;
        w.print("{d} callers for '{s}' (within {d} candidate files)\n", .{ shown, name, path_set.count() }) catch {};
    } else {
        // Seed: set ctx.file_set to caller files
        var seen = std.StringHashMap(void).init(ctx.alloc);
        defer seen.deinit();
        ctx.file_set.clearRetainingCapacity();

        var shown: usize = 0;
        for (results) |r| {
            if (!CallSiteFilter.isCallSite(r, defs, name)) continue;
            shown += 1;
            if (r.scope_name) |sn| {
                w.print("  {s}:{d}: {s}  [in {s}]\n", .{ r.path, r.line_num, r.line_text, sn }) catch {};
            } else {
                w.print("  {s}:{d}: {s}\n", .{ r.path, r.line_num, r.line_text }) catch {};
            }
            shared.recordHitLine(ctx.hit_lines, ctx.alloc, r.path, r.line_num);
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
        w.print("{d} callers for '{s}' across {d} files:\n", .{ shown, name, ctx.file_set.items.len }) catch {};
    }
    return true;
}
