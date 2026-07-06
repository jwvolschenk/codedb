// Tests for worktree/submodule-aware branch-switch detection (#591 Task 6):
// the pure parser that turns `git rev-parse --absolute-git-dir --git-common-dir`
// output + HEAD file content into the set of absolute paths the watcher stats.
//
// Picked up by the test runner via tests.zig, which re-imports this file.

const std = @import("std");
const testing = std.testing;
const git_mod = @import("../git.zig");

test "head-watch: normal repo, symref HEAD" {
    var hw = git_mod.parseHeadWatchPaths(
        "/repo/.git\n/repo/.git\n",
        "ref: refs/heads/main\n",
        "/repo",
        testing.allocator,
    ) orelse return testing.expect(false);
    defer hw.deinit(testing.allocator);

    try testing.expectEqualStrings("/repo/.git/HEAD", hw.head_path);
    try testing.expectEqualStrings("/repo/.git/refs/heads/main", hw.ref_path.?);
    try testing.expectEqualStrings("/repo/.git/packed-refs", hw.packed_refs_path.?);
}

test "head-watch: linked worktree — HEAD private, refs in common dir" {
    var hw = git_mod.parseHeadWatchPaths(
        "/repo/.git/worktrees/wt1\n/repo/.git\n",
        "ref: refs/heads/feature\n",
        "/repo-wt1",
        testing.allocator,
    ) orelse return testing.expect(false);
    defer hw.deinit(testing.allocator);

    // HEAD is per-worktree (the file the old `.git/HEAD` stat never found,
    // because `.git` in a worktree is a FILE, not a directory).
    try testing.expectEqualStrings("/repo/.git/worktrees/wt1/HEAD", hw.head_path);
    // The branch ref lives in the SHARED common dir.
    try testing.expectEqualStrings("/repo/.git/refs/heads/feature", hw.ref_path.?);
    try testing.expectEqualStrings("/repo/.git/packed-refs", hw.packed_refs_path.?);
}

test "head-watch: detached HEAD has no ref path" {
    var hw = git_mod.parseHeadWatchPaths(
        "/repo/.git\n/repo/.git\n",
        "3f786850e387550fdab836ed7e6dc881de23001b\n",
        "/repo",
        testing.allocator,
    ) orelse return testing.expect(false);
    defer hw.deinit(testing.allocator);

    try testing.expectEqualStrings("/repo/.git/HEAD", hw.head_path);
    try testing.expect(hw.ref_path == null);
    try testing.expectEqualStrings("/repo/.git/packed-refs", hw.packed_refs_path.?);
}

test "head-watch: relative common dir is resolved against root" {
    // `git rev-parse --git-common-dir` prints a relative `.git` in a normal
    // repo when cwd is the repo root; the parser must absolutize it.
    var hw = git_mod.parseHeadWatchPaths(
        "/repo/.git\n.git\n",
        "ref: refs/heads/main\n",
        "/repo",
        testing.allocator,
    ) orelse return testing.expect(false);
    defer hw.deinit(testing.allocator);

    try testing.expectEqualStrings("/repo/.git/refs/heads/main", hw.ref_path.?);
    try testing.expectEqualStrings("/repo/.git/packed-refs", hw.packed_refs_path.?);
}

test "head-watch: malformed rev-parse output -> null" {
    try testing.expect(git_mod.parseHeadWatchPaths("only-one-line\n", "ref: refs/heads/x\n", "/r", testing.allocator) == null);
    try testing.expect(git_mod.parseHeadWatchPaths("", "", "/r", testing.allocator) == null);
}
