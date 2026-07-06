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

/// The absolute filesystem paths whose mtimes tell the watcher "HEAD may have
/// moved" — worktree/submodule-aware, unlike a naive `{root}/.git/HEAD` stat
/// (in linked worktrees and submodules `.git` is a FILE, so that stat fails
/// and branch-switch detection is silently dead).
pub const HeadWatchPaths = struct {
    head_path: []u8, //         <git-dir>/HEAD          (worktree-private)
    ref_path: ?[]u8, //         <common-dir>/<symref>   (null when detached)
    packed_refs_path: ?[]u8, // <common-dir>/packed-refs

    pub fn deinit(self: *HeadWatchPaths, alloc: std.mem.Allocator) void {
        alloc.free(self.head_path);
        if (self.ref_path) |p| alloc.free(p);
        if (self.packed_refs_path) |p| alloc.free(p);
        self.* = undefined;
    }
};

/// Pure parser (testable without git): `rev_parse_out` is the two-line output
/// of `git rev-parse --absolute-git-dir --git-common-dir`; `head_content` is
/// the HEAD file's content ("ref: refs/heads/x" or a bare SHA when detached).
/// The common dir may be printed relative (".git") — resolved against `root`.
pub fn parseHeadWatchPaths(
    rev_parse_out: []const u8,
    head_content: []const u8,
    root: []const u8,
    allocator: std.mem.Allocator,
) ?HeadWatchPaths {
    var lines = std.mem.splitScalar(u8, rev_parse_out, '\n');
    const git_dir = std.mem.trim(u8, lines.next() orelse return null, &std.ascii.whitespace);
    const common_raw = std.mem.trim(u8, lines.next() orelse return null, &std.ascii.whitespace);
    if (git_dir.len == 0 or common_raw.len == 0) return null;

    const common_dir = if (common_raw[0] == '/')
        allocator.dupe(u8, common_raw) catch return null
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, common_raw }) catch return null;
    defer allocator.free(common_dir);

    const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch return null;

    var ref_path: ?[]u8 = null;
    const trimmed_head = std.mem.trim(u8, head_content, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
        const ref = std.mem.trim(u8, trimmed_head["ref: ".len..], &std.ascii.whitespace);
        if (ref.len > 0) {
            ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ common_dir, ref }) catch {
                allocator.free(head_path);
                return null;
            };
        }
    }

    const packed_refs = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{common_dir}) catch {
        allocator.free(head_path);
        if (ref_path) |p| allocator.free(p);
        return null;
    };

    return .{ .head_path = head_path, .ref_path = ref_path, .packed_refs_path = packed_refs };
}

/// One `git rev-parse --absolute-git-dir --git-common-dir` subprocess at
/// watcher startup (and again after each branch switch, to retarget the
/// symref), then a HEAD read to find the current ref. Handles linked
/// worktrees (gitdir file), submodules, and detached HEAD (ref_path=null).
/// Returns null on any failure — callers fall back to the periodic
/// unconditional `getGitHead` compare.
pub fn resolveHeadWatchPaths(io: std.Io, root: []const u8, allocator: std.mem.Allocator) ?HeadWatchPaths {
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--absolute-git-dir", "--git-common-dir" },
        .cwd = root,
        .max_output_bytes = 8192,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    const git_dir = std.mem.trim(u8, lines.next() orelse return null, &std.ascii.whitespace);
    if (git_dir.len == 0) return null;
    const head_file = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch return null;
    defer allocator.free(head_file);
    const head_content = std.Io.Dir.cwd().readFileAlloc(io, head_file, allocator, .limited(4096)) catch return null;
    defer allocator.free(head_content);

    return parseHeadWatchPaths(result.stdout, head_content, root, allocator);
}

/// Free a path list returned by `parseStatusPorcelainZ` / `getDirtyPaths`.
pub fn freePathList(paths: [][]u8, allocator: std.mem.Allocator) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

