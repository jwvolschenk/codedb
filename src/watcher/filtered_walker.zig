const std = @import("std");
const skip_rules = @import("skip_rules.zig");

/// Recursive directory walker that prunes skip_dirs before descending.
/// Unlike std.Io.Dir.walk(), this never enters .git, node_modules, etc.,
/// avoiding the CPU cost of traversing potentially huge directory trees.
pub const FilteredWalker = struct {
    const StackItem = struct {
        dir_handle: std.Io.Dir,
        iter: std.Io.Dir.Iterator,
    };

    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_prefix_len: usize = 0,
    ignore_patterns: std.ArrayList([]const u8) = .empty,
    codedbignore_hash: ?u64 = null,
    real_root: []const u8 = &.{},
    visited_real_paths: std.StringHashMapUnmanaged(void) = .empty,

    pub const Entry = struct {
        path: []const u8, // relative path — valid until next call to next()
    };

    pub fn init(io: std.Io, root: std.Io.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var self = FilteredWalker{
            .stack = .empty,
            .name_buffer = .empty,
            .allocator = allocator,
            .io = io,
        };
        try self.stack.append(allocator, .{
            .dir_handle = root,
            .iter = root.iterate(),
        });

        var rr_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (root.realPathFile(io, ".", &rr_buf)) |rr_len| {
            const dup = try allocator.dupe(u8, rr_buf[0..rr_len]);
            self.real_root = dup;
            const seed = try allocator.dupe(u8, rr_buf[0..rr_len]);
            try self.visited_real_paths.put(allocator, seed, {});
        } else |_| {}

        if (root.readFileAlloc(io, ".codedbignore", allocator, .limited(64 * 1024))) |content| {
            self.codedbignore_hash = std.hash.Wyhash.hash(0, content);
            defer allocator.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                const duped = try allocator.dupe(u8, trimmed);
                try self.ignore_patterns.append(allocator, duped);
            }
        } else |_| {}

        if (root.readFileAlloc(io, ".gitignore", allocator, .limited(64 * 1024))) |content| {
            defer allocator.free(content);
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                if (trimmed[0] == '!') continue;
                const duped = try allocator.dupe(u8, trimmed);
                try self.ignore_patterns.append(allocator, duped);
            }
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *FilteredWalker) void {
        for (self.stack.items, 0..) |*item, i| {
            if (i > 0) item.dir_handle.close(self.io);
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
        for (self.ignore_patterns.items) |p| self.allocator.free(p);
        self.ignore_patterns.deinit(self.allocator);
        var it = self.visited_real_paths.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.visited_real_paths.deinit(self.allocator);
        if (self.real_root.len > 0) self.allocator.free(self.real_root);
    }

    fn isIgnored(self: *FilteredWalker, name: []const u8, full_path: []const u8) bool {
        for (self.ignore_patterns.items) |pattern| {
            const pat = if (std.mem.startsWith(u8, pattern, "**/")) pattern[3..] else pattern;
            if (pat.len == 0) continue;

            if (pat.len > 1 and pat[0] == '/') {
                const anchored = pat[1..];
                const clean = if (std.mem.endsWith(u8, anchored, "/")) anchored[0 .. anchored.len - 1] else anchored;
                if (skip_rules.eqlAsciiIgnoreCase(full_path, clean) or std.mem.startsWith(u8, full_path, anchored)) return true;
                continue;
            }
            if (std.mem.endsWith(u8, pat, "/")) {
                const dir_name = pat[0 .. pat.len - 1];
                if (skip_rules.eqlAsciiIgnoreCase(name, dir_name)) return true;
                continue;
            }
            if (std.mem.indexOfScalar(u8, pat, '*')) |_| {
                if (skip_rules.matchSimpleGlob(name, pat)) return true;
                continue;
            }
            if (skip_rules.eqlAsciiIgnoreCase(name, pat)) return true;
            if (std.mem.startsWith(u8, full_path, pat) and
                full_path.len > pat.len and full_path[pat.len] == '/') return true;
        }
        return false;
    }

    pub fn next(self: *FilteredWalker) !?Entry {
        self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next(self.io)) |entry| {
                if (entry.kind == .directory) {
                    if (skip_rules.shouldSkipDir(entry.name)) continue;
                    if (self.ignore_patterns.items.len > 0) {
                        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const check_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (self.isIgnored(entry.name, check_path)) continue;
                    }
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    errdefer sub.close(self.io);
                    const saved_len = self.name_buffer.items.len;
                    errdefer self.name_buffer.shrinkRetainingCapacity(saved_len);

                    if (self.name_buffer.items.len > 0)
                        try self.name_buffer.append(self.allocator, '/');
                    try self.name_buffer.appendSlice(self.allocator, entry.name);
                    self.dir_prefix_len = self.name_buffer.items.len;

                    try self.stack.append(self.allocator, .{
                        .dir_handle = sub,
                        .iter = sub.iterate(),
                    });
                    continue;
                }

                if (entry.kind != .file) {
                    if (entry.kind != .sym_link) continue;
                    const target_stat = top.dir_handle.statFile(self.io, entry.name, .{}) catch continue;
                    if (target_stat.kind == .directory) {
                        if (skip_rules.shouldSkipDir(entry.name)) continue;
                        if (self.ignore_patterns.items.len > 0) {
                            var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const check_path = if (self.dir_prefix_len > 0)
                                std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                            else
                                entry.name;
                            if (self.isIgnored(entry.name, check_path)) continue;
                        }
                        var rt_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const rt_len = top.dir_handle.realPathFile(self.io, entry.name, &rt_buf) catch continue;
                        const real_target = rt_buf[0..rt_len];
                        if (self.real_root.len == 0) continue;
                        if (!std.mem.startsWith(u8, real_target, self.real_root)) continue;
                        if (real_target.len != self.real_root.len and real_target[self.real_root.len] != '/') continue;
                        const gop = self.visited_real_paths.getOrPut(self.allocator, real_target) catch continue;
                        if (gop.found_existing) continue;
                        const dup = self.allocator.dupe(u8, real_target) catch {
                            _ = self.visited_real_paths.remove(real_target);
                            continue;
                        };
                        gop.key_ptr.* = dup;
                        const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                        errdefer sub.close(self.io);
                        const saved_len_sym = self.name_buffer.items.len;
                        errdefer self.name_buffer.shrinkRetainingCapacity(saved_len_sym);
                        if (self.name_buffer.items.len > 0)
                            try self.name_buffer.append(self.allocator, '/');
                        try self.name_buffer.appendSlice(self.allocator, entry.name);
                        self.dir_prefix_len = self.name_buffer.items.len;
                        try self.stack.append(self.allocator, .{
                            .dir_handle = sub,
                            .iter = sub.iterate(),
                        });
                        continue;
                    }
                    if (target_stat.kind != .file) continue;
                }

                if (self.dir_prefix_len > 0)
                    try self.name_buffer.append(self.allocator, '/');
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                if (self.ignore_patterns.items.len > 0 and self.isIgnored(entry.name, self.name_buffer.items)) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }

                return .{ .path = self.name_buffer.items };
            } else {
                if (self.stack.items.len > 1) {
                    var item = self.stack.pop().?;
                    item.dir_handle.close(self.io);
                } else {
                    _ = self.stack.pop();
                }
                if (std.mem.lastIndexOfScalar(u8, self.name_buffer.items[0..self.dir_prefix_len], '/')) |pos| {
                    self.dir_prefix_len = pos;
                } else {
                    self.dir_prefix_len = 0;
                }
                self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
            }
        }
        return null;
    }
};
