// codedb — forward/reverse file dependency graph.
const std = @import("std");

pub const DependencyGraph = struct {
    forward: std.StringHashMap(std.ArrayList([]const u8)),
    reverse: std.StringHashMap(std.StringHashMap(void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .forward = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .reverse = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DependencyGraph) void {
        var fwd_iter = self.forward.iterator();
        while (fwd_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.forward.deinit();

        var rev_iter = self.reverse.iterator();
        while (rev_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.reverse.deinit();
    }

    pub fn setDeps(self: *DependencyGraph, path: []const u8, deps: std.ArrayList([]const u8)) !void {
        // Remove old reverse edges for this path
        if (self.forward.getPtr(path)) |old_deps| {
            for (old_deps.items) |old_dep| {
                if (self.reverse.getPtr(old_dep)) |rev_set| {
                    _ = rev_set.remove(path);
                }
            }
            old_deps.deinit(self.allocator);
        }

        // Set forward edge
        const gop = try self.forward.getOrPut(path);
        gop.key_ptr.* = path;
        gop.value_ptr.* = deps;

        // Add reverse edges: for each dep, record that `path` depends on it
        for (deps.items) |dep| {
            const rev_gop = try self.reverse.getOrPut(dep);
            if (!rev_gop.found_existing) {
                rev_gop.key_ptr.* = dep;
                rev_gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
            }
            try rev_gop.value_ptr.put(path, {});
        }
    }

    pub fn remove(self: *DependencyGraph, path: []const u8) void {
        // Remove forward edges and their reverse counterparts
        if (self.forward.getPtr(path)) |deps| {
            for (deps.items) |dep| {
                if (self.reverse.getPtr(dep)) |rev_set| {
                    _ = rev_set.remove(path);
                }
            }
            deps.deinit(self.allocator);
            _ = self.forward.remove(path);
        }
        // Remove path from reverse index (others importing this path)
        // The entries in reverse[path] are the files that import `path`.
        // We don't remove those — they still have forward edges pointing here.
        // We just remove the reverse key if nobody imports this path anymore.
        // Actually, we should NOT remove reverse[path] here — other files
        // still reference `path` in their forward edges. The reverse entry
        // is cleaned up lazily when those files are re-indexed or removed.
    }

    pub fn getForwardDeps(self: *const DependencyGraph, path: []const u8) ?[]const []const u8 {
        const deps = self.forward.get(path) orelse return null;
        return deps.items;
    }

    pub fn getImportedBy(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        // Extract basename for matching (e.g., "src/store.zig" -> "store.zig")
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        const stem = fileStem(basename);

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        // O(1) lookup: check reverse index for exact path match
        if (self.reverse.get(path)) |rev_set| {
            var rev_iter = rev_set.keyIterator();
            while (rev_iter.next()) |key_ptr| {
                const dep_path = try allocator.dupe(u8, key_ptr.*);
                try result.append(allocator, dep_path);
            }
        }

        // Also check basename match (imports often use short names)
        if (!std.mem.eql(u8, path, basename)) {
            if (self.reverse.get(basename)) |rev_set| {
                try appendReverseSetUnique(rev_set, &result, allocator);
            }
        }

        // Relative JS/TS-style imports are often extensionless (`./foo`) while
        // indexed files include extensions (`foo.ts`, `foo.js`). Match the file
        // stem as a final exact-key fallback.
        if (!std.mem.eql(u8, stem, basename)) {
            if (self.reverse.get(stem)) |rev_set| {
                try appendReverseSetUnique(rev_set, &result, allocator);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn importedByCount(self: *const DependencyGraph, path: []const u8) usize {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;
        const stem = fileStem(basename);
        var total: usize = 0;
        const exact_set = self.reverse.get(path);
        if (exact_set) |rev_set| total += rev_set.count();
        const basename_set = if (!std.mem.eql(u8, path, basename)) self.reverse.get(basename) else null;
        const stem_set = if (!std.mem.eql(u8, stem, basename)) self.reverse.get(stem) else null;
        if (!std.mem.eql(u8, path, basename)) {
            if (basename_set) |rev_set| total += reverseSetAdditionalCount(rev_set, exact_set, null);
        }
        if (!std.mem.eql(u8, stem, basename)) {
            if (stem_set) |rev_set| total += reverseSetAdditionalCount(rev_set, exact_set, basename_set);
        }
        return total;
    }

    pub fn getTransitiveDependents(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        var queue: std.ArrayList(struct { path: []const u8, depth: u32 }) = .empty;
        defer queue.deinit(allocator);

        try visited.put(path, {});
        if (!std.mem.eql(u8, path, basename)) {
            try visited.put(basename, {});
        }
        try queue.append(allocator, .{ .path = path, .depth = 0 });
        if (!std.mem.eql(u8, path, basename)) {
            try queue.append(allocator, .{ .path = basename, .depth = 0 });
        }

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const item = queue.items[head];
            head += 1;

            const depth_limit = max_depth orelse std.math.maxInt(u32);
            if (item.depth >= depth_limit) continue;

            if (self.reverse.get(item.path)) |rev_set| {
                var rev_iter = rev_set.keyIterator();
                while (rev_iter.next()) |key_ptr| {
                    const dep = key_ptr.*;
                    if (!visited.contains(dep)) {
                        try visited.put(dep, {});
                        const dep_copy = try allocator.dupe(u8, dep);
                        try result.append(allocator, dep_copy);
                        try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });

                        // Also enqueue basename for this dep
                        const dep_basename = if (std.mem.lastIndexOfScalar(u8, dep, '/')) |pos| dep[pos + 1 ..] else dep;
                        if (!std.mem.eql(u8, dep, dep_basename) and !visited.contains(dep_basename)) {
                            try visited.put(dep_basename, {});
                            try queue.append(allocator, .{ .path = dep_basename, .depth = item.depth + 1 });
                        }
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn getTransitiveDependencies(self: *const DependencyGraph, path: []const u8, allocator: std.mem.Allocator, max_depth: ?u32) ![]const []const u8 {
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        var queue: std.ArrayList(struct { path: []const u8, depth: u32 }) = .empty;
        defer queue.deinit(allocator);

        try visited.put(path, {});
        try queue.append(allocator, .{ .path = path, .depth = 0 });

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const item = queue.items[head];
            head += 1;

            const depth_limit = max_depth orelse std.math.maxInt(u32);
            if (item.depth >= depth_limit) continue;

            if (self.forward.get(item.path)) |fwd_deps| {
                for (fwd_deps.items) |dep| {
                    if (!visited.contains(dep)) {
                        try visited.put(dep, {});
                        const dep_copy = try allocator.dupe(u8, dep);
                        try result.append(allocator, dep_copy);
                        try queue.append(allocator, .{ .path = dep, .depth = item.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn count(self: *const DependencyGraph) usize {
        return self.forward.count();
    }

    pub fn iterator(self: *const DependencyGraph) std.StringHashMap(std.ArrayList([]const u8)).Iterator {
        return self.forward.iterator();
    }

    pub fn get(self: *const DependencyGraph, key: []const u8) ?std.ArrayList([]const u8) {
        return self.forward.get(key);
    }

    pub fn keyIterator(self: *const DependencyGraph) std.StringHashMap(std.ArrayList([]const u8)).KeyIterator {
        return self.forward.keyIterator();
    }
};

fn fileStem(basename: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        if (dot > 0) return basename[0..dot];
    }
    return basename;
}

fn appendReverseSetUnique(rev_set: std.StringHashMap(void), result: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var rev_iter = rev_set.keyIterator();
    while (rev_iter.next()) |key_ptr| {
        var already = false;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing, key_ptr.*)) {
                already = true;
                break;
            }
        }
        if (!already) {
            const dep_path = try allocator.dupe(u8, key_ptr.*);
            try result.append(allocator, dep_path);
        }
    }
}

fn reverseSetAdditionalCount(rev_set: std.StringHashMap(void), existing_a: ?std.StringHashMap(void), existing_b: ?std.StringHashMap(void)) usize {
    var count: usize = 0;
    var rev_iter = rev_set.keyIterator();
    while (rev_iter.next()) |key_ptr| {
        const key = key_ptr.*;
        if (existing_a) |set| if (set.contains(key)) continue;
        if (existing_b) |set| if (set.contains(key)) continue;
        count += 1;
    }
    return count;
}
