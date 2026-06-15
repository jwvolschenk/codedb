const std = @import("std");
const platform = @import("platform.zig");

const is_windows = platform.is_windows;
const posix = platform.posix;
const win = platform.win;

fn winNanoTimestamp() i128 {
    var ft: std.os.windows.FILETIME = undefined;
    win.GetSystemTimeAsFileTime(&ft);
    const raw: u64 = (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    return @as(i128, @intCast(raw)) * 100 - win.FILETIME_EPOCH_DIFF * 100;
}

fn winQueryPerfCounter() i128 {
    var counter: i64 = 0;
    _ = win.QueryPerformanceCounter(&counter);
    var freq: i64 = 0;
    _ = win.QueryPerformanceFrequency(&freq);
    if (freq == 0) return 0;
    // Convert to nanoseconds.
    return @divTrunc(@as(i128, counter) * 1_000_000_000, @as(i128, freq));
}

pub fn nanoTimestamp() i128 {
    if (is_windows) return winNanoTimestamp();
    var ts: std.c.timespec = undefined;
    _ = posix.clock_gettime(posix.CLOCK_REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn milliTimestamp() i64 {
    if (is_windows) return @intCast(@divTrunc(winNanoTimestamp(), 1_000_000));
    var ts: std.c.timespec = undefined;
    _ = posix.clock_gettime(posix.CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub const Timer = struct {
    start_ns: i128,

    pub fn start() !Timer {
        if (is_windows) return .{ .start_ns = winQueryPerfCounter() };
        var ts: std.c.timespec = undefined;
        _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
        return .{ .start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec };
    }

    pub fn read(self: *Timer) u64 {
        const now: i128 = if (is_windows) winQueryPerfCounter() else blk: {
            var ts: std.c.timespec = undefined;
            _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
            break :blk @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        };
        return @intCast(now - self.start_ns);
    }

    pub fn lap(self: *Timer) u64 {
        const now: i128 = if (is_windows) winQueryPerfCounter() else blk: {
            var ts: std.c.timespec = undefined;
            _ = posix.clock_gettime(posix.CLOCK_MONOTONIC, &ts);
            break :blk @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        };
        const delta: u64 = @intCast(now - self.start_ns);
        self.start_ns = now;
        return delta;
    }
};

/// Non-cryptographic random u64 mixing nanotime, PID, and thread ID.
pub fn randU64() u64 {
    const ts_ns: u64 = if (is_windows) blk: {
        var ft: std.os.windows.FILETIME = undefined;
        win.GetSystemTimeAsFileTime(&ft);
        break :blk (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
    } else blk: {
        var ts: std.c.timespec = undefined;
        _ = posix.clock_gettime(posix.CLOCK_REALTIME, &ts);
        break :blk @as(u64, @intCast(ts.nsec));
    };
    const tid = std.Thread.getCurrentId();
    const pid: u64 = if (is_windows)
        @intCast(win.GetCurrentProcessId())
    else
        @intCast(std.c.getpid());
    // splitmix64-style final mixing to avoid close-timestamp collisions
    var x = ts_ns ^ (tid *% (1 << 17)) ^ (pid *% (1 << 23));
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

pub fn sleepMs(ms: u64) void {
    if (is_windows) {
        win.Sleep(@intCast(ms));
    } else {
        var ts: std.c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}
