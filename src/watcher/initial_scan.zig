const std = @import("std");
const ContentCache = @import("../hot_cache.zig").ContentCache;
const cio = @import("../cio.zig");
const Store = @import("../store.zig").Store;
const Explorer = @import("../explore.zig").Explorer;
const TrigramIndex = @import("../index.zig").TrigramIndex;
const explore_mod = @import("../explore.zig");
const FilteredWalker = @import("filtered_walker.zig").FilteredWalker;
const skip_rules = @import("skip_rules.zig");

const InitialScanEntry = struct {
    path: []u8,
    skip_trigram: bool,
};

const ParsedScanFile = struct {
    path: []const u8,
    content: []const u8,
    outline: explore_mod.FileOutline,
    skip_trigram: bool,
};

const WorkerParsedResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ParsedScanFile),

    fn init(backing: std.mem.Allocator) WorkerParsedResults {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .items = .empty,
        };
    }

    fn deinit(self: *WorkerParsedResults, backing: std.mem.Allocator) void {
        _ = backing;
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn collectInitialScanEntries(io: std.Io, store: *Store, explorer: *Explorer, dir: std.Io.Dir, allocator: std.mem.Allocator, skip_trigram: bool) !std.ArrayList(InitialScanEntry) {
    var walker = try FilteredWalker.init(io, dir, allocator);
    defer walker.deinit();
    try explorer.setIgnorePatterns(walker.ignore_patterns.items);
    explorer.codedbignore_hash = walker.codedbignore_hash;

    var entries: std.ArrayList(InitialScanEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    const max_trigram_files: usize = 15_000;
    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        _ = try store.recordSnapshot(entry.path, stat.size, 0);
        file_count += 1;
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .skip_trigram = skip_trigram or (file_count > max_trigram_files),
        });
    }
    return entries;
}

fn parseInitialScanEntry(io: std.Io, root: []const u8, entry: InitialScanEntry, arena_alloc: std.mem.Allocator) !?ParsedScanFile {
    if (skip_rules.shouldSkipFile(entry.path)) return null;
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const stat = try dir.statFile(io, entry.path, .{});
    if (stat.size > skip_rules.max_indexed_file_bytes) return null;
    const content = try dir.readFileAlloc(io, entry.path, arena_alloc, .limited(skip_rules.max_indexed_file_bytes));
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return null;
    }
    const effective_skip_trigram = entry.skip_trigram or (content.len > 64 * 1024);
    const parsed = try explore_mod.Explorer.parseContentForIndexing(arena_alloc, entry.path, content);
    return .{
        .path = entry.path,
        .content = parsed.content,
        .outline = parsed.outline,
        .skip_trigram = effective_skip_trigram,
    };
}

fn initialScanWorker(io: std.Io, results: *WorkerParsedResults, root: []const u8, entries: []const InitialScanEntry) void {
    const arena_alloc = results.arena.allocator();
    for (entries) |entry| {
        const parsed = parseInitialScanEntry(io, root, entry, arena_alloc) catch null;
        if (parsed) |file| {
            results.items.append(arena_alloc, file) catch return;
        }
    }
}

pub fn initialScanWithWorkerCount(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool, worker_count: usize) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var entries = try collectInitialScanEntries(io, store, explorer, dir, allocator, skip_trigram);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) return;
    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        for (entries.items) |entry| {
            {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const parsed = try parseInitialScanEntry(io, root, entry, arena.allocator());
                if (parsed) |file| {
                    try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
                }
            }
        }
        return;
    }

    const workers = try allocator.alloc(WorkerParsedResults, n_workers);
    var workers_committed: usize = 0;
    defer {
        for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (workers, 0..) |*worker, i| {
        worker.* = WorkerParsedResults.init(std.heap.page_allocator);
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk });
    }
    for (threads) |thread| thread.join();

    for (workers) |*worker| {
        for (worker.items.items) |file| {
            try explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, file.skip_trigram);
        }
        worker.deinit(allocator);
        workers_committed += 1;
    }
}

