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

        var rt_types: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (rt_types.items) |t| self.allocator.free(t);
            rt_types.deinit(self.allocator);
        }
        var pt_types: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (pt_types.items) |t| self.allocator.free(t);
            pt_types.deinit(self.allocator);
        }

        for (symbols) |sym| {
            if (sym.return_type) |rt| {
                const rt_copy = try self.allocator.dupe(u8, rt);
                errdefer self.allocator.free(rt_copy);

                const gop = try self.return_type_map.getOrPut(rt_copy);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(TypeHit).empty;
                    try rt_types.append(self.allocator, rt_copy);
                } else {
                    self.allocator.free(rt_copy);
                }
                try gop.value_ptr.append(self.allocator, .{
                    .path = path,
                    .symbol_name = sym.name,
                    .line_start = sym.line_start,
                });
            }

            for (sym.param_types) |pt| {
                const pt_copy = try self.allocator.dupe(u8, pt);
                errdefer self.allocator.free(pt_copy);

                const gop = try self.param_type_map.getOrPut(pt_copy);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(TypeHit).empty;
                    try pt_types.append(self.allocator, pt_copy);
                } else {
                    self.allocator.free(pt_copy);
                }
                try gop.value_ptr.append(self.allocator, .{
                    .path = path,
                    .symbol_name = sym.name,
                    .line_start = sym.line_start,
                });
            }
        }

        try self.file_return_types.put(try self.allocator.dupe(u8, path), try rt_types.toOwnedSlice(self.allocator));
        try self.file_param_types.put(try self.allocator.dupe(u8, path), try pt_types.toOwnedSlice(self.allocator));
    }

    /// Remove all entries for a given file path.
    pub fn removeFile(self: *TypeIndex, path: []const u8) void {
        if (self.file_return_types.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            for (removed.value) |rt| {
                // Remove hits for this path from the return_type_map entry
                if (self.return_type_map.getPtr(rt)) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) {
                        if (std.mem.eql(u8, list.items[i].path, path)) {
                            _ = list.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    // If the list is now empty, remove the entire entry
                    if (list.items.len == 0) {
                        if (self.return_type_map.fetchRemove(rt)) |kv| {
                            var mutable_list = kv.value;
                            mutable_list.deinit(self.allocator);
                            self.allocator.free(kv.key);
                        }
                    }
                }
            }
            self.allocator.free(removed.value);
        }

        if (self.file_param_types.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            for (removed.value) |pt| {
                if (self.param_type_map.getPtr(pt)) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) {
                        if (std.mem.eql(u8, list.items[i].path, path)) {
                            _ = list.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    if (list.items.len == 0) {
                        if (self.param_type_map.fetchRemove(pt)) |kv| {
                            var mutable_list = kv.value;
                            mutable_list.deinit(self.allocator);
                            self.allocator.free(kv.key);
                        }
                    }
                }
            }
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
