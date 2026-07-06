// Tests for the indexing memory budget (#591 Task 8): a last-resort backstop
// so indexing the wrong folder (or a mono-repo) can't exhaust host memory.
//
// Picked up by the test runner via tests.zig, which re-imports this file.

const std = @import("std");
const testing = std.testing;
const cio = @import("../cio.zig");
const budget = @import("../watcher/budget.zig");
const Config = @import("../config.zig").Config;

test "config: max_index_memory_mb defaults to 6144" {
    const cfg = try Config.parse("");
    try testing.expectEqual(@as(u32, 6144), cfg.max_index_memory_mb);
}

test "config: max_index_memory_mb parses" {
    const cfg = try Config.parse("max_index_memory_mb = 2048\n");
    try testing.expectEqual(@as(u32, 2048), cfg.max_index_memory_mb);
}

test "config: max_index_memory_mb accepts 0 (unlimited)" {
    const cfg = try Config.parse("max_index_memory_mb = 0\n");
    try testing.expectEqual(@as(u32, 0), cfg.max_index_memory_mb);
}

test "config: malformed max_index_memory_mb rejected" {
    try testing.expectError(error.InvalidMaxIndexMemoryMb, Config.parse("max_index_memory_mb = lots\n"));
}

test "budget: processRssBytes reports something plausible on this platform" {
    const rss = cio.processRssBytes() orelse return error.SkipZigTest;
    // Any live zig test process is comfortably above 1MB and below 1TB.
    try testing.expect(rss > 1024 * 1024);
    try testing.expect(rss < 1024 * 1024 * 1024 * 1024);
}

test "budget: limit 0 is never over" {
    const check = budget.checkMemoryBudget(0);
    try testing.expect(!check.over);
}

test "budget: limit 1MB is over for any live process" {
    const check = budget.checkMemoryBudget(1);
    if (cio.processRssBytes() == null) return error.SkipZigTest;
    try testing.expect(check.over);
    try testing.expect(check.rss_bytes > 1024 * 1024);
}

test "budget: global limit set/get and exceeded flag" {
    budget.setLimitMb(1);
    defer budget.setLimitMb(6144);
    defer budget.clearExceeded();
    try testing.expectEqual(@as(u32, 1), budget.limitMb());
    try testing.expect(!budget.exceeded());
    // shouldStopIndexing marks the sticky exceeded flag when over.
    if (cio.processRssBytes() == null) return error.SkipZigTest;
    try testing.expect(budget.shouldStopIndexing());
    try testing.expect(budget.exceeded());
}