fn readFileEntry(io: std.Io, root: []const u8, entry: InitialScanEntry, arena_alloc: std.mem.Allocator) ?struct { path: []const u8, content: []const u8 } {
    if (skip_rules.shouldSkipFile(entry.path)) return null;
    const dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return null;
    defer dir.close(io);
    const stat = dir.statFile(io, entry.path, .{}) catch return null;
    if (stat.size > skip_rules.max_indexed_file_bytes) return null;
    const c = dir.readFileAlloc(io, entry.path, arena_alloc, .limited(skip_rules.max_indexed_file_bytes)) catch return null;
    const check_len = @min(c.len, 512);
    for (c[0..check_len]) |ch| {
        if (ch == 0) return null;
    }
    return .{ .path = entry.path, .content = c };
}

const ReadResult = struct { path: []const u8, content: []const u8 };
const ReadResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(ReadResult),

    fn init(backing: std.mem.Allocator) ReadResults {
        return .{ .arena = std.heap.ArenaAllocator.init(backing), .items = .empty };
    }
    fn deinit(self: *ReadResults, _: std.mem.Allocator) void {
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn readWorker(io: std.Io, results: *ReadResults, root: []const u8, entries: []const InitialScanEntry) void {
    const alloc = results.arena.allocator();
    for (entries) |entry| {
        if (readFileEntry(io, root, entry, alloc)) |r| {
            results.items.append(alloc, r) catch {};
        }
    }
}

const TriExtractEntry = TrigramIndex.BulkEntry;
const TriExtractResult = struct { path: []const u8, trigrams: []TriExtractEntry };
const TriExtractResults = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(TriExtractResult),
    fn init(backing: std.mem.Allocator) TriExtractResults {
        return .{ .arena = std.heap.ArenaAllocator.init(backing), .items = .empty };
    }
    fn deinit(self: *TriExtractResults, _: std.mem.Allocator) void {
        self.items.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

const CachedEntry = struct { path: []const u8, content: []const u8 };

fn cachedTrigramExtractWorker(results: *TriExtractResults, entries: []const CachedEntry) void {
    const alloc = results.arena.allocator();
    const index_m = @import("../index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        if (entry.content.len > 64 * 1024) continue;
        local.clearRetainingCapacity();
        if (entry.content.len >= 3) {
            for (0..entry.content.len - 2) |i| {
                const c0 = entry.content[i];
                const c1 = entry.content[i + 1];
                const c2 = entry.content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = index_m.packTrigram(index_m.normalizeChar(c0), index_m.normalizeChar(c1), index_m.normalizeChar(c2));
                const gop = local.getOrPut(tri) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = index_m.PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < entry.content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(index_m.normalizeChar(entry.content[i + 3]) % 8);
                }
            }
        }
        const tri_entries = alloc.alloc(TriExtractEntry, local.count()) catch continue;
        var ti: usize = 0;
        var iter = local.iterator();
        while (iter.next()) |e| {
            tri_entries[ti] = .{ .tri = e.key_ptr.*, .mask = e.value_ptr.* };
            ti += 1;
        }
        results.items.append(alloc, .{ .path = entry.path, .trigrams = tri_entries }) catch {};
    }
}

pub fn buildTrigramsFromCache(
    contents: *ContentCache,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    worker_count: usize,
) !*TrigramIndex {
    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    tmp_tri.owns_paths = true;
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(contents.count(), 65536))) catch {};

    if (contents.count() == 0) return tmp_tri;

    var entries: std.ArrayList(CachedEntry) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, contents.count());
    var iter = contents.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.*.len > 64 * 1024) continue;
        entries.appendAssumeCapacity(.{ .path = e.key_ptr.*, .content = e.value_ptr.* });
    }
    if (entries.items.len == 0) return tmp_tri;

    const n_workers = @max(@as(usize, 1), @min(worker_count, entries.items.len));
    if (n_workers == 1) {
        var results = TriExtractResults.init(std.heap.page_allocator);
        defer results.deinit(allocator);
        cachedTrigramExtractWorker(&results, entries.items);
        for (results.items.items) |r| tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
        return tmp_tri;
    }

    const extractors = try allocator.alloc(TriExtractResults, n_workers);
    var extractors_done: usize = 0;
    defer {
        for (extractors[extractors_done..]) |*r| r.deinit(allocator);
        allocator.free(extractors);
    }
    const threads = try allocator.alloc(std.Thread, n_workers);
    defer allocator.free(threads);

    const chunk_size = entries.items.len / n_workers;
    const remainder = entries.items.len % n_workers;
    var offset: usize = 0;
    for (extractors, 0..) |*ext, i| {
        ext.* = TriExtractResults.init(std.heap.page_allocator);
        const extra: usize = if (i < remainder) 1 else 0;
        const count = chunk_size + extra;
        const chunk = entries.items[offset .. offset + count];
        offset += count;
        threads[i] = try std.Thread.spawn(.{}, cachedTrigramExtractWorker, .{ ext, chunk });
    }
    for (threads) |t| t.join();

    for (extractors) |*ext| {
        for (ext.items.items) |r| tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
        ext.deinit(allocator);
        extractors_done += 1;
    }
    return tmp_tri;
}

