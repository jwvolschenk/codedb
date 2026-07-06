const std = @import("std");
const cio = @import("../cio.zig");
const Store = @import("../store.zig").Store;
const Explorer = @import("../explore.zig").Explorer;
const TrigramIndex = @import("../index.zig").TrigramIndex;
const MmapTrigramIndex = @import("../index.zig").MmapTrigramIndex;
const WordIndex = @import("../index.zig").WordIndex;
const index_mod = @import("../index.zig");
const snapshot_mod = @import("../snapshot.zig");
const Config = @import("../config.zig").Config;
const root_resolve = @import("../root_resolve.zig");

pub fn loadUserConfig(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) !Config {
    const self_exe: ?[:0]u8 = std.process.executablePathAlloc(io, alloc) catch null;
    defer if (self_exe) |p| alloc.free(p);
    const bin_dir: ?[]const u8 = if (self_exe) |p| blk: {
        const last_slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse break :blk null;
        break :blk p[0..last_slash];
    } else null;

    return try Config.loadDefault(io, alloc, explicit, bin_dir);
}

pub fn loadSnapshotIfHeadMatches(
    io: std.Io,
    snapshot_path: []const u8,
    explorer: *Explorer,
    store: *Store,
    abs_root: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const snap_head = snapshot_mod.readSnapshotGitHead(io, snapshot_path) orelse {
        // No git HEAD in snapshot (non-git project or legacy snapshot) — load
        // only when the current project also has no git HEAD.
        if (current_git_head != null) return false;
        // Still check .codedbignore even for non-git projects
        if (codedbignoreChanged(io, snapshot_path, abs_root, allocator)) return false;
        return snapshot_mod.loadSnapshot(io, snapshot_path, abs_root, explorer, store, allocator);
    };
    const cur_head = current_git_head orelse return false;
    if (!std.mem.eql(u8, &snap_head, &cur_head)) return false;

    // Check if .codedbignore changed since the snapshot was written.
    // If so, force a re-scan so new ignore patterns take effect.
    if (codedbignoreChanged(io, snapshot_path, abs_root, allocator)) return false;

    return snapshot_mod.loadSnapshot(io, snapshot_path, abs_root, explorer, store, allocator);
}

/// Check if the .codedbignore file has changed since the snapshot was written.
/// Returns true if the hashes differ (meaning re-scan is needed).
fn codedbignoreChanged(io: std.Io, snapshot_path: []const u8, abs_root: []const u8, allocator: std.mem.Allocator) bool {
    // Read stored hash from snapshot META
    const stored_hash = snapshot_mod.readSnapshotCodedbIgnoreHash(io, snapshot_path, allocator);

    // Compute current hash from .codedbignore file
    const cbi_path = std.fmt.allocPrint(allocator, "{s}/.codedbignore", .{abs_root}) catch return false;
    defer allocator.free(cbi_path);
    const cbi_content = std.Io.Dir.cwd().readFileAlloc(io, cbi_path, allocator, .limited(64 * 1024)) catch {
        // No .codedbignore file exists now.
        // If snapshot also has none (null or 0), they match → no re-scan needed.
        // If snapshot had one (hash != 0), file was deleted → re-scan needed.
        if (stored_hash) |h| return h != 0;
        return false; // both null → match
    };
    defer allocator.free(cbi_content);
    const current_hash = std.hash.Wyhash.hash(0, cbi_content);

    // If snapshot has no stored hash (legacy), don't force re-scan
    const stored = stored_hash orelse return false;
    return stored != current_hash;
}

pub fn loadBestSnapshot(
    io: std.Io,
    explorer: *Explorer,
    store: *Store,
    abs_root: []const u8,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const root_snapshot = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch null;
    defer if (root_snapshot) |p| allocator.free(p);
    const first_snapshot = root_snapshot orelse "codedb.snapshot";
    if (loadSnapshotIfHeadMatches(io, first_snapshot, explorer, store, abs_root, current_git_head, allocator)) {
        return true;
    }

    const central_snapshot = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{data_dir}) catch return false;
    defer allocator.free(central_snapshot);
    return loadSnapshotIfHeadMatches(io, central_snapshot, explorer, store, abs_root, current_git_head, allocator);
}

pub fn getDataDir(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    // Precondition: abs_root is canonical (absolute, no trailing separator,
    // symlinks resolved). The CLI path satisfies this via shell.resolveRoot;
    // the MCP path must route through root_resolve.canonicalizeRoot. Asserting
    // here catches a future caller that forgets the funnel — the worst symptom
    // (two cache dirs for one project, #591) is silent otherwise.
    std.debug.assert(abs_root.len > 0);
    std.debug.assert(abs_root[0] == '/' or (abs_root.len >= 2 and std.ascii.isAlphabetic(abs_root[0]) and abs_root[1] == ':'));
    std.debug.assert(abs_root.len == 1 or abs_root[abs_root.len - 1] != '/');

    // The ONLY hash of the root string — #591. Case-folded on macOS/Windows so
    // case-insensitive-FS aliasing can't produce divergent cache dirs.
    const hash = root_resolve.cacheKey(abs_root);
    const home_env = cio.getHomeDir() orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{abs_root});
    };
    const home = try allocator.dupe(u8, home_env);
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    // Record the canonical root for human inspection and as a collision
    // detector: if an existing project.txt names a different root, two roots
    // hashed to the same dir (aliasing/collision). Never fatal — just warn.
    saveProjectInfo(io, allocator, dir, abs_root) catch {};
    warnIfProjectTxtDisagrees(io, allocator, dir, abs_root);
    return dir;
}

