const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

// POSIX externs (only declared on non-Windows).
pub const posix = if (!is_windows) struct {
    pub extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
    pub extern "c" fn read(fd: c_int, ptr: [*]u8, len: usize) isize;
    pub extern "c" fn isatty(fd: c_int) c_int;
    pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    pub extern "c" fn clock_gettime(id: c_int, ts: *std.c.timespec) c_int;
    pub extern "c" fn pipe(fds: *[2]c_int) c_int;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn flock(fd: c_int, operation: c_int) c_int;

    pub const CLOCK_REALTIME: c_int = 0;
    pub const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;
} else struct {};

// Windows externs (only declared on Windows).
pub const win = if (is_windows) struct {
    pub extern "kernel32" fn WriteFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: std.os.windows.DWORD, lpNumberOfBytesWritten: *std.os.windows.DWORD, lpOverlapped: ?*anyopaque) std.os.windows.BOOL;
    pub extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) std.os.windows.HANDLE;
    pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) std.os.windows.BOOL;
    pub extern "kernel32" fn GetEnvironmentVariableA(lpName: [*:0]const u8, lpBuffer: [*]u8, nSize: std.os.windows.DWORD) std.os.windows.DWORD;
    pub extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) void;
    pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) void;
    pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) std.os.windows.BOOL;
    pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) std.os.windows.BOOL;
    pub extern "kernel32" fn GetCurrentProcessId() std.os.windows.DWORD;
    pub extern "kernel32" fn LockFileEx(hFile: std.os.windows.HANDLE, dwFlags: std.os.windows.DWORD, dwReserved: std.os.windows.DWORD, nNumberOfBytesToLockLow: std.os.windows.DWORD, nNumberOfBytesToLockHigh: std.os.windows.DWORD, lpOverlapped: *std.os.windows.OVERLAPPED) std.os.windows.BOOL;
    pub extern "kernel32" fn UnlockFileEx(hFile: std.os.windows.HANDLE, dwReserved: std.os.windows.DWORD, nNumberOfBytesToUnlockLow: std.os.windows.DWORD, nNumberOfBytesToUnlockHigh: std.os.windows.DWORD, lpOverlapped: *std.os.windows.OVERLAPPED) std.os.windows.BOOL;

    pub const STD_OUTPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -11));
    pub const STD_ERROR_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -12));
    pub const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
    pub const FILETIME_EPOCH_DIFF: i128 = 116444736000000000; // 100ns intervals between 1601 and 1970
} else struct {};

// Darwin: argv lives in __NSGetArgv() (libc, from <crt_externs.h>).
pub const NsGetArgv = if (!is_windows and builtin.os.tag == .macos) struct {
    pub extern "c" fn _NSGetArgc() *c_int;
    pub extern "c" fn _NSGetArgv() *[*][*:0]u8;
} else struct {};
