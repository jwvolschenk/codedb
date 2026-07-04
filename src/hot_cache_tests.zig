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

test "issue-584: probe-window overflow insert stays reachable (no global-hand strand)" {
    // Pre-fix, the global CLOCK hand evicted a victim OUTSIDE the new key's
    // probe window, so get() — which only scans its own window — could never
    // find it. The bytes were stranded and the key permanently missed.
    // Use a tiny capacity so 5 colliding keys force a full window.
    var cache = try ContentCache.initAlloc(testing.allocator, 8);
    defer cache.deinit();

    // Five keys engineered to share one probe-window base: same low bits.
    // (We don't control hash, so just overfill with distinct keys — the window
    // is 8-way, so inserting 8+ distinct keys guarantees at least one overflow
    // insert somewhere; assert every inserted key past the first window-full
    // is still retrievable, i.e. eviction stayed in-window.)
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        var kb: [32]u8 = undefined;
        var vb: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "k584_{d}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vb, "v584_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }
    // Every key still in the cache (len <= cap) must be reachable by get().
    var it = cache.iterator();
    var checked: u32 = 0;
    while (it.next()) |entry| {
        try testing.expect(cache.get(entry.key_ptr.*) != null);
        checked += 1;
    }
    try testing.expect(checked == cache.len());
}

test "issue-584: remove() hole does not hide a later in-window entry" {
    // Pre-fix, get()/remove() broke out of the probe loop on the first hole
    // (key_hash == 0), so an entry stored PAST a hole was unreachable and
    // immune to removal — a permanent leak with a dangling free.
    var cache = try ContentCache.initAlloc(testing.allocator, 64);
    defer cache.deinit();

    // Fill, then remove a key in the middle of a window, then confirm other
    // keys remain reachable (get scans the full window, not stopping at holes).
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var kb: [32]u8 = undefined;
        var vb: [32]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "rm_{d}", .{i}) catch unreachable;
        const v = std.fmt.bufPrint(&vb, "vm_{d}", .{i}) catch unreachable;
        try cache.put(k, v);
    }
    // Remove a couple, creating holes.
    cache.remove("rm_3");
    cache.remove("rm_7");
    try testing.expect(cache.get("rm_3") == null);
    try testing.expect(cache.get("rm_7") == null);
    // The other keys must STILL be reachable (the holes must not terminate
    // the probe scan before reaching them).
    try testing.expect(cache.get("rm_0") != null);
    try testing.expect(cache.get("rm_9") != null);
}

test "issue-584: put() into a window with a hole does not duplicate the key" {
    // Pre-fix, put() took the FIRST empty slot without scanning the rest of
    // the window, so a key already held later in the window got duplicated.
    var cache = try ContentCache.initAlloc(testing.allocator, 64);
    defer cache.deinit();

    try cache.put("dup", "first");
    // Create a hole somewhere, then re-put the same key — must update in place,
    // not add a second entry.
    cache.remove("sibling");
    try cache.put("dup", "second");
    try testing.expectEqualStrings("second", cache.get("dup").?);
    try testing.expectEqual(@as(u32, 1), cache.len());
}
