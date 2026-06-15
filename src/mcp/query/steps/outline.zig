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
    // Accepts optional 'path' for standalone single-file outline.
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
            w.print("error: outline needs prior step or 'path' param\n", .{}) catch {};
            return false;
        }
    }
    for (ctx.file_set.items) |path| {
        var outline = ctx.explorer.getOutline(path, ctx.alloc) catch continue;
        if (outline) |*o| {
            defer o.deinit();
            w.print("--- {s} ({s}, {d} sym) ---\n", .{ path, @tagName(o.language), o.symbols.items.len }) catch {};
            for (o.symbols.items) |sym| w.print("  L{d} {s} {s}\n", .{ sym.line_start, @tagName(sym.kind), sym.name }) catch {};
        }
        if (ctx.out.items.len > 100 * 1024) {
            w.print("... truncated\n", .{}) catch {};
            break;
        }
    }
    return true;
}
