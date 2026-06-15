// codedb MCP — codedb_query pipeline handler + combo-boost reranking.
const std = @import("std");
const cio = @import("../../cio.zig");
const explore_mod = @import("../../explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("../../store.zig").Store;
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const eql = mcpj.eql;
const wal = @import("../wal.zig");
const globMatch = @import("../pathglob.zig").globMatch;
const mcp = @import("../../mcp.zig");
const appendBundleArgKeysDiagnostic = mcp.appendBundleArgKeysDiagnostic;
const finishQueryWithFailure = mcp.finishQueryWithFailure;

const COMBO_WINDOW_MS: i64 = 5000; // 5 second window between query and file open
const COMBO_BOOST_PER_HIT: f32 = 5.0; // score boost per historical open

pub fn applyComboBoosts(io: std.Io, alloc: std.mem.Allocator, query: []const u8, matches: []explore_mod.Explorer.FuzzyMatch) void {
    const wal_path = wal.logPath() orelse return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, wal_path, alloc, .limited(512 * 1024)) catch return;
    defer alloc.free(data);

    // Scan WAL for query→access pairs within COMBO_WINDOW_MS
    var boosts = std.StringHashMap(f32).init(alloc);
    defer boosts.deinit();

    var last_query_ts: i64 = 0;
    var last_query_match = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 10) continue;

        if (std.mem.indexOf(u8, line, "\"ev\":\"query\"")) |_| {
            // Check if this query matches the current one (case-insensitive substring)
            var qbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "query", &qbuf)) |logged_query| {
                last_query_match = std.mem.indexOf(u8, logged_query, query) != null or
                    std.mem.indexOf(u8, query, logged_query) != null;
            } else {
                last_query_match = false;
            }
            last_query_ts = extractJsonIntLocal(line, "ts") orelse 0;
        } else if (std.mem.indexOf(u8, line, "\"ev\":\"access\"")) |_| {
            if (!last_query_match) continue;
            const access_ts = extractJsonIntLocal(line, "ts") orelse continue;
            if (access_ts - last_query_ts > COMBO_WINDOW_MS) continue;

            var pbuf: [256]u8 = undefined;
            if (extractJsonStrLocal(line, "path", &pbuf)) |path| {
                const gop = boosts.getOrPut(path) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += COMBO_BOOST_PER_HIT;
            }
        }
    }

    if (boosts.count() == 0) return;

    // Apply boosts to matching results
    var boosted = false;
    for (matches) |*m| {
        if (boosts.get(m.path)) |boost| {
            m.score += boost;
            boosted = true;
        }
    }

    // Re-sort if any scores changed
    if (boosted) {
        std.mem.sort(explore_mod.Explorer.FuzzyMatch, matches, {}, struct {
            fn lt(_: void, a: explore_mod.Explorer.FuzzyMatch, b: explore_mod.Explorer.FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);
    }
}

pub fn extractJsonIntLocal(line: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    var end = start;
    while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, line[start..end], 10) catch null;
}

pub fn extractJsonStrLocal(line: []const u8, key: []const u8, out: *[256]u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, line, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    const len = @min(end - start, out.len);
    @memcpy(out[0..len], line[start..][0..len]);
    return out[0..len];
}

/// Record a hit line number for a file in the hit_lines map.
/// Used by search/word/callers pipeline steps to enable context-aware reads.
fn recordHitLine(hit_map: *std.StringHashMap(std.ArrayList(usize)), al: std.mem.Allocator, path: []const u8, line: u32) void {
    if (hit_map.getPtr(path)) |hl| {
        hl.append(al, line) catch {};
    } else {
        const key = al.dupe(u8, path) catch return;
        var new_list: std.ArrayList(usize) = .empty;
        new_list.append(al, line) catch return;
        hit_map.put(key, new_list) catch {
            al.free(key);
            new_list.deinit(al);
            return;
        };
    }
}
