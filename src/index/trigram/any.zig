// Trigram index — union(enum) dispatcher over heap and mmap variants.
//
// Extracted from the former trigram.zig monolith. Delegates every operation
// to the active variant and handles promotion from mmap → mmap_overlay when
// the index needs to accept new writes.

const heap = @import("heap.zig");
const TrigramIndex = heap.TrigramIndex;
const mmap_mod = @import("mmap.zig");
const MmapTrigramIndex = mmap_mod.MmapTrigramIndex;
const tg_posting = @import("../trigram_posting.zig");
const Trigram = tg_posting.Trigram;

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
        /// and removeFile/indexFile (Phase 4). masked_in_base only counts
        /// paths the base actually answers for, so fileCount() stays correct.
        pub fn mask(self: *MmapOverlay, path: []const u8) void {
            if (self.masked.contains(path)) return;
            const key = self.overlay.allocator.dupe(u8, path) catch return;
            self.masked.put(key, {}) catch {
                self.overlay.allocator.free(key);
                return;
            };
            if (self.base.containsFile(path)) self.masked_in_base += 1;
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
                break :blk mergeOverlayCandidates(mo, base, over, allocator);
            },
        };
    }

    /// Merge base + overlay candidate lists, dropping base hits for masked
    /// (superseded or removed) paths. Returns null on alloc failure so callers
    /// fall back to the full scan. (#593)
    fn mergeOverlayCandidates(
        mo: *const MmapOverlay,
        base: ?[]const []const u8,
        over: ?[]const []const u8,
        allocator: std.mem.Allocator,
    ) ?[]const []const u8 {
        if (base == null and over == null) return null;
        if (base == null) return over;
        // No overlay hits and nothing masked — base already is the answer;
        // skip rehashing every base candidate.
        if (over == null and mo.masked.count() == 0) return base;
        var merged = std.StringHashMap(void).init(allocator);
        defer merged.deinit();
        var failed = false;
        for (base.?) |p| {
            if (mo.masked.contains(p)) continue;
            merged.put(p, {}) catch {
                failed = true;
                break;
            };
        }
        if (!failed) if (over) |ov| {
            for (ov) |p| {
                merged.put(p, {}) catch {
                    failed = true;
                    break;
                };
            }
        };
        allocator.free(base.?);
        if (over) |ov| allocator.free(ov);
        if (failed) return null;
        var result: std.ArrayList([]const u8) = .empty;
        result.ensureTotalCapacity(allocator, merged.count()) catch return null;
        var it = merged.keyIterator();
        while (it.next()) |k| result.appendAssumeCapacity(k.*);
        return result.toOwnedSlice(allocator) catch {
            result.deinit(allocator);
            return null;
        };
    }

    pub fn candidatesRegex(self: *AnyTrigramIndex, query: *const RegexQuery, allocator: std.mem.Allocator) ?[]const []const u8 {
        return switch (self.*) {
            .heap => |*h| h.candidatesRegex(query, allocator),
            .mmap => |*m| m.candidatesRegex(query, allocator),
            .mmap_overlay => |*mo| blk: {
                const base = mo.base.candidatesRegex(query, allocator);
                const over = mo.overlay.candidatesRegex(query, allocator);
                break :blk mergeOverlayCandidates(mo, base, over, allocator);
            },
        };
    }

    pub fn containsFile(self: *const AnyTrigramIndex, path: []const u8) bool {
        return switch (self.*) {
            .heap => |*h| h.file_trigrams.contains(path),
            .mmap => |*m| m.containsFile(path),
            // #593: a masked base path is superseded — answer from the overlay only.
            .mmap_overlay => |*mo| (mo.base.containsFile(path) and !mo.masked.contains(path)) or
                mo.overlay.file_trigrams.contains(path),
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
            // #593: a re-index of an overlay file masks its base entry so the
            // stale base trigrams no longer leak into candidates().
            .mmap_overlay => |*mo| {
                try mo.overlay.indexFile(path, content);
                mo.mask(path);
            },
        }
    }

    pub fn removeFile(self: *AnyTrigramIndex, path: []const u8) void {
        switch (self.*) {
            .heap => |*h| h.removeFile(path),
            .mmap => |*m| {
                // #593: a remove is a write — promote so the base entry can be
                // masked. Without this, a deleted file's base trigrams keep
                // answering candidates() (ghost matches from deleted files).
                if (!m.containsFile(path)) return;
                const alloc = m.allocator;
                const base = self.mmap;
                self.* = .{ .mmap_overlay = .{
                    .base = base,
                    .overlay = TrigramIndex.init(alloc),
                    .masked = std.StringHashMap(void).init(alloc),
                } };
                self.mmap_overlay.mask(path);
            },
            .mmap_overlay => |*mo| {
                mo.overlay.removeFile(path);
                mo.mask(path);
            },
        }
    }

    pub fn writeToDisk(self: *AnyTrigramIndex, io: std.Io, dir_path: []const u8, git_head: ?[40]u8) !void {
        switch (self.*) {
            .heap => |*h| try h.writeToDisk(io, dir_path, git_head),
            // A pure mmap view holds no in-memory changes — the disk files
            // already are the index.
            .mmap => {},
            // #600: materialize the merged logical state (base minus masked
            // paths, plus overlay) as a heap TrigramIndex and persist that.
            // Pre-fix this was a no-op, so overlay edits never reached disk
            // and vanished on restart.
            .mmap_overlay => |*mo| {
                var merged = try materializeOverlay(mo);
                defer merged.deinit();
                try merged.writeToDisk(io, dir_path, git_head);
            },
        }
    }

    /// Rebuild the merged logical state (base minus masked paths, plus
    /// overlay) as a heap TrigramIndex so the heap serializer can persist it.
    /// That serializer is tmp+rename atomic, so writing over the very directory
    /// the live base is mmapped from is safe — the mapping keeps the old inode
    /// alive. (#600)
    fn materializeOverlay(mo: *const MmapOverlay) !TrigramIndex {
        const alloc = mo.overlay.allocator;
        var merged = TrigramIndex.init(alloc);
        merged.owns_paths = true;
        errdefer merged.deinit();

        for (mo.base.file_table) |path| {
            if (mo.masked.contains(path)) continue;
            try mergedAddFile(&merged, path);
        }
        var overlay_files = mo.overlay.file_trigrams.keyIterator();
        while (overlay_files.next()) |path_ptr| {
            try mergedAddFile(&merged, path_ptr.*);
        }

        for (0..mo.base.lookup_entries) |e| {
            const entry = mo.base.lookupEntryAt(e);
            const tri: Trigram = @intCast(entry.trigram);
            for (0..entry.count) |pi| {
                const p = mo.base.readPosting(entry.offset + pi) orelse continue;
                if (p.file_id >= mo.base.file_table.len) continue;
                const path = mo.base.file_table[p.file_id];
                if (mo.masked.contains(path)) continue;
                try mergedInsert(&merged, tri, path, p.next_mask, p.loc_mask);
            }
        }

        var overlay_tris = mo.overlay.index.iterator();
        while (overlay_tris.next()) |te| {
            for (te.value_ptr.items.items) |p| {
                if (p.doc_id >= mo.overlay.id_to_path.items.len) continue;
                const path = mo.overlay.id_to_path.items[p.doc_id];
                if (path.len == 0) continue;
                try mergedInsert(&merged, te.key_ptr.*, path, p.next_mask, p.loc_mask);
            }
        }
        return merged;
    }

    fn mergedAddFile(merged: *TrigramIndex, path: []const u8) !void {
        const doc_id = try merged.getOrCreateDocId(path);
        const stable = merged.id_to_path.items[doc_id];
        if (!merged.file_trigrams.contains(stable)) {
            try merged.file_trigrams.put(stable, .empty);
        }
    }

    fn mergedInsert(merged: *TrigramIndex, tri: Trigram, path: []const u8, next_mask: u8, loc_mask: u8) !void {
        const doc_id = merged.path_to_id.get(path) orelse return;
        const gop = try merged.index.getOrPut(tri);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .path_to_id = &merged.path_to_id };
        }
        const posting = try gop.value_ptr.getOrAddPosting(merged.allocator, doc_id);
        posting.next_mask |= next_mask;
        posting.loc_mask |= loc_mask;
        const stable = merged.id_to_path.items[doc_id];
        const tri_list = merged.file_trigrams.getPtr(stable) orelse return;
        if (tri_list.items.len == 0 or tri_list.items[tri_list.items.len - 1] != tri) {
            try tri_list.append(merged.allocator, tri);
        }
    }

    pub fn fileCount(self: *const AnyTrigramIndex) u32 {
        return switch (self.*) {
            .heap => |*h| h.fileCount(),
            .mmap => |*m| m.fileCount(),
            // #593: masked base paths are superseded by the overlay (or removed),
            // so don't double-count them.
            .mmap_overlay => |*mo| mo.base.fileCount() + mo.overlay.fileCount() - mo.masked_in_base,
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
