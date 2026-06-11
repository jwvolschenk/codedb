//! cio.zig — 0.16 stdlib compatibility shim.
//!
//! 0.16 removed std.fs.File.{stdout,stderr,stdin}, cio.Mutex/RwLock,
//! std.time.Timer, std.time.nanoTimestamp, std.process.Child.run, and
//! cio.posixGetenv. This shim wraps libc/pthread primitives so existing
//! call sites continue to work with minimal import-line changes.
//!
//! Windows: uses MSVC CRT (_write, _read, etc.), kernel32 (time, env, sleep),
//! and std.atomic.Mutex (spinlock) since pthreads are not available.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// ── POSIX externs (only declared on non-Windows) ────────────────────────
const posix = if (!is_windows) struct {
    extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
    extern "c" fn read(fd: c_int, ptr: [*]u8, len: usize) isize;
    extern "c" fn isatty(fd: c_int) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn clock_gettime(id: c_int, ts: *std.c.timespec) c_int;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn flock(fd: c_int, operation: c_int) c_int;

    const CLOCK_REALTIME: c_int = 0;
    const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;
} else struct {};

// ── Windows externs (only declared on Windows) ──────────────────────────
const win = if (is_windows) struct {
    extern "kernel32" fn WriteFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: std.os.windows.DWORD, lpNumberOfBytesWritten: *std.os.windows.DWORD, lpOverlapped: ?*anyopaque) std.os.windows.BOOL;
    extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) std.os.windows.HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) std.os.windows.BOOL;
    extern "kernel32" fn GetEnvironmentVariableA(lpName: [*:0]const u8, lpBuffer: [*]u8, nSize: std.os.windows.DWORD) std.os.windows.DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: std.os.windows.DWORD) void;
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) void;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) std.os.windows.BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) std.os.windows.BOOL;
    extern "kernel32" fn GetCurrentProcessId() std.os.windows.DWORD;
    extern "kernel32" fn LockFileEx(hFile: std.os.windows.HANDLE, dwFlags: std.os.windows.DWORD, dwReserved: std.os.windows.DWORD, nNumberOfBytesToLockLow: std.os.windows.DWORD, nNumberOfBytesToLockHigh: std.os.windows.DWORD, lpOverlapped: *std.os.windows.OVERLAPPED) std.os.windows.BOOL;
    extern "kernel32" fn UnlockFileEx(hFile: std.os.windows.HANDLE, dwReserved: std.os.windows.DWORD, nNumberOfBytesToUnlockLow: std.os.windows.DWORD, nNumberOfBytesToUnlockHigh: std.os.windows.DWORD, lpOverlapped: *std.os.windows.OVERLAPPED) std.os.windows.BOOL;

    const STD_OUTPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -12));
    const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
    const FILETIME_EPOCH_DIFF: i128 = 116444736000000000; // 100ns intervals between 1601 and 1970
} else struct {};

// ── Stdio ────────────────────────────────────────────────────────────────

pub const File = struct {
    handle: c_int,

    pub fn stdout() File {
        return .{ .handle = 1 };
    }
    pub fn stderr() File {
        return .{ .handle = 2 };
    }
    pub fn stdin() File {
        return .{ .handle = 0 };
    }

    pub fn isTty(self: File) bool {
        if (is_windows) {
            const h = win.GetStdHandle(
                switch (self.handle) {
                    0 => win.STD_INPUT_HANDLE,
                    1 => win.STD_OUTPUT_HANDLE,
                    2 => win.STD_ERROR_HANDLE,
                    else => return false,
                },
            );
            var mode: std.os.windows.DWORD = 0;
            return win.GetConsoleMode(h, &mode) != .FALSE;
        }
        return posix.isatty(self.handle) != 0;
    }

    pub fn writeAll(self: File, data: []const u8) !void {
        var rem = data;
        while (rem.len > 0) {
            if (is_windows) {
                const h = win.GetStdHandle(
                    switch (self.handle) {
                        0 => win.STD_INPUT_HANDLE,
                        1 => win.STD_OUTPUT_HANDLE,
                        2 => win.STD_ERROR_HANDLE,
                        else => return error.WriteFailed,
                    },
                );
                var written: std.os.windows.DWORD = 0;
                if (win.WriteFile(h, rem.ptr, @intCast(rem.len), &written, null) == .FALSE)
                    return error.WriteFailed;
                if (written == 0) return error.WriteFailed;
                rem = rem[@intCast(written)..];
            } else {
                const n = posix.write(self.handle, rem.ptr, rem.len);
                if (n <= 0) return error.WriteFailed;
                rem = rem[@intCast(n)..];
            }
        }
    }

    pub fn print(self: File, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(std.heap.c_allocator, fmt, args);
            defer std.heap.c_allocator.free(big);
            return self.writeAll(big);
        };
        try self.writeAll(s);
    }
};