fn trigramExtractWorker(io: std.Io, results: *TriExtractResults, root: []const u8, entries: []const InitialScanEntry) void {
    const alloc = results.arena.allocator();
    const index_m = @import("../index.zig");
    var local = std.AutoHashMap(index_m.Trigram, index_m.PostingMask).init(std.heap.c_allocator);
    defer local.deinit();
    local.ensureTotalCapacity(4096) catch {};
    for (entries) |entry| {
        const r = readFileEntry(io, root, entry, alloc) orelse continue;
        if (r.content.len > 64 * 1024) continue;
        local.clearRetainingCapacity();
        if (r.content.len >= 3) {
            for (0..r.content.len - 2) |i| {
                const c0 = r.content[i];
                const c1 = r.content[i + 1];
                const c2 = r.content[i + 2];
                if ((c0 == ' ' or c0 == '\t' or c0 == '\n' or c0 == '\r') and
                    (c1 == ' ' or c1 == '\t' or c1 == '\n' or c1 == '\r') and
                    (c2 == ' ' or c2 == '\t' or c2 == '\n' or c2 == '\r')) continue;
                const tri = index_m.packTrigram(index_m.normalizeChar(c0), index_m.normalizeChar(c1), index_m.normalizeChar(c2));
                const gop = local.getOrPut(tri) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = index_m.PostingMask{};
                gop.value_ptr.loc_mask |= @as(u8, 1) << @intCast(i % 8);
                if (i + 3 < r.content.len) {
                    gop.value_ptr.next_mask |= @as(u8, 1) << @intCast(index_m.normalizeChar(r.content[i + 3]) % 8);
                }
            }
        }
        const tri_entries = alloc.alloc(TriExtractEntry, local.count()) catch continue;
        var ti: usize = 0;
        var iter = local.iterator();
        while (iter.next()) |e| {
            tri_entries[ti] = .{ .tri = e.key_ptr.*, .mask = e.value_ptr.* };
            ti += 1;
        }
        results.items.append(alloc, .{ .path = r.path, .trigrams = tri_entries }) catch {};
    }
}

