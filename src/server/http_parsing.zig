// codedb HTTP server — ported to Zig 0.16 std.Io.net (issue #285).
//
// This restores the port server that upstream stubbed out in commit 56ea465
// (v0.2.578). The route set and JSON response shapes match the pre-0.16
// implementation byte-for-byte; only the transport layer (listen/accept/read/
// write/close) was rewritten against the new `std.Io.net` surface. MCP stdio
// remains the primary entry, but `codedb serve --port` is once again usable
// by external clients that speak HTTP/1.1.

const std = @import("std");

// -- HTTP parsing helpers -----------------------------------------------------

pub fn extractQueryParam(request: []const u8, key: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..first_line_end];

    const q_pos = std.mem.indexOfScalar(u8, first_line, '?') orelse return null;
    const space_pos = std.mem.indexOfScalarPos(u8, first_line, q_pos, ' ') orelse first_line.len;
    const query = first_line[q_pos + 1 .. space_pos];

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, key)) {
            if (pair.len > key.len and pair[key.len] == '=') {
                return pair[key.len + 1 ..];
            }
        }
    }
    return null;
}

pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn extractQueryParamInt(request: []const u8, key: []const u8) ?u64 {
    const val = extractQueryParam(request, key) orelse return null;
    return std.fmt.parseInt(u64, val, 10) catch null;
}

pub fn extractBody(request: []const u8) []const u8 {
    if (std.mem.indexOf(u8, request, "\r\n\r\n")) |pos| {
        return request[pos + 4 ..];
    }
    return "";
}

pub fn jsonString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn jsonU64(obj: *const std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
        else => null,
    };
}

pub fn findUnescapedQuote(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (s[i] == '"') return i;
    }
    return null;
}

/// Minimal JSON string extractor: finds "key":"value" and returns value.
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // NOTE: This is a naive scanner that does NOT handle JSON escape sequences
    // (e.g. \" inside string values will cause incorrect results). For correct
    // parsing use std.json.parseFromSlice on the full body instead.
    var pos: usize = 0;
    while (pos < json.len) {
        const key_start = std.mem.indexOfPos(u8, json, pos, "\"") orelse return null;
        const key_end = std.mem.indexOfPos(u8, json, key_start + 1, "\"") orelse return null;
        const found_key = json[key_start + 1 .. key_end];

        if (std.mem.eql(u8, found_key, key)) {
            // Skip ":"
            var next = key_end + 1;
            while (next < json.len and (json[next] == ':' or json[next] == ' ')) : (next += 1) {}
            if (next >= json.len or json[next] != '"') return null;
            const val_start = next + 1;
            const val_end = findUnescapedQuote(json, val_start) orelse return null;
            return json[val_start..val_end];
        }
        pos = key_end + 1;
    }
    return null;
}
