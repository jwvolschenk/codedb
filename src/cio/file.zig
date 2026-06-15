const std = @import("std");
const platform = @import("platform.zig");

const is_windows = platform.is_windows;
const posix = platform.posix;
const win = platform.win;

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
