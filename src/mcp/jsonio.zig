const std = @import("std");
const cio = @import("../cio.zig");
const json_utils = @import("../json_utils.zig");
const mcpj = @import("mcp").json;
const release_info = @import("../release_info.zig");

/// Every result object gains `resultType:"complete"` and `_meta` serverInfo
/// here (MCP 2026-07-28) — the single splice point for initialize,
/// tools/list, tools/call, and ping. Payloads that already declare
/// resultType (server/discover) pass through unchanged; clients on older
/// protocol revisions ignore the extra members.
pub const result_meta_prelude = "{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"codedb\",\"version\":\"" ++ release_info.semver ++ "\"}}";

pub fn writeResult(alloc: std.mem.Allocator, stdout: cio.File, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.ensureTotalCapacity(alloc, result.len + 64 + result_meta_prelude.len) catch {};
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    var payload = result;
    if (result.len >= 2 and result[0] == '{' and !std.mem.startsWith(u8, result, "{\"resultType\"")) {
        buf.appendSlice(alloc, result_meta_prelude) catch return;
        if (std.mem.eql(u8, result, "{}")) {
            buf.appendSlice(alloc, "}") catch return;
            payload = "";
        } else {
            buf.appendSlice(alloc, ",") catch return;
            payload = result[1..];
        }
    }
    // Batch-copy non-newline runs instead of per-byte append.
    var i: usize = 0;
    while (i < payload.len) {
        const start = i;
        while (i < payload.len and payload[i] != '\n' and payload[i] != '\r') : (i += 1) {}
        if (i > start) buf.appendSlice(alloc, payload[start..i]) catch return;
        if (i < payload.len) i += 1;
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
