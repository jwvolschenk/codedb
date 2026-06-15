// Tests for src/hot_cache.zig.
//
// Extracted from src/hot_cache.zig to keep the parser file focused on
// implementation. Tests are picked up by the test runner via
// `@import("tests.zig")` which re-imports this file.

const std = @import("std");
const testing = std.testing;
const hot_cache = @import("hot_cache.zig");
const ContentCache = hot_cache.ContentCache;

test "ContentCache: basic get/put/remove" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("foo", "bar");
    try std.testing.expectEqualStrings("bar", cache.get("foo").?);
    try std.testing.expect(cache.get("missing") == null);

    cache.remove("foo");
    try std.testing.expect(cache.get("foo") == null);
    try std.testing.expectEqual(@as(u32, 0), cache.len());
}

test "ContentCache: put updates existing key in place" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("key", "v1");
    try cache.put("key", "v2");
    try std.testing.expectEqualStrings("v2", cache.get("key").?);
    try std.testing.expectEqual(@as(u32, 1), cache.len());
}

test "ContentCache: clear drops all entries" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("a", "1");
    try cache.put("b", "2");
    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.len());
    try std.testing.expect(cache.get("a") == null);
}

test "ContentCache: iterator visits all present entries" {
    var cache = try ContentCache.initAlloc(std.testing.allocator, 64);
    defer cache.deinit();

    try cache.put("x", "1");
    try cache.put("y", "2");
    try cache.put("z", "3");

    var count: usize = 0;
    var iter = cache.iterator();
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "ContentCache: eviction fires under capacity pressure" {
    const cap = 50;
    var cache = try ContentCache.initAlloc(std.testing.allocator, cap);
    defer cache.deinit();

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const k = std.fmt.bufPrint(&key_buf, "file_{d}.zig", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&val_buf, "content_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }
    try std.testing.expect(cache.len() <= cap);
    const s = cache.stats();
    try std.testing.expect(s.evictions > 0);
}
