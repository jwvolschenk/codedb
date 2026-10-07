const project_file = @import("../project_file.zig");
const std = @import("std");
const gitignore = @import("../gitignore.zig");
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
    arena: std.heap.ArenaAllocator,
    git_rules: std.ArrayList(gitignore.Rule) = .empty,
    codedb_rules: []const gitignore.Rule = &.{},
    real_root: []const u8 = &.{},
    visited_real_paths: std.StringHashMapUnmanaged(void) = .empty,

    pub const Entry = struct {
        path: []const u8, // relative path — valid until next call to next()
    };

    /// Targeted counterpart to next(): same ordered rules along this path,
    /// without walking unrelated directories when read/outline misses the index.
    pub fn allowsPath(io: std.Io, root: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) bool {
        if (!project_file.isAllowedPath(path) or skip_rules.shouldSkip(path) or skip_rules.shouldSkipFile(path)) return false;
        var walker = init(io, root, allocator) catch return false;
        defer walker.deinit();
        var offset: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, offset, '/')) |slash| {
            if (walker.isIgnored(path[0..slash], true)) return false;
            const probe = std.fmt.allocPrint(allocator, "{s}/.gitignore", .{path[0..slash]}) catch return false;
            defer allocator.free(probe);
            const parent = project_file.openParent(io, root, probe) catch return false;
            defer parent.close(io);
            const base = std.fmt.allocPrint(allocator, "project/{s}", .{path[0..slash]}) catch return false;
            defer allocator.free(base);
            walker.loadRules(parent.dir, ".gitignore", base);
            offset = slash + 1;
        }
        return !walker.isIgnored(path, false);
    }

    pub fn init(io: std.Io, root: std.Io.Dir, allocator: std.mem.Allocator) !FilteredWalker {
        var self = FilteredWalker{
            .stack = .empty,
            .name_buffer = .empty,
            .allocator = allocator,
            .io = io,
            .arena = std.heap.ArenaAllocator.init(allocator),
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

        const a = self.arena.allocator();
        // Metadata is read through a separate directory capability; source
        // access correctly forbids .git, so that source API cannot open it.
        if (root.openDir(io, ".git", .{ .follow_symlinks = false })) |metadata| {
            defer metadata.close(io);
            self.loadRules(metadata, "info/exclude", "project");
        } else |_| {}
        self.loadRules(root, ".gitignore", "project");
        if (project_file.readAlloc(io, root, ".codedbignore", a, .limited(64 * 1024))) |content| {
            self.codedbignore_hash = std.hash.Wyhash.hash(0, content);
            self.codedb_rules = try gitignore.parse(a, content, "project");
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *FilteredWalker) void {
        self.arena.deinit();
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

    fn loadRules(self: *FilteredWalker, dir: std.Io.Dir, name: []const u8, base: []const u8) void {
        const a = self.arena.allocator();
        const content = project_file.readAlloc(self.io, dir, name, a, .limited(64 * 1024)) catch return;
        const owned_base = a.dupe(u8, base) catch return;
        const rules = gitignore.parse(a, content, owned_base) catch return;
        self.git_rules.appendSlice(a, rules) catch {};
    }

    fn isIgnored(self: *FilteredWalker, full_path: []const u8, is_dir: bool) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const virtual = std.fmt.bufPrint(&buf, "project/{s}", .{full_path}) catch return true;
        const a = self.arena.allocator();
        // .codedbignore has final precedence; security and built-in skips are
        // enforced independently before this matcher and cannot be negated.
        const cv = gitignore.verdict(a, self.codedb_rules, virtual, is_dir) catch return true;
        if (cv != .none) return cv == .ignore;
        return (gitignore.verdict(a, self.git_rules.items, virtual, is_dir) catch return true) == .ignore;
    }

    pub fn next(self: *FilteredWalker) !?Entry {
        self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next(self.io)) |entry| {
                if (entry.kind == .directory) {
                    if (skip_rules.shouldSkipDir(entry.name)) continue;
                    {
                        var check_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const check_path = if (self.dir_prefix_len > 0)
                            std.fmt.bufPrint(&check_buf, "{s}/{s}", .{ self.name_buffer.items[0..self.dir_prefix_len], entry.name }) catch entry.name
                        else
                            entry.name;
                        if (self.isIgnored(check_path, true)) continue;
                    }
                    const sub = top.dir_handle.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                    errdefer sub.close(self.io);
                    const saved_len = self.name_buffer.items.len;
                    errdefer self.name_buffer.shrinkRetainingCapacity(saved_len);

                    if (self.name_buffer.items.len > 0)
                        try self.name_buffer.append(self.allocator, '/');
                    try self.name_buffer.appendSlice(self.allocator, entry.name);
                    self.dir_prefix_len = self.name_buffer.items.len;
                    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const base = std.fmt.bufPrint(&base_buf, "project/{s}", .{self.name_buffer.items}) catch return error.NameTooLong;
                    self.loadRules(sub, ".gitignore", base);

                    try self.stack.append(self.allocator, .{
                        .dir_handle = sub,
                        .iter = sub.iterate(),
                    });
                    continue;
                }

                if (entry.kind != .file) continue;

                if (self.dir_prefix_len > 0)
                    try self.name_buffer.append(self.allocator, '/');
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                if (self.isIgnored(self.name_buffer.items, false)) {
                    self.name_buffer.shrinkRetainingCapacity(self.dir_prefix_len);
                    continue;
                }

                if (!project_file.isAllowedPath(self.name_buffer.items)) {
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
