const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../cio.zig");
const Store = @import("../store.zig").Store;
const Explorer = @import("../explore.zig").Explorer;
const git_mod = @import("../git.zig");
const FilteredWalker = @import("filtered_walker.zig").FilteredWalker;
const skip_rules = @import("skip_rules.zig");

pub const EventKind = enum(u8) {
    created,
    modified,
    deleted,
};

pub const FsEvent = struct {
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize,
    kind: EventKind,
    seq: u64,

    pub fn init(src_path: []const u8, kind: EventKind, seq: u64) ?FsEvent {
        if (src_path.len > std.fs.max_path_bytes) return null;
        var event = FsEvent{
            .path_len = src_path.len,
            .kind = kind,
            .seq = seq,
        };
        @memcpy(event.path_buf[0..src_path.len], src_path);
        return event;
    }

    pub fn path(self: *const FsEvent) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const EventQueue = struct {
    const CAPACITY = 4096;

    events: [CAPACITY]?FsEvent = [_]?FsEvent{null} ** CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    mu: cio.Mutex = .{},

    pub fn push(self: *EventQueue, event: FsEvent) bool {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_tail = self.tail;
        const next_tail = (cur_tail + 1) % CAPACITY;
        if (next_tail == self.head) return false;
        self.events[cur_tail] = event;
        self.tail = next_tail;
        return true;
    }

    pub fn pop(self: *EventQueue) ?FsEvent {
        self.mu.lock();
        defer self.mu.unlock();

        const cur_head = self.head;
        if (cur_head == self.tail) return null;
        const event = self.events[cur_head];
        self.head = (cur_head + 1) % CAPACITY;
        return event;
    }
};

const FileState = struct {
    mtime: i64, // milliseconds since epoch — cheap stat check
    size: u64, // cheap change discriminator before hashing
    hash: u64, // wyhash of content — confirms actual change
    seen: bool, // set during current poll cycle for deletion detection
};

const FileMap = std.StringHashMap(FileState);

/// Background thread: polls for incremental FS changes.
pub fn incrementalLoop(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, root: []const u8, shutdown: *std.atomic.Value(bool), scan_done: *std.atomic.Value(bool)) void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    while (!scan_done.load(.acquire)) {
        if (shutdown.load(.acquire)) return;
        cio.sleepMs(100);
    }

    var known = FileMap.init(backing);
    defer {
        var iter = known.iterator();
        while (iter.next()) |kv| {
            backing.free(kv.key_ptr.*);
        }
        known.deinit();
    }
    {
        var snap_arena = std.heap.ArenaAllocator.init(backing);
        defer snap_arena.deinit();
        const tmp = snap_arena.allocator();
        const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = FilteredWalker.init(io, dir, tmp) catch return;
        defer walker.deinit();
        while (walker.next() catch null) |entry| {
            const stat = dir.statFile(io, entry.path, .{}) catch continue;
            const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
            const duped = backing.dupe(u8, entry.path) catch continue;
            known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
        }
    }

    var last_git_head: ?[40]u8 = git_mod.getGitHead(root, backing) catch null;

    var git_head_mtime: i128 = blk: {
        const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk -1;
        defer root_dir.close(io);
        const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk -1;
        break :blk @intCast(st.mtime.nanoseconds);
    };

    while (!shutdown.load(.acquire)) {
        drainNotifyFile(io, store, explorer, queue, &known, root, backing);

        cio.sleepMs(2 * std.time.ns_per_s / 1_000_000);

        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            {
                const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch break :blk false;
                defer root_dir.close(io);
                const st = root_dir.statFile(io, ".git/HEAD", .{}) catch break :blk false;
                const st_mtime: i128 = @intCast(st.mtime.nanoseconds);
                if (st_mtime == git_head_mtime) break :blk false;
                git_head_mtime = st_mtime;
            }
            current_head = git_mod.getGitHead(root, backing) catch null;
            if (last_git_head == null and current_head == null) break :blk false;
            if (last_git_head == null or current_head == null) break :blk true;
            break :blk !std.mem.eql(u8, &last_git_head.?, &current_head.?);
        };

        if (head_changed) {
            std.log.info("git HEAD changed — re-scanning", .{});
            last_git_head = current_head;

            var remove_list: std.ArrayList([]const u8) = .empty;
            defer remove_list.deinit(backing);
            var kiter = known.iterator();
            while (kiter.next()) |kv| {
                remove_list.append(backing, kv.key_ptr.*) catch {};
            }
            for (remove_list.items) |path| {
                explorer.removeFile(path);
            }

            var kiter2 = known.iterator();
            while (kiter2.next()) |kv| backing.free(kv.key_ptr.*);
            known.clearRetainingCapacity();

            var rescan_arena = std.heap.ArenaAllocator.init(backing);
            defer rescan_arena.deinit();
            const tmp = rescan_arena.allocator();
            const dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = FilteredWalker.init(io, dir, tmp) catch continue;
            defer walker.deinit();
            explorer.setIgnorePatterns(walker.ignore_patterns.items) catch {};
            const max_trigram_files: usize = 15_000;
            var file_count: usize = 0;
            while (walker.next() catch null) |entry| {
                const stat = dir.statFile(io, entry.path, .{}) catch continue;
                _ = store.recordSnapshot(entry.path, stat.size, 0) catch {};
                file_count += 1;
                const effective_skip = file_count > max_trigram_files;
                indexFileContent(io, explorer, dir, entry.path, backing, effective_skip) catch {};
                const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
                const duped = backing.dupe(u8, entry.path) catch continue;
                known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch backing.free(duped);
            }
            continue;
        }

        var cycle_arena = std.heap.ArenaAllocator.init(backing);
        defer cycle_arena.deinit();

        incrementalDiff(io, store, explorer, queue, &known, root, backing, cycle_arena.allocator()) catch |err| {
            std.log.err("watcher: diff failed: {}", .{err});
        };
    }
}

