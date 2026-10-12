// codedb — Type index for return_type and param_type lookups.
//
// Inverted index: type string → list of hits.
// Populated during file indexing from Symbol.return_type and Symbol.param_types.
// Enables O(1) lookup for "find all functions returning X" and
// "find all functions accepting X".

const std = @import("std");

pub const TypeHit = struct {
    path: []const u8,
    symbol_name: []const u8,
    line_start: u32,
};

pub const TypeIndex = struct {
    /// return_type → hits (e.g. "Task<IViewComponentResult>" → [...])
    return_type_map: std.StringHashMap(std.ArrayList(TypeHit)),
    /// param_type → hits (e.g. "ILogger" → [...])
    param_type_map: std.StringHashMap(std.ArrayList(TypeHit)),
    /// path → set of return_types contributed (for efficient re-index cleanup)
    file_return_types: std.StringHashMap([]const []const u8),
    /// path → set of param_types contributed (for efficient re-index cleanup)
    file_param_types: std.StringHashMap([]const []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeIndex {
        return .{
            .return_type_map = std.StringHashMap(std.ArrayList(TypeHit)).init(allocator),
            .param_type_map = std.StringHashMap(std.ArrayList(TypeHit)).init(allocator),
            .file_return_types = std.StringHashMap([]const []const u8).init(allocator),
            .file_param_types = std.StringHashMap([]const []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeIndex) void {
        // Free per-file type sets first (values are slices of keys from the main maps,
        // but we DON'T free the type strings here — the main maps own them)
        var frt_iter = self.file_return_types.iterator();
        while (frt_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*); // free the slice, not the strings
        }
        self.file_return_types.deinit();

        var fpt_iter = self.file_param_types.iterator();
        while (fpt_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.file_param_types.deinit();

        // Free hit lists and duped keys in return_type_map
        var rt_iter = self.return_type_map.iterator();
        while (rt_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.return_type_map.deinit();

        // Free hit lists and duped keys in param_type_map
        var pt_iter = self.param_type_map.iterator();
        while (pt_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.param_type_map.deinit();
    }

    /// Index a file's symbols. Generic over the symbol type — expects fields:
    ///   name: []const u8, line_start: u32, return_type: ?[]const u8,
    ///   param_types: []const []const u8
    pub fn indexFileSymbols(self: *TypeIndex, path: []const u8, symbols: anytype) !void {
        self.removeFile(path);

        // The per-file lists hold the map's own (canonical) key slices, so a type
        // the file shares with other files is still recorded and its hits are
        // removed again on re-index/removeFile. Recording only the types this
        // file happened to create left stale hits behind, pointing at outline
        // strings that were freed when the file was re-indexed.
        // Reserve everything the commit step needs BEFORE adding any hits, so
        // the final bookkeeping cannot fail and strand hits we cannot clean up.
        try self.file_return_types.ensureUnusedCapacity(1);
        try self.file_param_types.ensureUnusedCapacity(1);
        const rt_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(rt_key);
        const pt_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(pt_key);

        var rt_types: std.ArrayList([]const u8) = .empty;
        defer rt_types.deinit(self.allocator);
        var pt_types: std.ArrayList([]const u8) = .empty;
        defer pt_types.deinit(self.allocator);
        var rt_seen = std.StringHashMap(void).init(self.allocator);
        defer rt_seen.deinit();
        var pt_seen = std.StringHashMap(void).init(self.allocator);
        defer pt_seen.deinit();
        var committed = false;
        defer if (!committed) {
            // Failed part-way: drop whatever hits this file already added.
            self.dropFileHits(&self.return_type_map, rt_types.items, path);
            self.dropFileHits(&self.param_type_map, pt_types.items, path);
        };

        for (symbols) |sym| {
            if (sym.return_type) |rt| {
                const list = try self.trackedHitList(&self.return_type_map, &rt_types, &rt_seen, rt);
                try list.append(self.allocator, .{
                    .path = path,
                    .symbol_name = sym.name,
                    .line_start = sym.line_start,
                });
            }

            for (sym.param_types) |pt| {
                const list = try self.trackedHitList(&self.param_type_map, &pt_types, &pt_seen, pt);
                try list.append(self.allocator, .{
                    .path = path,
                    .symbol_name = sym.name,
                    .line_start = sym.line_start,
                });
            }
        }

        // Copy (not move) the lists so a failure here still leaves rt_types and
        // pt_types intact for the cleanup above.
        const rt_owned = try self.allocator.dupe([]const u8, rt_types.items);
        errdefer self.allocator.free(rt_owned);
        const pt_owned = try self.allocator.dupe([]const u8, pt_types.items);
        errdefer self.allocator.free(pt_owned);
        self.file_return_types.putAssumeCapacity(rt_key, rt_owned);
        self.file_param_types.putAssumeCapacity(pt_key, pt_owned);
        committed = true;
    }

    /// Hit list for `type_name`, creating the entry on first use, and note the
    /// map's canonical key in `file_types` once per file.
    fn trackedHitList(
        self: *TypeIndex,
        map: *std.StringHashMap(std.ArrayList(TypeHit)),
        file_types: *std.ArrayList([]const u8),
        seen: *std.StringHashMap(void),
        type_name: []const u8,
    ) !*std.ArrayList(TypeHit) {
        if (map.getEntry(type_name) == null) {
            const key = try self.allocator.dupe(u8, type_name);
            errdefer self.allocator.free(key);
            try map.put(key, std.ArrayList(TypeHit).empty);
        }
        const entry = map.getEntry(type_name).?;
        const first_use = try seen.getOrPut(entry.key_ptr.*);
        if (!first_use.found_existing) {
            try file_types.append(self.allocator, entry.key_ptr.*);
        }
        return entry.value_ptr;
    }

    /// Remove `path`'s hits from each of `types` in `map`, deleting entries that
    /// become empty.
    fn dropFileHits(
        self: *TypeIndex,
        map: *std.StringHashMap(std.ArrayList(TypeHit)),
        types: []const []const u8,
        path: []const u8,
    ) void {
        for (types) |type_name| {
            const list = map.getPtr(type_name) orelse continue;
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i].path, path)) {
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                if (map.fetchRemove(type_name)) |kv| {
                    var mutable_list = kv.value;
                    mutable_list.deinit(self.allocator);
                    self.allocator.free(kv.key);
                }
            }
        }
    }

    /// Remove all entries for a given file path.
    pub fn removeFile(self: *TypeIndex, path: []const u8) void {
        if (self.file_return_types.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.dropFileHits(&self.return_type_map, removed.value, path);
            self.allocator.free(removed.value);
        }
        if (self.file_param_types.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.dropFileHits(&self.param_type_map, removed.value, path);
            self.allocator.free(removed.value);
        }
    }

    /// Query: find all symbols with a given return type (exact match).
    pub fn findByReturnType(self: *const TypeIndex, return_type: []const u8) []const TypeHit {
        if (self.return_type_map.get(return_type)) |hits| return hits.items;
        return &.{};
    }

    /// Query: find all symbols accepting a given param type (exact match).
    pub fn findByParamType(self: *const TypeIndex, param_type: []const u8) []const TypeHit {
        if (self.param_type_map.get(param_type)) |hits| return hits.items;
        return &.{};
    }

    /// Query: fuzzy search return types (substring match).
    pub fn searchReturnTypes(self: *const TypeIndex, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const TypeHit {
        var results: std.ArrayList(TypeHit) = .empty;
        errdefer results.deinit(allocator);

        var iter = self.return_type_map.iterator();
        while (iter.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, query) != null) {
                for (entry.value_ptr.items) |hit| {
                    if (results.items.len >= max_results) break;
                    try results.append(allocator, hit);
                }
            }
            if (results.items.len >= max_results) break;
        }
        return try results.toOwnedSlice(allocator);
    }

    /// Query: fuzzy search param types (substring match).
    pub fn searchParamTypes(self: *const TypeIndex, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const TypeHit {
        var results: std.ArrayList(TypeHit) = .empty;
        errdefer results.deinit(allocator);

        var iter = self.param_type_map.iterator();
        while (iter.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, query) != null) {
                for (entry.value_ptr.items) |hit| {
                    if (results.items.len >= max_results) break;
                    try results.append(allocator, hit);
                }
            }
            if (results.items.len >= max_results) break;
        }
        return try results.toOwnedSlice(allocator);
    }

    pub fn returnTypeCount(self: *const TypeIndex) usize {
        return self.return_type_map.count();
    }

    pub fn paramTypeCount(self: *const TypeIndex) usize {
        return self.param_type_map.count();
    }
};
