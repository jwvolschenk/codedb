const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const is_windows = platform.is_windows;
const posix = platform.posix;

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
                    while (j < arg.len and arg[j] == '\\') {
                        j += 1;
                        nbs += 1;
                    }
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
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .dwFlags = win_spawn_impl.STARTF_USESTDHANDLES,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
            .hStdInput = win_spawn_impl.INVALID_HANDLE_VALUE,
            .hStdOutput = stdout_w,
            .hStdError = stderr_w,
        };
        var pi: win_spawn_impl.PROCESS_INFORMATION = undefined;
        const cwd_ptr: ?[*:0]const u16 = if (opts.cwd != null)
            @as([*:0]const u16, @ptrCast(cwd_u16.items.ptr))
        else
            null;
        if (win_spawn_impl.CreateProcessW(null, @as([*:0]u16, @ptrCast(cmdline_u16.items.ptr)), null, null, .TRUE, win_spawn_impl.CREATE_NO_WINDOW, null, cwd_ptr, &si, &pi) == .FALSE) {
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
                    ctx.out.appendSlice(ctx.alloc, chunk[0..nread]) catch |e| {
                        ctx.err = e;
                        return;
                    };
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
                stdout_out.appendSlice(alloc, chunk[0..nread]) catch |e| {
                    stdout_drain_err = e;
                    break;
                };
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
        if (stdout_drain_err) |e| {
            stdout_out.deinit(alloc);
            err_ctx.out.deinit(alloc);
            return e;
        }
        if (err_ctx.err) |e| {
            stdout_out.deinit(alloc);
            err_ctx.out.deinit(alloc);
            return e;
        }
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