fn hashFile(io: std.Io, dir: std.Io.Dir, path: []const u8, size: u64) !u64 {
    if (skip_rules.shouldSkipFile(path)) return 0;
    if (size > skip_rules.max_indexed_file_bytes) return 0;
    const file = dir.openFile(io, path, .{}) catch return std.math.maxInt(u64);
    defer file.close(io);

    var hasher = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, &buf, offset) catch return std.math.maxInt(u64);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
        if (n < buf.len) break;
    }
    return hasher.final();
}

fn pushEventOrWait(queue: *EventQueue, event: FsEvent) void {
    _ = queue.push(event);
}

fn incrementalDiff(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, persistent: std.mem.Allocator, tmp: std.mem.Allocator) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var known_iter = known.iterator();
    while (known_iter.next()) |kv| {
        kv.value_ptr.seen = false;
    }

    var walker = try FilteredWalker.init(io, dir, tmp);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));

        if (known.getEntry(entry.path)) |known_entry| {
            const old = known_entry.value_ptr;
            old.seen = true;

            if (old.mtime == mtime) continue;

            var hash: u64 = 0;
            if (old.size == stat.size) {
                hash = hashFile(io, dir, entry.path, stat.size) catch 0;
            }
            if (old.size == stat.size and hash != 0 and old.hash != 0 and hash == old.hash) {
                old.mtime = mtime;
                old.size = stat.size;
                continue;
            }

            const seq = try store.recordSnapshot(entry.path, stat.size, hash);
            old.mtime = mtime;
            old.size = stat.size;
            old.hash = hash;
            const stable_path = known_entry.key_ptr.*;
            if (FsEvent.init(stable_path, .modified, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(io, explorer, dir, stable_path, tmp, false) catch {};
        } else {
            const duped = try persistent.dupe(u8, entry.path);
            errdefer persistent.free(duped);
            const seq = try store.recordSnapshot(duped, stat.size, 0);
            try known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = true });
            if (FsEvent.init(duped, .created, seq)) |ev| pushEventOrWait(queue, ev);
            indexFileContent(io, explorer, dir, duped, tmp, false) catch {};
        }
    }

    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(tmp);

    var iter = known.iterator();
    while (iter.next()) |kv| {
        if (!kv.value_ptr.seen) {
            try to_remove.append(tmp, kv.key_ptr.*);
        }
    }
    for (to_remove.items) |path| {
        const seq = store.recordDelete(path, 0) catch continue;
        explorer.removeFile(path);
        if (known.fetchRemove(path)) |kv| {
            if (FsEvent.init(kv.key, .deleted, seq)) |ev| pushEventOrWait(queue, ev);
            persistent.free(kv.key);
        }
    }
}

