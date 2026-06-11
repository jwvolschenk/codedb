// Trigram packing + posting-list data structures.
const std = @import("std");

pub const Trigram = u24;

pub fn packTrigram(a: u8, b: u8, c: u8) Trigram {
    return @as(Trigram, a) << 16 | @as(Trigram, b) << 8 | @as(Trigram, c);
}

pub const PostingMask = struct {
    next_mask: u8 = 0, // bloom filter of chars following this trigram
    loc_mask: u8 = 0, // bit mask of (position % 8) where trigram appears
};

pub const DocPosting = struct {
    doc_id: u32,
    next_mask: u8 = 0,
    loc_mask: u8 = 0,
};

pub const PostingList = struct {
    items: std.ArrayList(DocPosting) = .empty,
    path_to_id: ?*const std.StringHashMap(u32) = null,

    pub fn deinit(self: *PostingList, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn count(self: *const PostingList) usize {
        return self.items.items.len;
    }

    pub fn get(self: *const PostingList, path: []const u8) ?PostingMask {
        const p2id = self.path_to_id orelse return null;
        const doc_id = p2id.get(path) orelse return null;
        return self.getByDocId(doc_id);
    }

    pub fn contains(self: *const PostingList, path: []const u8) bool {
        return self.get(path) != null;
    }

    pub fn getByDocId(self: *const PostingList, doc_id: u32) ?PostingMask {
        // Binary search on sorted doc_id array
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].doc_id == doc_id) return PostingMask{ .next_mask = items[mid].next_mask, .loc_mask = items[mid].loc_mask };
            if (items[mid].doc_id < doc_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    pub fn containsDocId(self: *const PostingList, doc_id: u32) bool {
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].doc_id == doc_id) return true;
            if (items[mid].doc_id < doc_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return false;
    }
    pub fn getOrAddPosting(self: *PostingList, allocator: std.mem.Allocator, doc_id: u32) !*DocPosting {
        // Binary search for existing
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].doc_id == doc_id) return &self.items.items[mid];
            if (items[mid].doc_id < doc_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Insert at sorted position
        try self.items.insert(allocator, lo, .{ .doc_id = doc_id });
        return &self.items.items[lo];
    }

    pub fn removeDocId(self: *PostingList, doc_id: u32) void {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.items.items[mid].doc_id < doc_id) {
                lo = mid + 1;
            } else if (self.items.items[mid].doc_id > doc_id) {
                hi = mid;
            } else {
                _ = self.items.orderedRemove(mid);
                return;
            }
        }
    }
};
