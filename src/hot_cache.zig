const std = @import("std");

/// Fixed-capacity CLOCK eviction cache for file contents.
/// Keys are owned (duped on put, freed on eviction/remove/clear).
/// Values are owned (duped on put, freed on eviction/remove/clear).
/// Zero dynamic allocation past init.
pub const ContentCache = struct {
    slots: []Slot,
    capacity: u32,
    count_: u32,
    allocator: std.mem.Allocator,
    hits_: std.atomic.Value(u64),
    misses_: std.atomic.Value(u64),
    evictions_: std.atomic.Value(u64),

    // 8-way set-associative: at typical occupancy a full window (the only
    // eviction trigger) is vanishingly rare; probes stay short and contiguous.
    const PROBE_LIMIT: u32 = 8;

    pub const Slot = struct {
        key_hash: u64,
        key: []const u8,
        value: []const u8,
        ref_bit: bool,
        present: bool,
    };

    const empty_slot = Slot{
        .key_hash = 0,
        .key = &.{},
        .value = &.{},
        .ref_bit = false,
        .present = false,
    };

    pub const Stats = struct {
        hits: u64,
        misses: u64,
        evictions: u64,
        count: u32,
        capacity: u32,
    };

    /// capacity must be >= 1. Panics if the allocator cannot provide the slot array.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) ContentCache {
        const slots = allocator.alloc(Slot, capacity) catch
            std.debug.panic("ContentCache.init: OOM allocating {d} slots", .{capacity});
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .count_ = 0,
            .allocator = allocator,
            .hits_ = std.atomic.Value(u64).init(0),
            .misses_ = std.atomic.Value(u64).init(0),
            .evictions_ = std.atomic.Value(u64).init(0),
        };
    }

    /// Fallible variant for tests that use testing.allocator (which detects leaks).
    pub fn initAlloc(allocator: std.mem.Allocator, capacity: u32) !ContentCache {
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, empty_slot);
        return .{
            .slots = slots,
            .capacity = capacity,
            .count_ = 0,
            .allocator = allocator,
            .hits_ = std.atomic.Value(u64).init(0),
            .misses_ = std.atomic.Value(u64).init(0),
            .evictions_ = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
            }
        }
        self.allocator.free(self.slots);
    }

    pub fn get(self: *ContentCache, key: []const u8) ?[]const u8 {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                slot.ref_bit = true;
                _ = self.hits_.fetchAdd(1, .monotonic);
                return slot.value;
            }
        }
        _ = self.misses_.fetchAdd(1, .monotonic);
        return null;
    }

    /// Insert key/value. Dups both into the cache allocator.
    /// On a full probe window, evicts a cold IN-WINDOW slot (second chance)
    /// so the new entry stays reachable by get(). A global CLOCK sweep would
    /// strand the entry outside its own probe window (#584).
    pub fn put(self: *ContentCache, key: []const u8, value: []const u8) !void {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;

        // Scan the whole window: update an existing entry in place (a hole must
        // not shadow it into a duplicate), otherwise remember the first empty slot.
        var empty_idx: ?u32 = null;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present) {
                if (slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                    // Compute the new value first so a failed dupe leaves the slot intact.
                    const new_value = try self.allocator.dupe(u8, value);
                    self.allocator.free(slot.value);
                    slot.value = new_value;
                    slot.ref_bit = true;
                    return;
                }
            } else if (empty_idx == null) {
                empty_idx = slot_idx;
            }
        }

        // Window full of other keys — evict in-window (second chance over the
        // probe slots) so the new entry stays reachable by get(). A victim from
        // a global sweep would strand the entry outside its own window.
        const target_idx = empty_idx orelse blk: {
            var victim: ?u32 = null;
            i = 0;
            while (i < PROBE_LIMIT) : (i += 1) {
                const slot_idx = (base +% i) % self.capacity;
                if (!self.slots[slot_idx].ref_bit) {
                    victim = slot_idx;
                    break;
                }
            }
            if (victim == null) {
                i = 0;
                while (i < PROBE_LIMIT) : (i += 1) {
                    self.slots[(base +% i) % self.capacity].ref_bit = false;
                }
                victim = base;
            }
            const slot = &self.slots[victim.?];
            self.allocator.free(slot.key);
            self.allocator.free(slot.value);
            slot.* = empty_slot;
            self.count_ -= 1;
            _ = self.evictions_.fetchAdd(1, .monotonic);
            break :blk victim.?;
        };

        const slot = &self.slots[target_idx];
        const duped_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(duped_key);
        const duped_val = try self.allocator.dupe(u8, value);
        slot.key_hash = h;
        slot.key = duped_key;
        slot.value = duped_val;
        slot.ref_bit = true;
        slot.present = true;
        self.count_ += 1;
    }

    pub fn remove(self: *ContentCache, key: []const u8) void {
        const h = hashKey(key);
        const base = @as(u32, @truncate(h)) % self.capacity;
        var i: u32 = 0;
        while (i < PROBE_LIMIT) : (i += 1) {
            const slot_idx = (base +% i) % self.capacity;
            const slot = &self.slots[slot_idx];
            if (slot.present and slot.key_hash == h and std.mem.eql(u8, slot.key, key)) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
                slot.* = empty_slot;
                self.count_ -= 1;
                return;
            }
        }
    }

    pub fn clear(self: *ContentCache) void {
        for (self.slots) |*slot| {
            if (slot.present) {
                self.allocator.free(slot.key);
                self.allocator.free(slot.value);
                slot.* = empty_slot;
            }
        }
        self.count_ = 0;
    }

    pub fn len(self: *const ContentCache) u32 {
        return self.count_;
    }

    pub fn count(self: *const ContentCache) u32 {
        return self.count_;
    }

    pub fn contains(self: *ContentCache, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn stats(self: *const ContentCache) Stats {
        return .{
            .hits = self.hits_.load(.monotonic),
            .misses = self.misses_.load(.monotonic),
            .evictions = self.evictions_.load(.monotonic),
            .count = self.count_,
            .capacity = self.capacity,
        };
    }

    pub const Iterator = struct {
        cache: *const ContentCache,
        index: u32,

        pub const Entry = struct {
            key_ptr: *const []const u8,
            value_ptr: *const []const u8,
        };

        pub fn next(self: *Iterator) ?Entry {
            while (self.index < self.cache.capacity) {
                const slot = &self.cache.slots[self.index];
                self.index += 1;
                if (slot.present) {
                    return .{
                        .key_ptr = &slot.key,
                        .value_ptr = &slot.value,
                    };
                }
            }
            return null;
        }
    };

    pub fn iterator(self: *const ContentCache) Iterator {
        return .{ .cache = self, .index = 0 };
    }

    fn hashKey(key: []const u8) u64 {
        var h: u64 = 14695981039346656037;
        for (key) |b| {
            h ^= b;
            h *%= 1099511628211;
        }
        if (h == 0) h = 1;
        return h;
    }
};