fn indexFileContent(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    _ = allocator;
    if (skip_rules.shouldSkipFile(path)) return;
    const stat = try dir.statFile(io, path, .{});
    if (stat.size > skip_rules.max_indexed_file_bytes) return;
    var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer content_arena.deinit();
    const content = try dir.readFileAlloc(io, path, content_arena.allocator(), .limited(skip_rules.max_indexed_file_bytes));
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    const effective_skip_trigram = skip_trigram or (content.len > 64 * 1024);
    if (effective_skip_trigram) {
        try explorer.indexFileSkipTrigram(path, content);
    } else {
        try explorer.indexFile(path, content);
    }
}

fn drainNotifyFile(io: std.Io, store: *Store, explorer: *Explorer, queue: *EventQueue, known: *FileMap, root: []const u8, alloc: std.mem.Allocator) void {
    const notify_path = "/tmp/codedb-notify";
    const file = std.Io.Dir.cwd().openFile(io, notify_path, .{ .mode = .read_write }) catch return;
    defer file.close(io);

    if (comptime builtin.os.tag != .windows) {
        cio.flockFd(file.handle, cio.LOCK_EX);
        defer cio.flockFd(file.handle, cio.LOCK_UN);
    }

    const file_len = file.length(io) catch return;
    if (file_len == 0) return;
    const cap: u64 = 64 * 1024;
    const read_len: usize = @intCast(@min(file_len, cap));
    const data = alloc.alloc(u8, read_len) catch return;
    defer alloc.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return;
    if (n == 0) return;
    const data_slice = data[0..n];

    var keep: std.ArrayList(u8) = .empty;
    defer keep.deinit(alloc);
    {
        var scan = std.mem.splitScalar(u8, data_slice, '\n');
        while (scan.next()) |line| {
            const path = std.mem.trim(u8, line, " \t\r");
            if (path.len == 0) continue;
            if (notifyLineBelongsToOtherRoot(path, root)) {
                keep.appendSlice(alloc, path) catch {};
                keep.append(alloc, '\n') catch {};
            }
        }
    }
    file.setLength(io, 0) catch return;
    if (keep.items.len > 0) {
        file.writePositionalAll(io, keep.items, 0) catch {};
    }

    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return;
    defer dir.close(io);

    var lines = std.mem.splitScalar(u8, data_slice, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        if (notifyLineBelongsToOtherRoot(path, root)) continue;

        const rel = if (std.mem.startsWith(u8, path, root))
            std.mem.trimStart(u8, path[root.len..], "/")
        else
            path;

        const stat = dir.statFile(io, rel, .{}) catch continue;
        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms));
        if (known.getPtr(rel)) |existing| {
            if (existing.mtime == mtime and existing.size == stat.size) continue;
        }

        indexFileContent(io, explorer, dir, rel, alloc, false) catch continue;

        const hash = hashFile(io, dir, rel, stat.size) catch continue;
        if (known.getPtr(rel)) |existing| {
            existing.mtime = mtime;
            existing.size = stat.size;
            existing.hash = hash;
        }

        if (FsEvent.init(rel, .modified, store.currentSeq())) |ev| {
            _ = queue.push(ev);
        }
    }
}

/// True when `line` is an absolute path outside `root` — i.e. it belongs to a
/// different project's watcher and must not be consumed here. Relative lines
/// are ambiguous (no project to attribute them to) and fall through to the
/// existing per-root handling, preserving prior behavior.
pub fn notifyLineBelongsToOtherRoot(line: []const u8, root: []const u8) bool {
    if (line.len == 0 or line[0] != '/') return false;
    return !pathUnderRoot(line, root);
}

fn pathUnderRoot(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/';
}