/// Pure parser for `git status --porcelain -z` output (testable without git).
///
/// -z format: entries are NUL-terminated, paths are NEVER quoted (no C-style
/// escaping even for spaces/unicode). Each entry is `XY <path>`; rename/copy
/// entries (X or Y in {R,C}) are followed by a second NUL-terminated token
/// holding the ORIGINAL path. Both paths are returned — the old path must be
/// evicted from the index and the new one indexed.
/// Malformed entries (shorter than `XY p`) are skipped, never fatal.
pub fn parseStatusPorcelainZ(buf: []const u8, allocator: std.mem.Allocator) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, buf, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        // `XY <path>` — two status chars, one space, at least one path byte.
        if (entry.len < 4 or entry[2] != ' ') continue;
        const x = entry[0];
        const y = entry[1];
        const path = entry[3..];
        try out.append(allocator, try allocator.dupe(u8, path));
        // Rename/copy: the next token is the original path.
        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
            if (it.next()) |orig| {
                if (orig.len > 0) {
                    try out.append(allocator, try allocator.dupe(u8, orig));
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Runs `git status --porcelain -z --untracked-files=all` in `root` and
/// returns ROOT-relative paths of every modified/added/deleted/renamed/
/// untracked entry (renames contribute BOTH old and new path). Returns null
/// when git is unavailable or `root` is not a repo — callers treat that as
/// "nothing to reconcile". Free with `freePathList`.
///
/// Porcelain output is REPO-ROOT-relative, but codedb's index paths are
/// relative to `root`, which may be a subdirectory of the repo (monorepo
/// package). So: resolve the repo toplevel, rebase every path against `root`,
/// and drop paths outside `root`'s subtree — a dirty file elsewhere in the
/// monorepo is not this index's business.
pub fn getDirtyPaths(root: []const u8, allocator: std.mem.Allocator) ?[][]u8 {
    const toplevel = blk: {
        const r = cio.runCapture(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .cwd = root,
            .max_output_bytes = 4096,
        }) catch return null;
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        switch (r.term) {
            .Exited => |code| if (code != 0) return null,
            else => return null,
        }
        const trimmed = std.mem.trim(u8, r.stdout, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        break :blk allocator.dupe(u8, trimmed) catch return null;
    };
    defer allocator.free(toplevel);

    const result = cio.runCapture(.{
        .allocator = allocator,
        // `-- .` limits the pathspec to root's subtree (cheaper in monorepos);
        // output paths are still repo-root-relative, hence the rebase below.
        .argv = &.{ "git", "status", "--porcelain", "-z", "--untracked-files=all", "--", "." },
        .cwd = root,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const repo_relative = parseStatusPorcelainZ(result.stdout, allocator) catch return null;

    // Fast path: root IS the repo toplevel — repo-relative == root-relative.
    // (Realpath both sides? root is canonical already — #591 funnel — and
    // --show-toplevel returns a resolved path, so byte equality is right.)
    if (std.mem.eql(u8, toplevel, root)) return repo_relative;
    defer freePathList(repo_relative, allocator);

    // root must be toplevel/<prefix>/ — compute the prefix and rebase.
    if (!std.mem.startsWith(u8, root, toplevel) or
        root.len <= toplevel.len or root[toplevel.len] != '/') return null;
    const prefix = root[toplevel.len + 1 ..];

    var out: std.ArrayList([]u8) = .empty;
    var failed = false;
    for (repo_relative) |p| {
        if (!std.mem.startsWith(u8, p, prefix)) continue;
        if (p.len <= prefix.len + 1 or p[prefix.len] != '/') continue;
        const rebased = allocator.dupe(u8, p[prefix.len + 1 ..]) catch {
            failed = true;
            break;
        };
        out.append(allocator, rebased) catch {
            allocator.free(rebased);
            failed = true;
            break;
        };
    }
    if (failed) {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
        return null;
    };
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