// ── Threads / Sync ───────────────────────────────────────────────────────

pub const Mutex = struct {
    inner: if (is_windows) std.atomic.Mutex else std.c.pthread_mutex_t = if (is_windows) .unlocked else .{},

    pub fn lock(self: *Mutex) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
    }
    pub fn unlock(self: *Mutex) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *Mutex) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
        }
    }
};

pub const RwLock = struct {
    inner: if (is_windows) std.atomic.Mutex else std.c.pthread_rwlock_t = if (is_windows) .unlocked else .{},

    // Windows: uses atomic spinlock (Mutex) for both exclusive and shared.
    // This is acceptable for codedb's short critical sections.
    pub fn lock(self: *RwLock) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_rwlock_wrlock(&self.inner);
        }
    }
    pub fn unlock(self: *RwLock) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn lockShared(self: *RwLock) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_rwlock_rdlock(&self.inner);
        }
    }
    pub fn unlockShared(self: *RwLock) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *RwLock) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_rwlock_trywrlock(&self.inner) == .SUCCESS;
        }
    }
    pub fn tryLockShared(self: *RwLock) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_rwlock_tryrdlock(&self.inner) == .SUCCESS;
        }
    }
};

// ── Advisory file locking (cross-process) ─────────────────────────────────
pub const LOCK_EX: c_int = 2;
pub const LOCK_UN: c_int = 8;

/// Best-effort advisory lock on an open file descriptor. Non-fatal on error.
pub fn flockFd(fd: c_int, operation: c_int) void {
    if (!is_windows) {
        _ = posix.flock(fd, operation);
    }
    // Windows: advisory flock not implemented (not used in Windows builds yet).
    // TODO: Use LockFileEx/UnlockFileEx on Windows HANDLE if needed.
}

// ── Time ─────────────────────────────────────────────────────────────────

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
    // Convert to nanoseconds
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

// ── Environment ──────────────────────────────────────────────────────────

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

// ── Arguments ────────────────────────────────────────────────────────────

// Darwin: argv lives in __NSGetArgv() (libc, from <crt_externs.h>).
// Linux/other POSIX: 0.16 doesn't expose argv globally — main() must call
// `setProcessArgs(argv_slice)` once at startup to populate `process_args`.
// Windows: args arrive as WTF-16 (`[]const u16`), stored separately and
// converted to UTF-8 in argsAlloc via std.process.Args.Iterator.
const NsGetArgv = if (!is_windows and builtin.os.tag == .macos) struct {
    extern "c" fn _NSGetArgc() *c_int;
    extern "c" fn _NSGetArgv() *[*][*:0]u8;
} else struct {};

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

// ── ArrayList writer helper (replaces 0.15's ArrayList(u8).writer(alloc)) ────

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    pub fn writeByteNTimes(self: ListWriter, b: u8, n: usize) !void {
        try self.list.appendNTimes(self.alloc, b, n);
    }
    pub fn writeBytesNTimes(self: ListWriter, bytes: []const u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&stack_buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(self.alloc, fmt, args);
            defer self.alloc.free(big);
            try self.list.appendSlice(self.alloc, big);
            return;
        };
        try self.list.appendSlice(self.alloc, s);
    }
};

