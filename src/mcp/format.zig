const std = @import("std");
const mcpj = @import("mcp").json;
const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;
const eql = mcpj.eql;

// ── MCP UX: 3-block response helpers ────────────────────────────────────────
// Colors are always on — MCP preview pane always renders ANSI. No TTY check.

pub const MCP_RESET = "\x1b[0m";
pub const MCP_BOLD = "\x1b[1m";
pub const MCP_DIM = "\x1b[2m";
pub const MCP_GREEN = "\x1b[32m";
pub const MCP_RED = "\x1b[31m";
pub const MCP_CYAN = "\x1b[36m";
pub const MCP_YELLOW = "\x1b[33m";
pub const MCP_MAGENTA = "\x1b[35m";
pub const MCP_BLUE = "\x1b[34m";
pub const MCP_BRIGHT_GREEN = "\x1b[92m";

pub const MCP_CHECK = "\xe2\x9c\x93"; // ✓
pub const MCP_CROSS = "\xe2\x9c\x97"; // ✗
pub const MCP_DASH = " \xe2\x80\x94 "; //  —
pub const MCP_ARROW = "\xe2\x86\x92 "; // →
pub const MCP_DOT = "\xe2\x80\xa2 "; // •
pub const MCP_ZAP = "\xe2\x9a\xa1"; // ⚡

pub fn mcpFormatDuration(buf: []u8, ns: i128) []const u8 {
    if (ns <= 0) return "";
    const uns: u64 = @intCast(@min(ns, std.math.maxInt(u64)));
    if (uns < 1_000) {
        return std.fmt.bufPrint(buf, "  " ++ MCP_CYAN ++ MCP_ZAP ++ " {d}ns" ++ MCP_RESET, .{uns}) catch "";
    } else if (uns < 1_000_000) {
        const us = uns / 1_000;
        const frac = (uns % 1_000) / 100;
        return std.fmt.bufPrint(buf, "  " ++ MCP_CYAN ++ MCP_ZAP ++ " {d}.{d}\xc2\xb5s" ++ MCP_RESET, .{ us, frac }) catch "";
    } else if (uns < 1_000_000_000) {
        const ms = uns / 1_000_000;
        const frac = (uns % 1_000_000) / 100_000;
        if (ms < 10) {
            return std.fmt.bufPrint(buf, "  " ++ MCP_BRIGHT_GREEN ++ MCP_ZAP ++ " {d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        } else if (ms < 100) {
            return std.fmt.bufPrint(buf, "  " ++ MCP_GREEN ++ "{d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "  " ++ MCP_BLUE ++ "{d}.{d}ms" ++ MCP_RESET, .{ ms, frac }) catch "";
        }
    } else {
        const s = uns / 1_000_000_000;
        const frac = (uns % 1_000_000_000) / 100_000_000;
        return std.fmt.bufPrint(buf, "  " ++ MCP_YELLOW ++ "{d}.{d}s" ++ MCP_RESET, .{ s, frac }) catch "";
    }
}

pub fn mcpToolIcon(tool_name: []const u8) []const u8 {
    if (eql(tool_name, "codedb_outline")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_symbol")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_read")) return MCP_BLUE ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_search")) return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_word")) return MCP_CYAN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_edit")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_tree")) return MCP_GREEN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_hot")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_deps")) return MCP_CYAN ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_changes")) return MCP_YELLOW ++ MCP_DOT ++ MCP_RESET;
    if (eql(tool_name, "codedb_bundle")) return MCP_MAGENTA ++ MCP_DOT ++ MCP_RESET;
    return MCP_DIM ++ MCP_DOT ++ MCP_RESET;
}

pub fn mcpPathBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| return path[pos + 1 ..];
    return path;
}

pub fn mcpPathParent(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| return path[0..pos];
    return "";
}

pub fn mcpAppendPath(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), path: []const u8) void {
    const name = mcpPathBasename(path);
    const parent = mcpPathParent(path);
    if (parent.len > 0) {
        buf.appendSlice(alloc, MCP_DIM) catch {};
        buf.appendSlice(alloc, parent) catch {};
        buf.appendSlice(alloc, "/" ++ MCP_RESET) catch {};
    }
    buf.appendSlice(alloc, MCP_BOLD) catch {};
    buf.appendSlice(alloc, name) catch {};
    buf.appendSlice(alloc, MCP_RESET) catch {};
}