pub fn initialScanWithTrigrams(
    io: std.Io,
    store: *Store,
    explorer: *Explorer,
    root: []const u8,
    allocator: std.mem.Allocator,
    trigram_alloc: std.mem.Allocator,
    skip_outlines: bool,
) !?*TrigramIndex {
    const dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var entries = try collectInitialScanEntries(io, store, explorer, dir, allocator, true);
    defer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }
    if (entries.items.len == 0) return null;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const n_workers = @max(@as(usize, 1), @min(@as(usize, @intCast(cpu_count)), @min(entries.items.len, 8)));

    var tmp_tri = try trigram_alloc.create(TrigramIndex);
    tmp_tri.* = TrigramIndex.init(trigram_alloc);
    tmp_tri.owns_paths = true;
    tmp_tri.index.ensureTotalCapacity(131072) catch {};
    tmp_tri.path_to_id.ensureTotalCapacity(@intCast(@min(entries.items.len, 65536))) catch {};

    if (n_workers == 1) {
        for (entries.items) |entry| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const parsed = parseInitialScanEntry(io, root, entry, arena.allocator()) catch null;
            if (parsed) |file| {
                if (!skip_outlines) {
                    explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, true) catch continue;
                }
                if (file.content.len <= 64 * 1024) {
                    tmp_tri.indexFile(file.path, file.content) catch {};
                }
            }
        }
        return tmp_tri;
    }

    if (skip_outlines) {
        const extractors = try allocator.alloc(TriExtractResults, n_workers);
        var extractors_done: usize = 0;
        defer {
            for (extractors[extractors_done..]) |*r| r.deinit(allocator);
            allocator.free(extractors);
        }
        const threads = try allocator.alloc(std.Thread, n_workers);
        defer allocator.free(threads);

        const chunk_size = entries.items.len / n_workers;
        const remainder = entries.items.len % n_workers;
        var offset: usize = 0;
        for (extractors, 0..) |*ext, i| {
            ext.* = TriExtractResults.init(std.heap.page_allocator);
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            threads[i] = try std.Thread.spawn(.{}, trigramExtractWorker, .{ io, ext, root, chunk });
        }
        for (threads) |thread| thread.join();

        for (extractors) |*ext| {
            for (ext.items.items) |r| {
                tmp_tri.insertBulkNew(r.path, r.trigrams) catch {};
            }
            ext.deinit(allocator);
            extractors_done += 1;
        }
    } else {
        const workers = try allocator.alloc(WorkerParsedResults, n_workers);
        var workers_committed: usize = 0;
        defer {
            for (workers[workers_committed..]) |*worker| worker.deinit(allocator);
            allocator.free(workers);
        }
        const threads = try allocator.alloc(std.Thread, n_workers);
        defer allocator.free(threads);

        const chunk_size = entries.items.len / n_workers;
        const remainder = entries.items.len % n_workers;
        var offset: usize = 0;
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerParsedResults.init(std.heap.page_allocator);
            const extra: usize = if (i < remainder) 1 else 0;
            const count = chunk_size + extra;
            const chunk = entries.items[offset .. offset + count];
            offset += count;
            threads[i] = try std.Thread.spawn(.{}, initialScanWorker, .{ io, worker, root, chunk });
        }
        for (threads) |thread| thread.join();

        for (workers) |*worker| {
            for (worker.items.items) |file| {
                explorer.commitParsedFileOwnedOutline(file.path, file.content, file.outline, true, true) catch continue;
                if (file.content.len <= 64 * 1024) {
                    tmp_tri.indexFile(file.path, file.content) catch {};
                }
            }
            worker.deinit(allocator);
            workers_committed += 1;
        }
    }
    return tmp_tri;
}

/// Called from main thread to do the initial scan before listening.
pub fn initialScan(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, skip_trigram: bool) !void {
    const worker_count = blk: {
        if (cio.posixGetenv("CODEDB_SCAN_WORKERS")) |raw| {
            const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
            if (parsed > 0) break :blk parsed;
        }
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk @min(@as(usize, @intCast(cpu_count)), 8);
    };
    try initialScanWithWorkerCount(io, store, explorer, root, allocator, skip_trigram, worker_count);
}

/// Fast index: parse symbols/outline only, skip expensive word+trigram indexes.
pub fn indexFileOutline(io: std.Io, explorer: *Explorer, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) !void {
    if (skip_rules.shouldSkipFile(path)) return;
    const stat = try dir.statFile(io, path, .{});
    if (stat.size > skip_rules.max_indexed_file_bytes) return;
    const content = try dir.readFileAlloc(io, path, allocator, .limited(skip_rules.max_indexed_file_bytes));
    defer allocator.free(content);
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |c| {
        if (c == 0) return;
    }
    try explorer.indexFileOutlineOnly(path, content);
}