pub fn listWriter(list: *std.ArrayList(u8), alloc: std.mem.Allocator) ListWriter {
    return .{ .list = list, .alloc = alloc };
}

// ── Subprocess ───────────────────────────────────────────────────────────

pub const CaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: Term,

    pub const Term = union(enum) {
        Exited: u8,
        Signal: u32,
        Stopped: u32,
        Unknown: u32,
    };
};

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 50 * 1024 * 1024,
};

// ── POSIX subprocess (non-Windows) ───────────────────────────────────────

const posix_spawn_impl = if (!is_windows) struct {
    extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

    const PosixSpawnFileActions = opaque {};
    const PosixSpawnAttr = opaque {};
    const pid_t = c_int;

    extern "c" fn posix_spawnp(
        pid: *pid_t,
        path: [*:0]const u8,
        file_actions: ?*const PosixSpawnFileActions,
        attrp: ?*const PosixSpawnAttr,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) c_int;
    extern "c" fn posix_spawn_file_actions_init(fa: *PosixSpawnFileActions) c_int;
    extern "c" fn posix_spawn_file_actions_destroy(fa: *PosixSpawnFileActions) c_int;
    extern "c" fn posix_spawn_file_actions_adddup2(fa: *PosixSpawnFileActions, fd: c_int, newfd: c_int) c_int;
    extern "c" fn posix_spawn_file_actions_addclose(fa: *PosixSpawnFileActions, fd: c_int) c_int;
    extern "c" fn posix_spawn_file_actions_addchdir_np(fa: *PosixSpawnFileActions, path: [*:0]const u8) c_int;
    extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;

    const PosixSpawnFAStorage = [256]u8;
} else struct {};

// ── Windows subprocess (CreateProcess) ──────────────────────────────────

const win_spawn_impl = if (is_windows) struct {
    pub const SECURITY_ATTRIBUTES = extern struct {
        nLength: std.os.windows.DWORD,
        lpSecurityDescriptor: ?*anyopaque,
        bInheritHandle: std.os.windows.BOOL,
    };
    pub const STARTUPINFOW = extern struct {
        cb: std.os.windows.DWORD,
        lpReserved: ?[*:0]u16,
        lpDesktop: ?[*:0]u16,
        lpTitle: ?[*:0]u16,
        dwX: std.os.windows.DWORD,
        dwY: std.os.windows.DWORD,
        dwXSize: std.os.windows.DWORD,
        dwYSize: std.os.windows.DWORD,
        dwXCountChars: std.os.windows.DWORD,
        dwYCountChars: std.os.windows.DWORD,
        dwFillAttribute: std.os.windows.DWORD,
        dwFlags: std.os.windows.DWORD,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?[*]u8,
        hStdInput: std.os.windows.HANDLE,
        hStdOutput: std.os.windows.HANDLE,
        hStdError: std.os.windows.HANDLE,
    };
    pub const PROCESS_INFORMATION = extern struct {
        hProcess: std.os.windows.HANDLE,
        hThread: std.os.windows.HANDLE,
        dwProcessId: std.os.windows.DWORD,
        dwThreadId: std.os.windows.DWORD,
    };
    pub extern "kernel32" fn CreatePipe(hReadPipe: *std.os.windows.HANDLE, hWritePipe: *std.os.windows.HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: std.os.windows.DWORD) std.os.windows.BOOL;
    pub extern "kernel32" fn SetHandleInformation(hObject: std.os.windows.HANDLE, dwMask: std.os.windows.DWORD, dwFlags: std.os.windows.DWORD) std.os.windows.BOOL;
    pub extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*const SECURITY_ATTRIBUTES, lpThreadAttributes: ?*const SECURITY_ATTRIBUTES, bInheritHandles: std.os.windows.BOOL, dwCreationFlags: std.os.windows.DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) std.os.windows.BOOL;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: std.os.windows.HANDLE, dwMilliseconds: std.os.windows.DWORD) std.os.windows.DWORD;
    pub extern "kernel32" fn GetExitCodeProcess(hProcess: std.os.windows.HANDLE, lpExitCode: *std.os.windows.DWORD) std.os.windows.BOOL;
    pub extern "kernel32" fn ReadFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: std.os.windows.DWORD, lpNumberOfBytesRead: *std.os.windows.DWORD, lpOverlapped: ?*anyopaque) std.os.windows.BOOL;
    pub extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) std.os.windows.BOOL;
    pub const HANDLE_FLAG_INHERIT: std.os.windows.DWORD = 0x00000001;
    pub const STARTF_USESTDHANDLES: std.os.windows.DWORD = 0x00000100;
    pub const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;
    pub const CREATE_NO_WINDOW: std.os.windows.DWORD = 0x08000000;
    pub const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
} else struct {};

