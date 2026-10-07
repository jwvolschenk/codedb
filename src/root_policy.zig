const std = @import("std");
const cio = @import("cio.zig");

pub fn isExactOrChild(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (path[0..prefix.len], prefix) |a, b| {
        if (@import("builtin").os.tag == .windows) {
            if (@import("root_resolve.zig").foldForKey(a) != @import("root_resolve.zig").foldForKey(b)) return false;
        } else if (a != b) return false;
    }
    return path.len == prefix.len or path[prefix.len] == '/' or (@import("builtin").os.tag == .windows and path[prefix.len] == '\\');
}

pub fn isIndexableRoot(path: []const u8) bool {
    if (path.len == 0) return false;
    // Reject network/device roots and whole drives before any Git exception.
    if (path.len >= 2 and (path[0] == '/' or path[0] == '\\') and (path[1] == '/' or path[1] == '\\')) return false;
    if (path.len >= 2 and path[1] == ':') {
        if (!std.ascii.isAlphabetic(path[0]) or path.len <= 3) return false;
        if (path[2] != '/' and path[2] != '\\') return false;
        var components = std.mem.tokenizeAny(u8, path[3..], "/\\");
        const first = components.next() orelse return false;
        for ([_][]const u8{ "windows", "program files", "program files (x86)", "programdata", "$recycle.bin", "system volume information" }) |name| {
            if (std.ascii.eqlIgnoreCase(first, name)) return false;
        }
        if (std.ascii.eqlIgnoreCase(first, "users")) {
            _ = components.next() orelse return false;
            if (components.next() == null) return false;
        }
    }
    if (std.mem.eql(u8, path, "/")) return false;
    if (isExactOrChild(path, "/private/tmp")) return false;
    if (isExactOrChild(path, "/tmp")) return false;

    const system_prefixes = [_][]const u8{
        "/Applications",
        "/System",
        "/Library",
        "/usr",
        "/opt",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/dev",
        "/proc",
        "/sys",
        "/snap",
        "/nix",
        "/var",
        "/private/var",
    };
    for (system_prefixes) |pfx| {
        if (isExactOrChild(path, pfx)) return false;
    }

    // Block home directory itself (not subdirectories) — prevents 17GB RAM spike (#174)
    if (cio.getHomeDir()) |home| {
        if (home.len > 0 and std.mem.eql(u8, path, home)) return false;
    }
    // Also block common home patterns directly
    if (std.mem.eql(u8, path, "/root")) return false;
    if (std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/Users/")) {
        // /home/user or /Users/user (no deeper path component) = home dir
        const rest = if (std.mem.startsWith(u8, path, "/home/")) path[6..] else path[7..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) return false;
    }

    return true;
}

const testing = std.testing;

test "security: reject Windows system drive home and network roots" {
    for ([_][]const u8{ "C:", "C:/", "C:\\", "C:relative", "C:/Windows/System32", "c:/PROGRAM FILES/app", "C:/Users", "C:/Users/person", "//host/share/repo", "\\\\?\\C:\\repo" }) |path| {
        try testing.expect(!isIndexableRoot(path));
    }
    try testing.expect(isIndexableRoot("C:/repos/project"));
}
