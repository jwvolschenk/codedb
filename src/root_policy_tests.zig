// Tests for src/root_policy.zig.
//
// Extracted from src/root_policy.zig to keep the parser file focused on
// implementation. Tests are picked up by the test runner via
// `@import("tests.zig")` which re-imports this file.

const std = @import("std");
const testing = std.testing;
const root_policy = @import("root_policy.zig");

test "issue-80: normal paths are allowed" {
    try testing.expect(root_policy.isIndexableRoot("/Users/dev/project"));
    try testing.expect(root_policy.isIndexableRoot("/home/user/code"));
    try testing.expect(root_policy.isIndexableRoot("/home/user/code/subdir"));
}

test "issue-174: home directory itself is denied" {
    try testing.expect(!root_policy.isIndexableRoot("/root"));
    try testing.expect(!root_policy.isIndexableRoot("/home/user"));
    try testing.expect(!root_policy.isIndexableRoot("/Users/dev"));
    // But subdirectories are allowed
    try testing.expect(root_policy.isIndexableRoot("/home/user/projects"));
    try testing.expect(root_policy.isIndexableRoot("/Users/dev/code"));
    try testing.expect(root_policy.isIndexableRoot("/root/projects"));
}
test "issue-80: empty path is denied" {
    try testing.expect(!root_policy.isIndexableRoot(""));
}

test "issue-80: /tmp is denied" {
    try testing.expect(!root_policy.isIndexableRoot("/tmp"));
    try testing.expect(!root_policy.isIndexableRoot("/tmp/foo"));
}