fn winAppendUtf16(out: *std.ArrayList(u16), alloc: std.mem.Allocator, utf8: []const u8) !void {
    var i: usize = 0;
    while (i < utf8.len) {
        const b = utf8[i];
        if (b < 0x80) {
            try out.append(alloc, @intCast(b));
            i += 1;
        } else if (b & 0xE0 == 0xC0 and i + 1 < utf8.len) {
            const cp: u21 = (@as(u21, b & 0x1F) << 6) | (utf8[i + 1] & 0x3F);
            try out.append(alloc, @intCast(cp));
            i += 2;
        } else if (b & 0xF0 == 0xE0 and i + 2 < utf8.len) {
            const cp: u21 = (@as(u21, b & 0x0F) << 12) | (@as(u21, utf8[i + 1] & 0x3F) << 6) | (utf8[i + 2] & 0x3F);
            try out.append(alloc, @intCast(cp));
            i += 3;
        } else if (b & 0xF8 == 0xF0 and i + 3 < utf8.len) {
            const cp: u21 = (@as(u21, b & 0x07) << 18) | (@as(u21, utf8[i + 1] & 0x3F) << 12) | (@as(u21, utf8[i + 2] & 0x3F) << 6) | (utf8[i + 3] & 0x3F);
            const sub = cp - 0x10000;
            const high: u16 = @intCast(0xD800 + (sub >> 10));
            const low: u16 = @intCast(0xDC00 + (sub & 0x3FF));
            try out.append(alloc, high);
            try out.append(alloc, low);
            i += 4;
        } else {
            i += 1;
        }
    }
}