/// Reads project.txt (if present) and warns when it names a different root than
/// the one currently being indexed into this data dir. A disagreement means two
/// distinct canonical roots hashed to the same cache dir — either a hash
/// collision or, more likely, an aliasing bug we haven't fully closed. Warn-only
/// per #591's "never fatal" policy.
fn warnIfProjectTxtDisagrees(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) void {
    const info_path = std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir}) catch return;
    defer allocator.free(info_path);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, info_path, allocator, .limited(4096)) catch return;
    defer allocator.free(existing);
    if (!std.mem.eql(u8, std.mem.trim(u8, existing, " \n\r\t"), abs_root)) {
        std.log.warn("codedb: cache dir {s} previously held project \"{s}\"; now indexing \"{s}\" (aliasing/collision?)", .{ data_dir, existing, abs_root });
    }
}

pub fn loadTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, data_dir: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const disk_backed = explorer.trigram_index != .heap;
    const heap_files = explorer.trigram_index.fileCount();
    const total_files = explorer.outlines.count();
    explorer.mu.unlockShared();
    // Skip only when a disk index is already adopted or the heap index
    // covers the whole project. A PARTIAL heap (snapshot freshness reindex
    // touches a few changed files before this runs) must not block the
    // load — adoptTrigramBase keeps those files as a masking overlay. (#615)
    if (disk_backed or (heap_files > 0 and heap_files >= total_files)) return;

    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.adoptTrigramBase(loaded);
    } else if (heap_files == 0) {
        if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
            explorer.adoptTrigramIndex(.{ .heap = loaded });
        }
    }
}

pub fn loadWordIndexFromDiskIfPresent(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const header = WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    const heads_match = blk: {
        if (current_git_head == null and header.git_head == null) break :blk true;
        if (current_git_head == null or header.git_head == null) break :blk false;
        break :blk std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
    };
    if (!heads_match) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    if (WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn wordIndexDiskMatches(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const header = WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse return false;

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) return false;

    if (current_git_head == null and header.git_head == null) return true;
    if (current_git_head == null or header.git_head == null) return false;
    return std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
}

pub fn compactMcpReadyMemory(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    explorer.mu.lockShared();
    const file_count = explorer.outlines.count();
    explorer.mu.unlockShared();

    if (file_count <= 1000 and cio.posixGetenv("CODEDB_LOW_MEMORY") == null) return;

    const can_release_contents =
        explorer.wordIndexIsComplete() or
        (explorer.wordIndexCanLoadFromDisk() and wordIndexDiskMatches(io, explorer, data_dir, current_git_head, allocator));

    if (can_release_contents) {
        explorer.releaseContents();
    }
    explorer.releaseSecondaryIndexes();

    // Shrink index allocations to reclaim ArrayList over-allocation.
    if (explorer.trigram_index.asHeap()) |heap| heap.shrinkPostingLists();
    explorer.word_index.shrinkAllocations();
}

pub fn persistWordIndexToDisk(io: std.Io, explorer: *Explorer, data_dir: []const u8, git_head: ?[40]u8) void {
    const generation = explorer.wordIndexGenerationToPersist() orelse return;

    explorer.mu.lockShared();
    explorer.word_index.writeToDisk(io, data_dir, git_head) catch |err| {
        explorer.mu.unlockShared();
        std.log.warn("could not persist word index: {}", .{err});
        return;
    };
    explorer.mu.unlockShared();
    explorer.markWordIndexPersisted(generation);
}

pub fn wordIndexMatchesOutlines(explorer: *Explorer) bool {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    return explorer.word_index_complete and
        explorer.word_index.id_to_path.items.len == explorer.outlines.count();
}

pub fn persistWordIndexFromSource(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    data_dir: []const u8,
    git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        try paths.ensureTotalCapacity(allocator, explorer.outlines.count());
        var path_iter = explorer.outlines.keyIterator();
        while (path_iter.next()) |path_ptr| {
            paths.appendAssumeCapacity(path_ptr.*);
        }
    }

    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root_dir.close(io);

    var word_index = WordIndex.init(allocator);
    defer word_index.deinit();
    word_index.skip_file_words = true;

    for (paths.items) |path| {
        const content = root_dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch continue;
        errdefer allocator.free(content);
        try word_index.indexFile(path, content);
        allocator.free(content);
    }

    if (word_index.id_to_path.items.len == 0 and paths.items.len != 0) return error.NoWordIndexData;
    try word_index.writeToDisk(io, data_dir, git_head);
}

pub fn saveProjectInfo(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) !void {
    const info_path = try std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir});
    defer allocator.free(info_path);
    const file = try std.Io.Dir.cwd().createFile(io, info_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, abs_root);
}
