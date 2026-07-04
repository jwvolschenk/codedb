// Trigram index — union(enum) dispatcher over heap and mmap variants.
//
// Extracted from the former trigram.zig monolith. Delegates every operation
// to the active variant and handles promotion from mmap → mmap_overlay when
// the index needs to accept new writes.

const heap = @import("heap.zig");
const TrigramIndex = heap.TrigramIndex;
const mmap_mod = @import("mmap.zig");
const MmapTrigramIndex = mmap_mod.MmapTrigramIndex;

const std = @import("std");
const regex_query = @import("../regex_query.zig");
const RegexQuery = regex_query.RegexQuery;

pub const AnyTrigramIndex = union(enum) {
    heap: TrigramIndex,
    mmap: MmapTrigramIndex,
    mmap_overlay: MmapOverlay,

    pub const MmapOverlay = struct {
        base: MmapTrigramIndex,
        overlay: TrigramIndex,
        /// Base paths superseded by the overlay (re-indexed or removed). Keys
        /// are owned (duped on insert, freed in deinit). #593: without this,
        /// a deleted file's base trigrams still answer candidates() — ghost
        /// matches from deleted files. Phase 4 wires the 6 function arms to
        /// consult it; Phase 2's adoptTrigramBase populates it. Construction
        /// sites pass an explicit init (the field has no usable default since
        /// Zig can't bind allocator from a sibling field).
        masked: std.StringHashMap(void),
        masked_in_base: u32 = 0,

        pub fn deinit(self: *MmapOverlay) void {
            self.base.deinit();
            self.overlay.deinit();
            // Free owned mask keys.
            var it = self.masked.iterator();
            while (it.next()) |entry| self.overlay.allocator.free(entry.key_ptr.*);
            self.masked.deinit();
        }

        /// Mark a base path as superseded by the overlay. Idempotent. The map
        /// owns its keys (freed in deinit). Used by adoptTrigramBase (Phase 2)
        /// and removeFile/indexFile (Phase 4).
        pub fn mask(self: *MmapOverlay, path: []const u8) void {
            if (self.masked.contains(path)) return;
            const key = self.overlay.allocator.dupe(u8, path) catch return;
            self.masked.put(key, {}) catch {
                self.overlay.allocator.free(key);
                return;
            };
            self.masked_in_base += 1;
        }
    };

    pub fn deinit(self: *AnyTrigramIndex) void {
        switch (self.*) {
            .heap => |*h| h.deinit(),
            .mmap => |*m| m.deinit(),
            .mmap_overlay => |*mo| mo.deinit(),
        }
    }

    pub fn candidates(self: *AnyTrigramIndex, query: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        return switch (self.*) {
            .heap => |*h| h.candidates(query, allocator),
            .mmap => |*m| m.candidates(query, allocator),
            .mmap_overlay => |*mo| blk: {
                const base = mo.base.candidates(query, allocator);
                const over = mo.overlay.candidates(query, allocator);
                if (base == null and over == null) break :blk null;
                if (base == null) break :blk over;
                if (over == null) break :blk base;
                // Merge and dedup — return null on alloc failure (triggers full scan fallback)
                var merged = std.StringHashMap(void).init(allocator);
                defer merged.deinit();
                for (base.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                for (over.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                allocator.free(base.?);
                allocator.free(over.?);
                var result: std.ArrayList([]const u8) = .empty;
                result.ensureTotalCapacity(allocator, merged.count()) catch break :blk null;
                var it = merged.keyIterator();
                while (it.next()) |k| result.appendAssumeCapacity(k.*);
                break :blk result.toOwnedSlice(allocator) catch {
                    result.deinit(allocator);
                    break :blk null;
                };
            },
        };
    }

    pub fn candidatesRegex(self: *AnyTrigramIndex, query: *const RegexQuery, allocator: std.mem.Allocator) ?[]const []const u8 {
        return switch (self.*) {
            .heap => |*h| h.candidatesRegex(query, allocator),
            .mmap => |*m| m.candidatesRegex(query, allocator),
            .mmap_overlay => |*mo| blk: {
                const base = mo.base.candidatesRegex(query, allocator);
                const over = mo.overlay.candidatesRegex(query, allocator);
                if (base == null and over == null) break :blk null;
                if (base == null) break :blk over;
                if (over == null) break :blk base;
                var merged = std.StringHashMap(void).init(allocator);
                defer merged.deinit();
                for (base.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                for (over.?) |p| merged.put(p, {}) catch {
                    allocator.free(base.?);
                    allocator.free(over.?);
                    break :blk null;
                };
                allocator.free(base.?);
                allocator.free(over.?);
                var result: std.ArrayList([]const u8) = .empty;
                result.ensureTotalCapacity(allocator, merged.count()) catch break :blk null;
                var it = merged.keyIterator();
                while (it.next()) |k| result.appendAssumeCapacity(k.*);
                break :blk result.toOwnedSlice(allocator) catch {
                    result.deinit(allocator);
                    break :blk null;
                };
            },
        };
    }

    pub fn containsFile(self: *const AnyTrigramIndex, path: []const u8) bool {
        return switch (self.*) {
            .heap => |*h| h.file_trigrams.contains(path),
            .mmap => |*m| m.containsFile(path),
            .mmap_overlay => |*mo| mo.base.containsFile(path) or mo.overlay.file_trigrams.contains(path),
        };
    }

    pub fn indexFile(self: *AnyTrigramIndex, path: []const u8, content: []const u8) !void {
        switch (self.*) {
            .heap => |*h| try h.indexFile(path, content),
            .mmap => |*m| {
                // Promote to mmap_overlay: keep mmap base, add heap overlay.
                // The newly-indexed file supersedes its base entry — mask it
                // (#593) so candidates() stops returning the stale base copy.
                const alloc = m.allocator;
                const base = self.mmap;
                self.* = .{ .mmap_overlay = .{
                    .base = base,
                    .overlay = TrigramIndex.init(alloc),
                    .masked = std.StringHashMap(void).init(alloc),
                } };
                try self.mmap_overlay.overlay.indexFile(path, content);
                self.mmap_overlay.mask(path);
            },
            .mmap_overlay => |*mo| try mo.overlay.indexFile(path, content),
        }
    }

    pub fn removeFile(self: *AnyTrigramIndex, path: []const u8) void {
        switch (self.*) {
            .heap => |*h| h.removeFile(path),
            .mmap => {},
            .mmap_overlay => |*mo| mo.overlay.removeFile(path),
        }
    }

    pub fn writeToDisk(self: *AnyTrigramIndex, io: std.Io, dir_path: []const u8, git_head: ?[40]u8) !void {
        switch (self.*) {
            .heap => |*h| try h.writeToDisk(io, dir_path, git_head),
            .mmap => {},
            .mmap_overlay => {},
        }
    }

    pub fn fileCount(self: *const AnyTrigramIndex) u32 {
        return switch (self.*) {
            .heap => |*h| h.fileCount(),
            .mmap => |*m| m.fileCount(),
            .mmap_overlay => |*mo| mo.base.fileCount() + mo.overlay.fileCount(),
        };
    }

    pub fn asHeap(self: *AnyTrigramIndex) ?*TrigramIndex {
        return switch (self.*) {
            .heap => |*h| h,
            .mmap => null,
            .mmap_overlay => |*mo| &mo.overlay,
        };
    }
};