pub fn runCapture(opts: RunOptions) !CaptureResult {
    if (is_windows) {
        const alloc = opts.allocator;
        if (opts.argv.len == 0) return error.EmptyArgv;

        // Build UTF-8 command line with Windows arg quoting
        var cmdline_u8: std.ArrayList(u8) = .empty;
        defer cmdline_u8.deinit(alloc);
        for (opts.argv, 0..) |arg, i| {
            if (i > 0) try cmdline_u8.append(alloc, ' ');
            const needs_quote = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
            if (!needs_quote) {
                try cmdline_u8.appendSlice(alloc, arg);
            } else {
                try cmdline_u8.append(alloc, '"');
                var j: usize = 0;
                while (j < arg.len) {
                    var nbs: usize = 0;
                    while (j < arg.len and arg[j] == '\\') { j += 1; nbs += 1; }
                    if (j == arg.len) {
                        var k: usize = 0;
                        while (k < nbs * 2) : (k += 1) try cmdline_u8.append(alloc, '\\');
                        break;
                    } else if (arg[j] == '"') {
                        var k: usize = 0;
                        while (k < nbs * 2 + 1) : (k += 1) try cmdline_u8.append(alloc, '\\');
                        try cmdline_u8.append(alloc, '"');
                        j += 1;
                    } else {
                        var k: usize = 0;
                        while (k < nbs) : (k += 1) try cmdline_u8.append(alloc, '\\');
                        try cmdline_u8.append(alloc, arg[j]);
                        j += 1;
                    }
                }
                try cmdline_u8.append(alloc, '"');
            }
        }
        var cmdline_u16: std.ArrayList(u16) = .empty;
        defer cmdline_u16.deinit(alloc);
        try winAppendUtf16(&cmdline_u16, alloc, cmdline_u8.items);
        try cmdline_u16.append(alloc, 0);

        var cwd_u16: std.ArrayList(u16) = .empty;
        defer cwd_u16.deinit(alloc);
        if (opts.cwd) |cwd| {
            try winAppendUtf16(&cwd_u16, alloc, cwd);
            try cwd_u16.append(alloc, 0);
        }

        var sa = win_spawn_impl.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(win_spawn_impl.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = .TRUE,
        };
        var stdout_r: std.os.windows.HANDLE = undefined;
        var stdout_w: std.os.windows.HANDLE = undefined;
        if (win_spawn_impl.CreatePipe(&stdout_r, &stdout_w, &sa, 0) == .FALSE) return error.PipeFailed;
        var stderr_r: std.os.windows.HANDLE = undefined;
        var stderr_w: std.os.windows.HANDLE = undefined;
        if (win_spawn_impl.CreatePipe(&stderr_r, &stderr_w, &sa, 0) == .FALSE) {
            _ = win_spawn_impl.CloseHandle(stdout_r);
            _ = win_spawn_impl.CloseHandle(stdout_w);
            return error.PipeFailed;
        }
        _ = win_spawn_impl.SetHandleInformation(stdout_r, win_spawn_impl.HANDLE_FLAG_INHERIT, 0);
        _ = win_spawn_impl.SetHandleInformation(stderr_r, win_spawn_impl.HANDLE_FLAG_INHERIT, 0);

        var si = win_spawn_impl.STARTUPINFOW{
            .cb = @sizeOf(win_spawn_impl.STARTUPINFOW),
            .lpReserved = null, .lpDesktop = null, .lpTitle = null,
            .dwX = 0, .dwY = 0, .dwXSize = 0, .dwYSize = 0,
            .dwXCountChars = 0, .dwYCountChars = 0, .dwFillAttribute = 0,
            .dwFlags = win_spawn_impl.STARTF_USESTDHANDLES,
            .wShowWindow = 0, .cbReserved2 = 0, .lpReserved2 = null,
            .hStdInput = win_spawn_impl.INVALID_HANDLE_VALUE,
            .hStdOutput = stdout_w,
            .hStdError = stderr_w,
        };
        var pi: win_spawn_impl.PROCESS_INFORMATION = undefined;
        const cwd_ptr: ?[*:0]const u16 = if (opts.cwd != null)
            @as([*:0]const u16, @ptrCast(cwd_u16.items.ptr))
        else
            null;
        if (win_spawn_impl.CreateProcessW(null, @as([*:0]u16, @ptrCast(cmdline_u16.items.ptr)),
            null, null, .TRUE, win_spawn_impl.CREATE_NO_WINDOW, null, cwd_ptr, &si, &pi) == .FALSE)
        {
            _ = win_spawn_impl.CloseHandle(stdout_r);
            _ = win_spawn_impl.CloseHandle(stdout_w);
            _ = win_spawn_impl.CloseHandle(stderr_r);
            _ = win_spawn_impl.CloseHandle(stderr_w);
            return error.SpawnFailed;
        }
        _ = win_spawn_impl.CloseHandle(stdout_w);
        _ = win_spawn_impl.CloseHandle(stderr_w);

        const WinDrainCtx = struct {
            handle: std.os.windows.HANDLE,
            cap: usize,
            alloc: std.mem.Allocator,
            out: std.ArrayList(u8) = .empty,
            err: ?anyerror = null,

            fn run(ctx: *@This()) void {
                var chunk: [64 * 1024]u8 = undefined;
                while (ctx.out.items.len < ctx.cap) {
                    const want: std.os.windows.DWORD = @intCast(@min(chunk.len, ctx.cap - ctx.out.items.len));
                    var nread: std.os.windows.DWORD = 0;
                    if (win_spawn_impl.ReadFile(ctx.handle, &chunk, want, &nread, null) == .FALSE or nread == 0) break;
                    ctx.out.appendSlice(ctx.alloc, chunk[0..nread]) catch |e| { ctx.err = e; return; };
                }
            }
        };
        var err_ctx: WinDrainCtx = .{ .handle = stderr_r, .cap = opts.max_output_bytes, .alloc = alloc };
        const err_thread = std.Thread.spawn(.{}, WinDrainCtx.run, .{&err_ctx}) catch {
            _ = win_spawn_impl.CloseHandle(stdout_r);
            _ = win_spawn_impl.CloseHandle(stderr_r);
            _ = win_spawn_impl.CloseHandle(pi.hProcess);
            _ = win_spawn_impl.CloseHandle(pi.hThread);
            return error.ThreadSpawnFailed;
        };
        var stdout_out: std.ArrayList(u8) = .empty;
        var stdout_drain_err: ?anyerror = null;
        {
            var chunk: [64 * 1024]u8 = undefined;
            while (stdout_out.items.len < opts.max_output_bytes) {
                const want: std.os.windows.DWORD = @intCast(@min(chunk.len, opts.max_output_bytes - stdout_out.items.len));
                var nread: std.os.windows.DWORD = 0;
                if (win_spawn_impl.ReadFile(stdout_r, &chunk, want, &nread, null) == .FALSE or nread == 0) break;
                stdout_out.appendSlice(alloc, chunk[0..nread]) catch |e| { stdout_drain_err = e; break; };
            }
        }
        _ = win_spawn_impl.CloseHandle(stdout_r);
        err_thread.join();
        _ = win_spawn_impl.CloseHandle(stderr_r);
        _ = win_spawn_impl.WaitForSingleObject(pi.hProcess, win_spawn_impl.INFINITE);
        var exit_code: std.os.windows.DWORD = 1;
        _ = win_spawn_impl.GetExitCodeProcess(pi.hProcess, &exit_code);
        _ = win_spawn_impl.CloseHandle(pi.hProcess);
        _ = win_spawn_impl.CloseHandle(pi.hThread);
        if (stdout_drain_err) |e| { stdout_out.deinit(alloc); err_ctx.out.deinit(alloc); return e; }
        if (err_ctx.err) |e| { stdout_out.deinit(alloc); err_ctx.out.deinit(alloc); return e; }
        return .{
            .stdout = try stdout_out.toOwnedSlice(alloc),
            .stderr = try err_ctx.out.toOwnedSlice(alloc),
            .term = .{ .Exited = @truncate(exit_code) },
        };
    }

    if (opts.argv.len == 0) return error.EmptyArgv;
    const alloc = opts.allocator;

    const c_argv = try alloc.alloc(?[*:0]const u8, opts.argv.len + 1);
    defer alloc.free(c_argv);
    const arg_bufs = try alloc.alloc([]u8, opts.argv.len);
    defer {
        for (arg_bufs) |b| alloc.free(b);
        alloc.free(arg_bufs);
    }
    for (opts.argv, 0..) |a, i| {
        const buf = try alloc.alloc(u8, a.len + 1);
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0;
        arg_bufs[i] = buf;
        c_argv[i] = @ptrCast(buf.ptr);
    }
    c_argv[opts.argv.len] = null;
    const c_argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(c_argv.ptr);

    var out_pipe: [2]c_int = .{ -1, -1 };
    var err_pipe: [2]c_int = .{ -1, -1 };
    if (posix.pipe(&out_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (out_pipe[0] >= 0) _ = posix.close(out_pipe[0]);
        if (out_pipe[1] >= 0) _ = posix.close(out_pipe[1]);
    }
    if (posix.pipe(&err_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (err_pipe[0] >= 0) _ = posix.close(err_pipe[0]);
        if (err_pipe[1] >= 0) _ = posix.close(err_pipe[1]);
    }

    var fa_storage: posix_spawn_impl.PosixSpawnFAStorage = undefined;
    const fa: *posix_spawn_impl.PosixSpawnFileActions = @ptrCast(&fa_storage);
    if (posix_spawn_impl.posix_spawn_file_actions_init(fa) != 0) return error.SpawnInitFailed;
    defer _ = posix_spawn_impl.posix_spawn_file_actions_destroy(fa);

    if (opts.cwd) |cwd| {
        var cwd_buf: [4096]u8 = undefined;
        if (cwd.len >= cwd_buf.len) return error.PathTooLong;
        @memcpy(cwd_buf[0..cwd.len], cwd);
        cwd_buf[cwd.len] = 0;
        if (posix_spawn_impl.posix_spawn_file_actions_addchdir_np(fa, @ptrCast(&cwd_buf)) != 0) {
            return error.CwdNotSupported;
        }
    }

    _ = posix_spawn_impl.posix_spawn_file_actions_adddup2(fa, out_pipe[1], 1);
    _ = posix_spawn_impl.posix_spawn_file_actions_adddup2(fa, err_pipe[1], 2);
    _ = posix_spawn_impl.posix_spawn_file_actions_addclose(fa, out_pipe[0]);
    _ = posix_spawn_impl.posix_spawn_file_actions_addclose(fa, out_pipe[1]);
    _ = posix_spawn_impl.posix_spawn_file_actions_addclose(fa, err_pipe[0]);
    _ = posix_spawn_impl.posix_spawn_file_actions_addclose(fa, err_pipe[1]);

    const envp: [*:null]const ?[*:0]const u8 = if (builtin.os.tag == .macos)
        @ptrCast(posix_spawn_impl._NSGetEnviron().*)
    else
        @ptrCast(std.c.environ);

    var pid: posix_spawn_impl.pid_t = 0;
    if (posix_spawn_impl.posix_spawnp(&pid, c_argv[0].?, fa, null, c_argv_z, envp) != 0)
        return error.SpawnFailed;

    _ = posix.close(out_pipe[1]);
    out_pipe[1] = -1;
    _ = posix.close(err_pipe[1]);
    err_pipe[1] = -1;

    // Drain stderr on a background thread so neither pipe can fill up and
    // deadlock the child. Main thread drains stdout.
    const DrainCtx = struct {
        fd: c_int,
        cap: usize,
        alloc: std.mem.Allocator,
        out: std.ArrayList(u8) = .empty,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var chunk: [64 * 1024]u8 = undefined;
            while (self.out.items.len < self.cap) {
                const want = @min(chunk.len, self.cap - self.out.items.len);
                const n = posix.read(self.fd, &chunk, want);
                if (n <= 0) break;
                self.out.appendSlice(self.alloc, chunk[0..@intCast(n)]) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };
    var err_ctx: DrainCtx = .{ .fd = err_pipe[0], .cap = opts.max_output_bytes, .alloc = alloc };
    errdefer err_ctx.out.deinit(alloc);
    const err_thread = try std.Thread.spawn(.{}, DrainCtx.run, .{&err_ctx});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (out.items.len < opts.max_output_bytes) {
        const want = @min(chunk.len, opts.max_output_bytes - out.items.len);
        const n = posix.read(out_pipe[0], &chunk, want);
        if (n <= 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    _ = posix.close(out_pipe[0]);
    out_pipe[0] = -1;

    err_thread.join();
    _ = posix.close(err_pipe[0]);
    err_pipe[0] = -1;
    if (err_ctx.err) |e| {
        err_ctx.out.deinit(alloc);
        return e;
    }

    var status: c_int = 0;
    _ = posix_spawn_impl.waitpid(pid, &status, 0);

    const term: CaptureResult.Term = if ((status & 0x7f) == 0)
        .{ .Exited = @intCast((status >> 8) & 0xff) }
    else if ((status & 0x7f) != 0x7f)
        .{ .Signal = @intCast(status & 0x7f) }
    else
        .{ .Stopped = @intCast((status >> 8) & 0xff) };

    return .{
        .stdout = try out.toOwnedSlice(alloc),
        .stderr = try err_ctx.out.toOwnedSlice(alloc),
        .term = term,
    };
}
