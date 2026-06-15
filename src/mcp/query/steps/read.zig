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
    // Accepts optional 'path' for standalone single-file read.
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
            w.print("error: read needs prior step or 'path' param\n", .{}) catch {};
            return false;
        }
    }
    const context_lines: usize = if (getInt(step, "context_lines")) |n| @intCast(@max(1, @min(n, 50))) else 0;
    const max_lines: usize = if (getInt(step, "lines")) |n| @intCast(@max(1, @min(n, 200))) else 50;
    for (ctx.file_set.items) |path| {
        const content = ctx.explorer.getContent(path, ctx.alloc) catch continue;
        if (content) |data| {
            defer ctx.alloc.free(data);
            w.print("--- {s} ---\n", .{path}) catch {};

            if (context_lines > 0) {
                // Context-aware read: show lines around hits from prior steps
                const hits_opt = ctx.hit_lines.get(path);
                if (hits_opt) |hits_list| {
                    // Sort hit line numbers
                    std.mem.sort(usize, hits_list.items, {}, std.sort.asc(usize));

                    // Build merged windows [hit-ctx, hit+ctx]
                    const Window = struct { start: usize, end: usize };
                    var windows: std.ArrayList(Window) = .empty;
                    defer windows.deinit(ctx.alloc);

                    for (hits_list.items) |hit_line| {
                        const win_start: usize = if (hit_line > context_lines) hit_line - context_lines else 1;
                        const win_end: usize = hit_line + context_lines;

                        if (windows.items.len > 0) {
                            const last = &windows.items[windows.items.len - 1];
                            if (win_start <= last.end + 1) {
                                last.end = @max(last.end, win_end);
                                continue;
                            }
                        }
                        windows.append(ctx.alloc, .{ .start = win_start, .end = win_end }) catch {};
                    }

                    // Output lines within windows, with ... between gaps
                    var ln: usize = 1;
                    var win_idx: usize = 0;
                    var prev_printed = false;
                    var line_it = std.mem.splitScalar(u8, data, '\n');
                    while (line_it.next()) |line| {
                        // Advance past completed windows
                        while (win_idx < windows.items.len and ln > windows.items[win_idx].end) {
                            win_idx += 1;
                            prev_printed = false;
                        }
                        if (win_idx >= windows.items.len) break;

                        const win = windows.items[win_idx];
                        if (ln >= win.start and ln <= win.end) {
                            if (!prev_printed and win_idx > 0) {
                                w.print("  ...\n", .{}) catch {};
                            }
                            w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                            prev_printed = true;
                        }
                        ln += 1;
                    }
                } else {
                    // No hits for this file — fall back to reading from start
                    var ln: usize = 1;
                    var line_it = std.mem.splitScalar(u8, data, '\n');
                    while (line_it.next()) |line| {
                        if (ln > max_lines) {
                            w.print("  ... (truncated)\n", .{}) catch {};
                            break;
                        }
                        w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                        ln += 1;
                    }
                }
            } else {
                // Original behavior: read from start
                var ln: usize = 1;
                var line_it = std.mem.splitScalar(u8, data, '\n');
                while (line_it.next()) |line| {
                    if (ln > max_lines) {
                        w.print("  ... (truncated)\n", .{}) catch {};
                        break;
                    }
                    w.print("{d:>4}| {s}\n", .{ ln, line }) catch {};
                    ln += 1;
                }
            }
        }
        if (ctx.out.items.len > 100 * 1024) {
            w.print("... truncated\n", .{}) catch {};
            break;
        }
    }
    return true;
}
