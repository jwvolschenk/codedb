const std = @import("std");
const cio = @import("cio.zig");

/// Returns true if `root` is inside a git work tree. Unlike `getGitHead`,
/// this also returns true for a fresh repo with no commits yet — it only
/// checks work-tree-ness, not commit history. Returns false if `root` is
/// not a git repo, git is unavailable, or `git rev-parse` fails.
pub fn isInGitWorkTree(root: []const u8, allocator: std.mem.Allocator) bool {
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
        .cwd = root,
        .max_output_bytes = 256,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    return std.mem.eql(u8, trimmed, "true");
}

/// Run `git rev-parse HEAD` in `root` and return the 40-char hex SHA.
/// Returns null if `root` is not a git repo, git is unavailable, or HEAD
/// has no commit yet (fresh repo).
pub fn getGitHead(root: []const u8, allocator: std.mem.Allocator) !?[40]u8 {
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = root,
        .max_output_bytes = 256,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len != 40) return null;
    for (trimmed) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    var out: [40]u8 = undefined;
    @memcpy(&out, trimmed[0..40]);
    return out;
}
