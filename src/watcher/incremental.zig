const std = @import("std");
const builtin = @import("builtin");
const cio = @import("../cio.zig");
const Store = @import("../store.zig").Store;
const Explorer = @import("../explore.zig").Explorer;
const git_mod = @import("../git.zig");
const FilteredWalker = @import("filtered_walker.zig").FilteredWalker;
const skip_rules = @import("skip_rules.zig");
const budget = @import("budget.zig");

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
            known.put(duped, .{ .mtime = mtime, .size = stat.size, .hash = 0, .seen = false }) catch {
                backing.free(duped);
                continue;
            };
            // Seed sweep half 1 (#591 Task 5): a walked file the explorer has
            // never indexed was created while the server was down (and, for
            // non-git projects, missed by the git reconcile). Index it now.
            const missing = blk: {
                explorer.mu.lockShared();
                defer explorer.mu.unlockShared();
                break :blk !explorer.outlines.contains(entry.path);
            };
            if (missing) {
                indexFileContent(io, explorer, dir, entry.path, tmp, false) catch {};
                _ = store.recordSnapshot(entry.path, stat.size, 0) catch {};
            }
        }
        // Seed sweep half 2: an indexed path the walk never visited was
        // deleted while the server was down — evict it. (Before this sweep,
        // such entries lived in the index forever: the poll loop only diffs
        // against `known`, which was just seeded from the same walk.)
        var stale: std.ArrayList([]const u8) = .empty;
        defer {
            for (stale.items) |p| tmp.free(p);
            stale.deinit(tmp);
        }
        {
            explorer.mu.lockShared();
            defer explorer.mu.unlockShared();
            var oit = explorer.outlines.keyIterator();
            while (oit.next()) |k| {
                if (!known.contains(k.*)) {
                    const duped = tmp.dupe(u8, k.*) catch break;
                    stale.append(tmp, duped) catch {
                        tmp.free(duped);
                        break;
                    };
                }
            }
        }
        for (stale.items) |p| {
            _ = store.recordDelete(p, 0) catch {};
            explorer.removeFile(p);
        }
        if (stale.items.len > 0) {
            std.log.info("codedb: watcher seed sweep evicted {d} deleted-while-down files", .{stale.items.len});
        }
    }

    var last_git_head: ?[40]u8 = git_mod.getGitHead(root, backing) catch null;

    // Worktree/submodule-aware HEAD watching (#591 Task 6): resolve the REAL
    // git dir once — in linked worktrees and submodules `{root}/.git` is a
    // file, so the old `.git/HEAD` stat failed forever and branch switches
    // were invisible. Watch mtimes of HEAD (worktree-private), the current
    // symref target, and packed-refs (shared common dir).
    var head_watch: ?git_mod.HeadWatchPaths = git_mod.resolveHeadWatchPaths(io, root, backing);
    defer if (head_watch) |*hw| hw.deinit(backing);
    var watch_mtimes = [3]i128{ -1, -1, -1 };
    seedHeadWatchMtimes(io, head_watch, &watch_mtimes);

    // Slow-path safety net: every SLOW_VERIFY_CYCLES polls (~30s) compare the
    // SHA unconditionally. Covers resolveHeadWatchPaths failures (non-standard
    // layouts that used to mean total silence) and packed-refs rewrites within
    // mtime granularity.
    const SLOW_VERIFY_CYCLES: usize = 15;
    var poll_cycle: usize = 0;

    while (!shutdown.load(.acquire)) {
        drainNotifyFile(io, store, explorer, queue, &known, root, backing);

        cio.sleepMs(2 * std.time.ns_per_s / 1_000_000);
        poll_cycle +%= 1;

        var current_head: ?[40]u8 = last_git_head;
        const head_changed = blk: {
            const mtime_moved = headWatchMtimesChanged(io, head_watch, &watch_mtimes);
            const slow_verify = (poll_cycle % SLOW_VERIFY_CYCLES == 0);
            if (!mtime_moved and !slow_verify) break :blk false;
            current_head = git_mod.getGitHead(root, backing) catch null;
            if (last_git_head == null and current_head == null) break :blk false;
            if (last_git_head == null or current_head == null) break :blk true;
            break :blk !std.mem.eql(u8, &last_git_head.?, &current_head.?);
        };

        if (head_changed) {
            // Branch switch: the symref target changed, so re-resolve the
            // watch set (new ref_path) and re-seed its mtimes.
            if (head_watch) |*hw| hw.deinit(backing);
            head_watch = git_mod.resolveHeadWatchPaths(io, root, backing);
            seedHeadWatchMtimes(io, head_watch, &watch_mtimes);
        }

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
                if (file_count % budget.CHECK_INTERVAL == 0 and budget.shouldStopIndexing()) break;
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

fn seedHeadWatchMtimes(io: std.Io, head_watch: ?git_mod.HeadWatchPaths, mtimes: *[3]i128) void {
    mtimes.* = .{ -1, -1, -1 };
    const hw = head_watch orelse return;
    const paths = [3]?[]const u8{ hw.head_path, hw.ref_path, hw.packed_refs_path };
    for (paths, 0..) |maybe_path, i| {
        const p = maybe_path orelse continue;
        const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch continue;
        mtimes[i] = @intCast(st.mtime.nanoseconds);
    }
}

/// Stat the 2-3 watched absolute paths; true when any mtime moved (including
/// a path appearing or disappearing). Updates `mtimes` in place so a change
/// is reported once.
fn headWatchMtimesChanged(io: std.Io, head_watch: ?git_mod.HeadWatchPaths, mtimes: *[3]i128) bool {
    const hw = head_watch orelse return false;
    var changed = false;
    const paths = [3]?[]const u8{ hw.head_path, hw.ref_path, hw.packed_refs_path };
    for (paths, 0..) |maybe_path, i| {
        const p = maybe_path orelse continue;
        const new_mtime: i128 = blk: {
            const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch break :blk -1;
            break :blk @intCast(st.mtime.nanoseconds);
        };
        if (new_mtime != mtimes[i]) {
            mtimes[i] = new_mtime;
            changed = true;
        }
    }
    return changed;
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

/// Shared read-and-index funnel: skip rules (extensions, lockfiles, sensitive
/// paths, generated code), size cap, binary sniff, trigram-size cutoff. The
/// warm-start reconcile (reconcile.zig) reuses this so every indexing path
/// applies identical filtering — do not fork a second copy of this logic.
pub fn indexFileContent(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
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
    // Portable notify path (#591 Task 7): %TEMP% on Windows, $TMPDIR/tmp on
    // POSIX — the old hardcoded /tmp/codedb-notify simply never worked on
    // Windows (and ignored per-user TMPDIR on macOS).
    var notify_buf: [std.fs.max_path_bytes]u8 = undefined;
    const notify_path = std.fmt.bufPrint(&notify_buf, "{s}/codedb-notify", .{cio.tempDir()}) catch return;
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
