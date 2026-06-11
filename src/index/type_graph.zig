// codedb — Type graph for inheritance/interface relationships.
//
// Tracks: type_name → base types (what it extends/implements)
//         type_name → derived types (what extends/implements it)
// Populated during indexing from class/interface declaration detail text.
// Enables O(1) "find all implementations of IUserRepository" queries.

const std = @import("std");

pub const TypeGraph = struct {
    /// type_name → set of base type names (what this type extends/implements)
    bases: std.StringHashMap(std.StringHashMap(void)),
    /// type_name → set of derived type names (what extends/implements this type)
    derived: std.StringHashMap(std.StringHashMap(void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeGraph {
        return .{
            .bases = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .derived = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeGraph) void {
        var bases_iter = self.bases.iterator();
        while (bases_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var set_iter = entry.value_ptr.iterator();
            while (set_iter.next()) |s| self.allocator.free(s.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.bases.deinit();

        var derived_iter = self.derived.iterator();
        while (derived_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var set_iter = entry.value_ptr.iterator();
            while (set_iter.next()) |s| self.allocator.free(s.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.derived.deinit();
    }

    /// Record that `type_name` extends/implements `base_name`.
    pub fn addRelationship(self: *TypeGraph, type_name: []const u8, base_name: []const u8) !void {
        // Skip self-references and keywords
        if (std.mem.eql(u8, type_name, base_name)) return;
        if (isHierarchyKeyword(base_name)) return;

        // Add to bases map: type_name -> base_name
        const type_copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_copy);
        const base_copy = try self.allocator.dupe(u8, base_name);
        errdefer self.allocator.free(base_copy);

        const bases_gop = try self.bases.getOrPut(type_copy);
        if (!bases_gop.found_existing) {
            bases_gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
        } else {
            self.allocator.free(type_copy);
        }
        const base_insert = try bases_gop.value_ptr.getOrPut(base_copy);
        if (base_insert.found_existing) {
            self.allocator.free(base_copy);
        }

        // Add to derived map: base_name -> type_name
        const base_copy2 = try self.allocator.dupe(u8, base_name);
        errdefer self.allocator.free(base_copy2);
        const type_copy2 = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_copy2);

        const derived_gop = try self.derived.getOrPut(base_copy2);
        if (!derived_gop.found_existing) {
            derived_gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
        } else {
            self.allocator.free(base_copy2);
        }
        const type_insert = try derived_gop.value_ptr.getOrPut(type_copy2);
        if (type_insert.found_existing) {
            self.allocator.free(type_copy2);
        }
    }

    /// Get all types that extend/implement `base_name`.
    pub fn getDerived(self: *const TypeGraph, base_name: []const u8) []const []const u8 {
        if (self.derived.get(base_name)) |set| {
            // Convert set to slice (caller must not free)
            const result = self.allocator.alloc([]const u8, set.count()) catch return &.{};
            var i: usize = 0;
            var iter = set.iterator();
            while (iter.next()) |entry| {
                result[i] = entry.key_ptr.*;
                i += 1;
            }
            return result;
        }
        return &.{};
    }

    /// Get all types that `type_name` extends/implements.
    pub fn getBases(self: *const TypeGraph, type_name: []const u8) []const []const u8 {
        if (self.bases.get(type_name)) |set| {
            const result = self.allocator.alloc([]const u8, set.count()) catch return &.{};
            var i: usize = 0;
            var iter = set.iterator();
            while (iter.next()) |entry| {
                result[i] = entry.key_ptr.*;
                i += 1;
            }
            return result;
        }
        return &.{};
    }

    /// Remove all relationships for a given type (used when re-indexing a file).
    pub fn removeType(self: *TypeGraph, type_name: []const u8) void {
        // Remove from bases: type_name -> [base_names]
        if (self.bases.fetchRemove(type_name)) |removed| {
            self.allocator.free(removed.key);
            var base_iter = removed.value.iterator();
            while (base_iter.next()) |entry| {
                // Also remove from derived: base_name -> type_name
                if (self.derived.getPtr(entry.key_ptr.*)) |derived_set| {
                    _ = derived_set.remove(type_name);
                    if (derived_set.count() == 0) {
                        if (self.derived.fetchRemove(entry.key_ptr.*)) |dr| {
                            self.allocator.free(dr.key);
                            var mutable_set = dr.value;
                            mutable_set.deinit();
                        }
                    }
                }
                self.allocator.free(entry.key_ptr.*);
            }
            var mutable_removed = removed.value;
            mutable_removed.deinit();
        }

        // Remove from derived: type_name -> [derived_names]
        if (self.derived.fetchRemove(type_name)) |removed| {
            self.allocator.free(removed.key);
            var derived_iter = removed.value.iterator();
            while (derived_iter.next()) |entry| {
                // Also remove from bases: derived_name -> type_name
                if (self.bases.getPtr(entry.key_ptr.*)) |bases_set| {
                    _ = bases_set.remove(type_name);
                    if (bases_set.count() == 0) {
                        if (self.bases.fetchRemove(entry.key_ptr.*)) |br| {
                            self.allocator.free(br.key);
                            var mutable_set = br.value;
                            mutable_set.deinit();
                        }
                    }
                }
                self.allocator.free(entry.key_ptr.*);
            }
            var mutable_removed = removed.value;
            mutable_removed.deinit();
        }
    }

    fn isHierarchyKeyword(token: []const u8) bool {
        const keywords = [_][]const u8{ "extends", "implements", "class", "interface", "struct", "enum", "trait", "record", "abstract", "sealed", "final", "static", "public", "private", "protected", "internal", "override", "virtual", "async", "partial", "where", "super", "protocol", ":", ",", "with" };
        for (keywords) |kw| {
            if (std.mem.eql(u8, token, kw)) return true;
        }
        return false;
    }
};
