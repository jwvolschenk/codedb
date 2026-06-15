const std = @import("std");
const cio = @import("../cio.zig");
const json_utils = @import("../json_utils.zig");
const mcpj = @import("mcp").json;

pub fn writeResult(alloc: std.mem.Allocator, stdout: cio.File, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.ensureTotalCapacity(alloc, result.len + 64) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    // Batch-copy non-newline runs instead of per-byte append.
    var i: usize = 0;
    while (i < result.len) {
        const start = i;
        while (i < result.len and result[i] != '\n' and result[i] != '\r') : (i += 1) {}
        if (i > start) buf.appendSlice(alloc, result[start..i]) catch return;
        if (i < result.len) i += 1;
    }
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch return;
}

pub fn writeError(alloc: std.mem.Allocator, stdout: cio.File, id: ?std.json.Value, code: i32, msg: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [12]u8 = undefined;
    const cs = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, cs) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    mcpj.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}") catch return;
    stdout.writeAll(buf.items) catch return;
    stdout.writeAll("\n") catch return;
}
/// Fast JSON string escaper: batch-copies runs of safe characters via
/// appendSlice instead of the per-byte append in mcpj.writeEscaped.
pub fn writeEscaped(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    json_utils.writeEscapedToList(alloc, out, s) catch {};
}

pub fn appendId(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), id: ?std.json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .string => |s| {
            buf.append(alloc, '"') catch return;
            mcpj.writeEscaped(alloc, buf, s);
            buf.append(alloc, '"') catch return;
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return;
            buf.appendSlice(alloc, s) catch return;
        },
        .number_string => |s| {
            buf.appendSlice(alloc, s) catch return;
        },
        else => buf.appendSlice(alloc, "null") catch return,
    } else {
        buf.appendSlice(alloc, "null") catch return;
    }
}