pub fn mcpGenerateSummary(
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: *const std.json.ObjectMap,
    output: []const u8,
    is_error: bool,
    buf: *std.ArrayList(u8),
) void {
    // Readable label: strip "codedb_" prefix
    const label = if (std.mem.indexOf(u8, tool_name, "_")) |i| tool_name[i + 1 ..] else tool_name;
    buf.appendSlice(alloc, MCP_BOLD) catch {};
    buf.appendSlice(alloc, label) catch {};
    buf.appendSlice(alloc, MCP_RESET) catch {};

    if (is_error) {
        const msg = if (std.mem.startsWith(u8, output, "error: ")) output[7..] else output;
        const end = std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len;
        buf.appendSlice(alloc, MCP_DASH ++ MCP_RED) catch {};
        buf.appendSlice(alloc, msg[0..end]) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
        // Issue #367-dx: surface the received-keys diagnostic inline so clients
        // that only render content[0] (the TTY summary block) still see it.
        if (std.mem.indexOf(u8, output, "received keys: [")) |s| {
            const kstart = s + "received keys: [".len;
            if (std.mem.indexOfScalarPos(u8, output, kstart, ']')) |kend| {
                buf.appendSlice(alloc, "  " ++ MCP_DIM ++ "(received: [") catch {};
                buf.appendSlice(alloc, output[kstart..kend]) catch {};
                buf.appendSlice(alloc, "])" ++ MCP_RESET) catch {};
            }
        }
        return;
    }

    if (eql(tool_name, "codedb_search") or eql(tool_name, "codedb_word")) {
        const q = getStr(args, "query") orelse getStr(args, "word") orelse "";
        // First line: "N results for 'q':\n" or "N hits for 'w':\n"
        const nl = std.mem.indexOfScalar(u8, output, '\n') orelse output.len;
        const sp = std.mem.indexOfScalar(u8, output[0..nl], ' ') orelse nl;
        buf.appendSlice(alloc, "  " ++ MCP_BOLD ++ "'") catch {};
        buf.appendSlice(alloc, q) catch {};
        buf.appendSlice(alloc, "'" ++ MCP_RESET ++ MCP_DASH ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, output[0..sp]) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
        buf.appendSlice(alloc, if (eql(tool_name, "codedb_search")) " results" else " hits") catch {};
        if (getBool(args, "scope")) {
            buf.appendSlice(alloc, MCP_DIM ++ "  (scoped)" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_outline")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
        // Parse meta from first line: "path (lang, N lines, N bytes)"
        if (std.mem.indexOfScalar(u8, output, '(')) |lp| {
            if (std.mem.indexOfScalarPos(u8, output, lp, ')')) |rp| {
                buf.appendSlice(alloc, MCP_DASH ++ MCP_DIM) catch {};
                buf.appendSlice(alloc, output[lp + 1 .. rp]) catch {};
                buf.appendSlice(alloc, MCP_RESET) catch {};
            }
        }
    } else if (eql(tool_name, "codedb_symbol")) {
        const sym_name = getStr(args, "name") orelse "";
        buf.appendSlice(alloc, MCP_DASH ++ MCP_MAGENTA ++ "fn " ++ MCP_RESET ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, sym_name) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_tree")) {
        var file_count: usize = 0;
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " ");
            if (t.len > 0 and !std.mem.endsWith(u8, t, "/")) file_count += 1;
        }
        var tmp: [32]u8 = undefined;
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{file_count}) catch "?") catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files") catch {};
    } else if (eql(tool_name, "codedb_read") or eql(tool_name, "codedb_deps")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
    } else if (eql(tool_name, "codedb_edit")) {
        const path = getStr(args, "path") orelse "";
        buf.appendSlice(alloc, "  ") catch {};
        mcpAppendPath(alloc, buf, path);
    } else if (eql(tool_name, "codedb_hot")) {
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, output, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " ").len > 0) count += 1;
        }
        var tmp: [32]u8 = undefined;
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{count}) catch "?") catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files") catch {};
    } else if (eql(tool_name, "codedb_status")) {
        var files_str: []const u8 = "?";
        var seq_str: []const u8 = "?";
        if (std.mem.indexOf(u8, output, "files: ")) |i| {
            const after = output[i + 7 ..];
            files_str = after[0 .. std.mem.indexOfScalar(u8, after, '\n') orelse after.len];
        }
        if (std.mem.indexOf(u8, output, "seq: ")) |i| {
            const after = output[i + 5 ..];
            seq_str = after[0 .. std.mem.indexOfScalar(u8, after, '\n') orelse after.len];
        }
        buf.appendSlice(alloc, "  " ++ MCP_CYAN ++ MCP_BOLD) catch {};
        buf.appendSlice(alloc, files_str) catch {};
        buf.appendSlice(alloc, MCP_RESET ++ " files" ++ MCP_DASH ++ MCP_DIM ++ "seq ") catch {};
        buf.appendSlice(alloc, seq_str) catch {};
        buf.appendSlice(alloc, MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_changes")) {
        if (getInt(args, "since")) |since| {
            var tmp: [32]u8 = undefined;
            buf.appendSlice(alloc, "  " ++ MCP_DIM ++ "since seq ") catch {};
            buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{since}) catch "0") catch {};
            buf.appendSlice(alloc, MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_bundle")) {
        const path = getStr(args, "path") orelse "";
        if (path.len > 0) {
            buf.appendSlice(alloc, "  ") catch {};
            mcpAppendPath(alloc, buf, path);
        }
    }
    // codedb_snapshot, codedb_status: label + timer is enough
}

