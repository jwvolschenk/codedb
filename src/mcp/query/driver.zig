const std = @import("std");
const cio = @import("../../cio.zig");
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const appendBundleArgKeysDiagnostic = @import("../../mcp.zig").appendBundleArgKeysDiagnostic;
const finishQueryWithFailure = @import("../../mcp.zig").finishQueryWithFailure;
const shared = @import("shared.zig");
const Explorer = shared.Explorer;
const Store = shared.Store;

const steps = struct {
    const find = @import("steps/find.zig");
    const search = @import("steps/search.zig");
    const deps = @import("steps/deps.zig");
    const filter = @import("steps/filter.zig");
    const outline = @import("steps/outline.zig");
    const read = @import("steps/read.zig");
    const transform = @import("steps/transform.zig");
    const word = @import("steps/word.zig");
    const callers = @import("steps/callers.zig");
    const symbol = @import("steps/symbol.zig");
    const limit = @import("steps/limit.zig");
    const types = @import("steps/types.zig");
};

pub fn handleQuery(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8), explorer: *Explorer, store: *Store) void {
    const pipeline_val = args.get("pipeline") orelse {
        out.appendSlice(alloc, "error: missing 'pipeline' array") catch {};
        appendBundleArgKeysDiagnostic(alloc, out, args);
        return;
    };
    const pipeline = switch (pipeline_val) {
        .array => |a| a.items,
        else => {
            out.appendSlice(alloc, "error: 'pipeline' must be an array") catch {};
            return;
        },
    };
    if (pipeline.len == 0 or pipeline.len > 10) {
        out.appendSlice(alloc, "error: pipeline must have 1-10 steps") catch {};
        return;
    }

    var file_set: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_set.items) |p| alloc.free(p);
        file_set.deinit(alloc);
    }
    var have_set = false;

    var hit_lines = std.StringHashMap(std.ArrayList(usize)).init(alloc);
    defer {
        var hl_iter = hit_lines.iterator();
        while (hl_iter.next()) |entry| {
            entry.value_ptr.deinit(alloc);
            alloc.free(entry.key_ptr.*);
        }
        hit_lines.deinit();
    }

    const w = cio.listWriter(out, alloc);
    const StageInfo = struct { op: []const u8, files_out: usize };
    var stages: std.ArrayList(StageInfo) = .empty;
    defer stages.deinit(alloc);

    var ctx = shared.Context{
        .alloc = alloc,
        .out = out,
        .explorer = explorer,
        .store = store,
        .file_set = &file_set,
        .hit_lines = &hit_lines,
        .have_set = &have_set,
    };

    for (pipeline, 0..) |step_val, step_i| {
        if (step_val != .object) {
            w.print("error: step {d} must be object\n", .{step_i}) catch {};
            return;
        }
        const step = &step_val.object;
        const op = getStr(step, "op") orelse blk: {
            if (getStr(step, "query") != null) break :blk "search";
            if (getStr(step, "word") != null) break :blk "word";
            if (getStr(step, "name") != null) break :blk "symbol";
            w.print("error: step {d} missing 'op'\n", .{step_i}) catch {};
            finishQueryWithFailure(alloc, out, step_i, "missing 'op'", step);
            return;
        };

        const ok = if (std.mem.eql(u8, op, "find"))
            steps.find.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "search"))
            steps.search.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "deps"))
            steps.deps.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "filter"))
            steps.filter.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "outline"))
            steps.outline.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "read"))
            steps.read.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "sort"))
            steps.transform.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "word"))
            steps.word.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "callers"))
            steps.callers.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "symbol"))
            steps.symbol.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "limit"))
            steps.limit.run(&ctx, step, step_i)
        else if (std.mem.eql(u8, op, "type_search") or std.mem.eql(u8, op, "type_compat"))
            steps.types.run(&ctx, step, step_i, op)
        else blk: {
            w.print("error: unknown op '{s}'\n", .{op}) catch {};
            break :blk false;
        };
        if (!ok) return;
        stages.append(alloc, .{ .op = op, .files_out = file_set.items.len }) catch {};
    }

    if (out.items.len == 0 and have_set) {
        w.print("{d} files:\n", .{file_set.items.len}) catch {};
        for (file_set.items) |path_item| w.print("  {s}\n", .{path_item}) catch {};
    }

    if (stages.items.len > 0) {
        w.print("\n--- stages ---\n", .{}) catch {};
        for (stages.items, 0..) |s, i| {
            w.print("{d}: {s} ({d} files)\n", .{ i, s.op, s.files_out }) catch {};
        }
    }
}
