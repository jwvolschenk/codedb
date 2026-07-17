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
    const name = getStr(step, "name") orelse {
        w.print("error: callers needs 'name'\n", .{}) catch {};
        finishQueryWithFailure(ctx.alloc, ctx.out, step_i, "callers needs 'name'", step);
        return false;
    };
    const max: usize = if (getInt(step, "max_results")) |n| @intCast(@max(1, @min(n, 200))) else 50;
    const include_generated = getBool(step, "include_generated");
    const exclude_generated = !include_generated;
    const requested_mode = getStr(step, "match_mode");

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
    // Auto-broaden to whole-word references when the resolved symbol is a
    // type definition — types are referenced, not "called".
    const match_mode = mcp.effectiveMatchMode(requested_mode, defs);

    // Search for all occurrences with scope info. In references mode, merge
    // structural type references so recall isn't capped by content ranking.
    const results = (if (std.mem.eql(u8, match_mode, "references"))
        ctx.explorer.searchReferencesWithScope(name, ctx.alloc, max)
    else
        ctx.explorer.searchContentWithScope(name, ctx.alloc, max)) catch {
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
        fn isCallSite(r: explore_mod.Explorer.ScopedSearchResult, definition_list: []const explore_mod.SymbolResult, nm: []const u8, mode: []const u8) bool {
            const lang = explore_mod.detectLanguage(r.path);
            if (!mcp.langHasCallSites(lang)) return false;
            if (mcp.excludeAsDefinitionLine(r.path, r.line_num, r.line_text, nm, definition_list))
                return false;
            return mcp.callerLineMatches(r.line_text, nm, lang, mode);
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
            if (!CallSiteFilter.isCallSite(r, defs, name, match_mode)) continue;
            if (exclude_generated and skip_rules.isGeneratedPath(r.path)) continue;
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
        const noun: []const u8 = if (std.mem.eql(u8, match_mode, "references")) "references" else "callers";
        w.print("{d} {s} for '{s}' (within {d} candidate files)\n", .{ shown, noun, name, path_set.count() }) catch {};
    } else {
        // Seed: set ctx.file_set to caller files
        var seen = std.StringHashMap(void).init(ctx.alloc);
        defer seen.deinit();
        ctx.file_set.clearRetainingCapacity();

        var shown: usize = 0;
        for (results) |r| {
            if (!CallSiteFilter.isCallSite(r, defs, name, match_mode)) continue;
            if (exclude_generated and skip_rules.isGeneratedPath(r.path)) continue;
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
        const noun: []const u8 = if (std.mem.eql(u8, match_mode, "references")) "references" else "callers";
        w.print("{d} {s} for '{s}' across {d} files:\n", .{ shown, noun, name, ctx.file_set.items.len }) catch {};
    }
    return true;
}