pub fn mcpGenerateGuidance(
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    args: *const std.json.ObjectMap,
    output: []const u8,
    is_error: bool,
    buf: *std.ArrayList(u8),
) void {
    if (is_error) {
        if (eql(tool_name, "codedb_outline") or eql(tool_name, "codedb_read") or eql(tool_name, "codedb_deps")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: use codedb_tree to verify file paths" ++ MCP_RESET) catch {};
        } else if (eql(tool_name, "codedb_edit")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: use codedb_outline to verify structure before editing" ++ MCP_RESET) catch {};
        }
        return;
    }
    if (eql(tool_name, "codedb_tree")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline path=<file> to inspect symbols" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_outline")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_symbol name=<fn> to read a function body" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_symbol")) {
        // Bug 8: don't tell the agent to "edit this symbol" when the lookup
        // returned 0 results — there's nothing to edit. Hint at codedb_search
        // instead so they can broaden the lookup.
        if (std.mem.startsWith(u8, output, "no results for:")) {
            buf.appendSlice(alloc, MCP_DIM ++ "hint: try codedb_search query=<name> to find references — symbol not defined" ++ MCP_RESET) catch {};
        } else {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_edit to modify this symbol" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_search")) {
        const has_regex_meta = blk: {
            if (getBool(args, "regex")) break :blk false;
            const q = getStr(args, "query") orelse break :blk false;
            for (q) |c| switch (c) {
                '|', '(', ')', '[', ']', '?', '+', '*', '^', '$' => break :blk true,
                else => {},
            };
            break :blk false;
        };
        if (has_regex_meta) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "hint: query has regex metachars but regex=false; matched as literal — pass regex=true for OR/grouping" ++ MCP_RESET) catch {};
        } else if (!getBool(args, "scope")) {
            buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: add scope=true to see enclosing functions" ++ MCP_RESET) catch {};
        }
    } else if (eql(tool_name, "codedb_word")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline on a result file for full context" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_edit")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_changes to verify edits" ++ MCP_RESET) catch {};
    } else if (eql(tool_name, "codedb_hot")) {
        buf.appendSlice(alloc, MCP_DIM ++ MCP_ARROW ++ "next: codedb_outline on a hot file to see recent changes" ++ MCP_RESET) catch {};
    }
}
