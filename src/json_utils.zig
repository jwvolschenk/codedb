// JSON string escaping — shared across HTTP server, MCP server, snapshot
// writer, and WASM bindings.
//
// Two IO surfaces:
//   writeEscapedToWriter — generic `anytype` writer (used with cio.listWriter,
//                          std.io.Writer, etc.); per-byte/short-run writes.
//   writeEscapedToList   — std.ArrayList(u8) + allocator; batched appendSlice
//                          for hot paths (the algorithm mcp/jsonio.zig used).
//
// Both emit the same JSON string escape: `\"`, `\\`, `\n`, `\r`, `\t`, and
// `\u00XX` for other control chars (< 0x20). Lossy sanitizers that produce
// non-JSON output (parse_utils.writeJsonEscaped, wal.escapeJsonStr) are
// intentionally NOT unified with these — different semantics.

const std = @import("std");

pub fn writeEscapedToWriter(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try writer.writeAll(&esc);
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

/// Batched version: copies runs of safe characters via appendSlice.
/// Significantly faster than per-byte append on hot paths.
pub fn writeEscapedToList(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }
        if (i > start) try out.appendSlice(alloc, s[start..i]);
        if (i >= s.len) break;
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                const hex = "0123456789abcdef";
                const esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try out.appendSlice(alloc, &esc);
            },
        }
        i += 1;
    }
}
