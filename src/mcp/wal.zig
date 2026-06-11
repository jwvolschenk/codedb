const std = @import("std");
const cio = @import("../cio.zig");

// Query tracking — append-only WAL in ~/.codedb/projects/<hash>/queries.log
var query_log_path: ?[]const u8 = null;

pub fn setQueryLogPath(path: []const u8) void {
    query_log_path = path;
}

pub fn escapeJsonStr(input: []const u8, out: *[256]u8) usize {
    var elen: usize = 0;
    for (input) |c| {
        if (elen >= out.len - 1) break;
        if (c == '"') {
            out[elen] = '\'';
            elen += 1;
        } else if (c == '\\') {
            if (elen + 1 < out.len) {
                out[elen] = '\\';
                out[elen + 1] = '\\';
                elen += 2;
            }
        } else if (c == '\n' or c == '\r' or c == '\t') {
            out[elen] = ' ';
            elen += 1;
        } else {
            out[elen] = c;
            elen += 1;
        }
    }
    return elen;
}

pub fn appendToWal(io: std.Io, line: []const u8) void {
    const path = query_log_path orelse return;
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch blk: {
        break :blk std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    };
    defer file.close(io);
    const end_offset = file.length(io) catch return;
    file.writePositionalAll(io, line, end_offset) catch {};
}

pub fn logQuery(io: std.Io, tool: []const u8, query: []const u8, result_bytes: usize, latency_ns: i128) void {
    var escaped: [256]u8 = undefined;
    const elen = escapeJsonStr(query, &escaped);
    const latency_us: i64 = @intCast(@divTrunc(latency_ns, 1000));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"ev\":\"query\",\"tool\":\"{s}\",\"query\":\"{s}\",\"result_bytes\":{d},\"latency_us\":{d}}}\n", .{
        cio.milliTimestamp(), tool, escaped[0..elen], result_bytes, latency_us,
    }) catch return;
    appendToWal(io, line);
}

pub fn logFileAccess(io: std.Io, tool: []const u8, file_path: []const u8, latency_ns: i128) void {
    var escaped: [256]u8 = undefined;
    const elen = escapeJsonStr(file_path, &escaped);
    const latency_us: i64 = @intCast(@divTrunc(latency_ns, 1000));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"ev\":\"access\",\"tool\":\"{s}\",\"path\":\"{s}\",\"latency_us\":{d}}}\n", .{
        cio.milliTimestamp(), tool, escaped[0..elen], latency_us,
    }) catch return;
    appendToWal(io, line);
}

pub fn logPath() ?[]const u8 {
    return query_log_path;
}
