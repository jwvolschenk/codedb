//! Root-confined source I/O. Adapted from upstream 36e35bf (4031c74,
//! 845ea53, 2b204c7), retaining Zig 0.16 and the fork's edit support.
//! Resolve each directory using a handle and reject links/reparse points.
//! Validate the opened object before reading it; a pre-open realpath is not
//! a security boundary. File arguments are normalized relative index keys.
const std = @import("std");
const safety = @import("path_safety.zig");

pub fn isAllowedPath(path: []const u8) bool {
    return safety.isPathSafe(path) and !safety.isSensitivePath(path);
}

pub const Parent = struct {
    dir: std.Io.Dir,
    owned: bool,
    basename: []const u8,
    pub fn close(self: Parent, io: std.Io) void {
        if (self.owned) self.dir.close(io);
    }
};

/// Open parents one component at a time. Holding the parent handle also
/// confines edit creation/rename when a path component is replaced.
pub fn openParent(io: std.Io, root: std.Io.Dir, path: []const u8) !Parent {
    if (!isAllowedPath(path)) return error.AccessDenied;
    var parent = Parent{ .dir = root, .owned = false, .basename = path };
    errdefer parent.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var component = parts.next() orelse return error.AccessDenied;
    while (parts.next()) |next| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) return error.AccessDenied;
        const child = try parent.dir.openDir(io, component, .{ .follow_symlinks = false });
        errdefer child.close(io);
        // Windows may return a handle to the reparse point itself.
        try validateObject(io, root, .{ .handle = child.handle, .flags = .{ .nonblocking = false } }, true);
        parent.close(io);
        parent.dir = child;
        parent.owned = true;
        component = next;
    }
    if (component.len == 0 or std.mem.eql(u8, component, ".")) return error.AccessDenied;
    parent.basename = component;
    return parent;
}

fn validateObject(io: std.Io, root: std.Io.Dir, file: std.Io.File, directory: bool) !void {
    const info = try file.stat(io);
    if (directory) {
        if (info.kind != .directory) return error.AccessDenied;
    } else if (info.kind != .file) return error.AccessDenied;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);
    const target_len = try file.realPath(io, &target_buf);
    if (target_len <= root_len) return error.AccessDenied;
    for (root_buf[0..root_len], target_buf[0..root_len]) |a, b| {
        if (fold(a) != fold(b)) return error.AccessDenied;
    }
    if (target_buf[root_len] != '/' and target_buf[root_len] != '\\') return error.AccessDenied;
    const rel = target_buf[root_len + 1 .. target_len];
    for (rel) |*ch| if (ch.* == '\\') { ch.* = '/'; };
    if (!isAllowedPath(rel)) return error.AccessDenied;
}

fn fold(ch: u8) u8 {
    return if (@import("builtin").os.tag == .windows)
        (if (ch == '\\') '/' else std.ascii.toLower(ch))
    else ch;
}

pub fn open(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.File {
    const parent = try openParent(io, root, path);
    defer parent.close(io);
    var file = try parent.dir.openFile(io, parent.basename, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    errdefer file.close(io);
    // Zig 0.16 opens no-follow Windows handles asynchronously.
    if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
    try validateObject(io, root, file, false);
    return file;
}

pub fn readAlloc(io: std.Io, root: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    const file = try open(io, root, path);
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, limit);
}

pub fn stat(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.File.Stat {
    const file = try open(io, root, path);
    defer file.close(io);
    return file.stat(io);
}
