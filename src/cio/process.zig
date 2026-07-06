const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const is_windows = platform.is_windows;
const posix = platform.posix;
const win = platform.win;
const NsGetArgv = platform.NsGetArgv;

pub const PipeError = error{PipeFailed};
pub fn makePipe() PipeError![2]c_int {
    if (is_windows) {
        // Windows: use MSVC CRT _pipe. 64 = O_BINARY | O_NOINHERIT.
        const fds = std.c._pipe(null, 65536, 6);
        if (fds.err != 0) return error.PipeFailed;
        return .{ fds.ret[0], fds.ret[1] };
    }
    var fds: [2]c_int = .{ -1, -1 };
    if (posix.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

pub fn closeFd(fd: c_int) void {
    if (is_windows) {
        _ = std.c._close(fd);
    } else {
        _ = posix.close(fd);
    }
}

pub fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    if (is_windows) {
        var wbuf: [512]u8 = undefined;
        const n = win.GetEnvironmentVariableA(@ptrCast(&buf), &wbuf, wbuf.len);
        if (n == 0 or n >= wbuf.len) return null;
        // Return a static copy (environment values live for process lifetime)
        const result = std.heap.c_allocator.alloc(u8, n) catch return null;
        @memcpy(result, wbuf[0..n]);
        return result;
    }
    const ptr = posix.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

/// Cross-platform home directory resolution.
/// Tries HOME first (Linux/macOS/Git Bash), then USERPROFILE (Windows native),
/// then HOMEDRIVE+HOMEPATH (older Windows).
pub fn getHomeDir() ?[]const u8 {
    if (posixGetenv("HOME")) |h| {
        if (h.len > 0) return h;
    }
    if (is_windows) {
        if (posixGetenv("USERPROFILE")) |up| {
            if (up.len > 0) return up;
        }
        if (posixGetenv("HOMEDRIVE")) |drive| {
            if (posixGetenv("HOMEPATH")) |path| {
                // Combine into a static buffer: drive + path
                var buf: [512]u8 = undefined;
                if (drive.len + path.len < buf.len) {
                    @memcpy(buf[0..drive.len], drive);
                    @memcpy(buf[drive.len .. drive.len + path.len], path);
                    const combined = buf[0 .. drive.len + path.len];
                    const result = std.heap.c_allocator.alloc(u8, combined.len) catch return null;
                    @memcpy(result, combined);
                    return result;
                }
            }
        }
    }
    return null;
}

/// Cross-platform temp directory resolution. Windows: %TEMP% then %TMP%;
/// POSIX: $TMPDIR (macOS sets a per-user one) with a /tmp fallback. Returned
/// slice has no trailing separator. Never null — the fallback is constant.
pub fn tempDir() []const u8 {
    if (is_windows) {
        if (posixGetenv("TEMP")) |t| {
            if (t.len > 0) return stripTrailingSep(t);
        }
        if (posixGetenv("TMP")) |t| {
            if (t.len > 0) return stripTrailingSep(t);
        }
        return "C:/Windows/Temp";
    }
    if (posixGetenv("TMPDIR")) |t| {
        if (t.len > 0) return stripTrailingSep(t);
    }
    return "/tmp";
}

fn stripTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and (p[end - 1] == '/' or p[end - 1] == '\\')) end -= 1;
    return p[0..end];
}

// Linux/other POSIX: 0.16 doesn't expose argv globally — main() must call
// `setProcessArgs(argv_slice)` once at startup to populate `process_args`.
// Windows: args arrive as WTF-16 (`[]const u16`), stored separately and
// converted to UTF-8 in argsAlloc via std.process.Args.Iterator.
var process_args: ?[]const [*:0]const u8 = null;
var process_args_w: ?[]const u16 = null;

/// Called once by `pub fn main` to register the argv slice on non-Darwin
/// platforms. No-op on macOS (it reads from `_NSGetArgv` directly).
pub fn setProcessArgs(args: []const [*:0]const u8) void {
    if (is_windows) return; // use setProcessArgsWindows instead
    process_args = args;
}

/// Called once by `pub fn main` on Windows to register the raw WTF-16
/// command line. Converted to UTF-8 in argsAlloc.
pub fn setProcessArgsWindows(args: []const u16) void {
    process_args_w = args;
}

/// Shim for cio.argsAlloc (removed in 0.16). Returns a duplicated
/// slice of argv strings owned by the allocator; free with argsFree.
pub fn argsAlloc(alloc: std.mem.Allocator) ![][:0]u8 {
    // Windows: args arrive as WTF-16, convert via std.process.Args.Iterator
    if (is_windows) {
        const raw = process_args_w orelse return error.ProcessArgsNotSet;
        const args_struct: std.process.Args = .{ .vector = raw };
        var iter = try std.process.Args.Iterator.initAllocator(args_struct, alloc);
        defer iter.deinit();

        var list = std.ArrayList([:0]u8).empty;
        defer {
            for (list.items) |a| alloc.free(a);
            list.deinit(alloc);
        }
        while (iter.next()) |arg| {
            const dup = try alloc.allocSentinel(u8, arg.len, 0);
            @memcpy(dup[0..arg.len], arg);
            try list.append(alloc, dup);
        }
        return try list.toOwnedSlice(alloc);
    }

    // macOS: argv lives in _NSGetArgv()
    const argc: usize = if (builtin.os.tag == .macos)
        @intCast(NsGetArgv._NSGetArgc().*)
    else
        (process_args orelse return error.ProcessArgsNotSet).len;
    const out = try alloc.alloc([:0]u8, argc);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(out[i]);
    }
    while (filled < argc) : (filled += 1) {
        const cstr: [*:0]const u8 = if (builtin.os.tag == .macos)
            NsGetArgv._NSGetArgv().*[filled]
        else
            process_args.?[filled];
        const s = std.mem.span(cstr);
        const dup = try alloc.allocSentinel(u8, s.len, 0);
        @memcpy(dup[0..s.len], s);
        out[filled] = dup;
    }
    return out;
}

pub fn argsFree(alloc: std.mem.Allocator, args: [][:0]u8) void {
    for (args) |a| alloc.free(a);
    alloc.free(args);
}
