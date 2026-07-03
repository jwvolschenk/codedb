const std = @import("std");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const FileOutline = explore_mod.FileOutline;
const Symbol = explore_mod.Symbol;
const SymbolKind = explore_mod.SymbolKind;
const Language = explore_mod.Language;
const Store = @import("../store.zig").Store;
const format = @import("format.zig");
const loader_fast = @import("loader_fast.zig");
const SectionId = format.SectionId;
const readSectionBytes = format.readSectionBytes;
const readSectionsFromFile = format.readSectionsFromFile;
const parseJsonU32 = format.parseJsonU32;
const parseJsonU64 = format.parseJsonU64;
const cleanupStaleTmpFiles = format.cleanupStaleTmpFiles;
const readSectionInt = format.readSectionInt;
const readSectionByte = format.readSectionByte;
const readSectionString = format.readSectionString;

pub fn loadSnapshotValidated(
    io: std.Io,
    snapshot_path: []const u8,
    expected_root: ?[]const u8,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) bool {
    // Clean up stale temp files from previous crashed writers
    cleanupStaleTmpFiles(io, snapshot_path);

    const file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return false;
    defer file.close(io);

    // Read section table (validates magic internally) — reuse already-open file (#253)
    var sections = (readSectionsFromFile(io, file, allocator) catch return false) orelse return false;
    defer sections.deinit();

    // Parse META section to get expected file_count and root_hash
    var expected_file_count: ?u32 = null;
    var meta_root_hash: ?u64 = null;
    if (sections.get(@intFromEnum(SectionId.meta))) |meta_entry| {
        if (meta_entry.length <= 256 * 1024 * 1024) blk: {
            const mb = allocator.alloc(u8, @intCast(meta_entry.length)) catch break :blk;
            defer allocator.free(mb);
            const nr = file.readPositionalAll(io, mb, meta_entry.offset) catch break :blk;
            if (nr != mb.len) break :blk;
            if (parseJsonU32(mb, "file_count")) |fc| {
                expected_file_count = fc;
            }
            if (parseJsonU64(mb, "root_hash")) |rh| {
                meta_root_hash = rh;
            }
            if (parseJsonU64(mb, "codedbignore_hash")) |cbi| {
                explorer.codedbignore_hash = cbi;
            }
        }
    }

    // Validate repo identity if requested (issue-41)
    if (expected_root) |root| {
        const expected_hash = std.hash.Wyhash.hash(0, root);
        if (meta_root_hash) |stored_hash| {
            if (stored_hash != expected_hash) return false;
        } else {
            // No root_hash in snapshot — reject if caller requires validation
            return false;
        }
    }

    if (sections.get(@intFromEnum(SectionId.outline_state)) != null) {
        return loader_fast.loadSnapshotFast(io, snapshot_path, expected_file_count, explorer, store, allocator) catch false;
    }

    // Load CONTENT section — this is the core data
    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;

    // Validate content section fits within actual file size (issue-40: truncation detection)
    const file_stat = file.stat(io) catch return false;
    const file_size = file_stat.size;
    if (content_entry.offset + content_entry.length > file_size) return false;

    var read_pos: u64 = content_entry.offset;
    const snap_mtime: i128 = @intCast(file_stat.mtime.nanoseconds);
    var bytes_read: u64 = 0;
    var file_count: u32 = 0;
    while (bytes_read < content_entry.length) {
        // Read path_len(u16)
        var pl_buf: [2]u8 = undefined;
        const pln = file.readPositionalAll(io, &pl_buf, read_pos) catch return false;
        if (pln != 2) break;
        read_pos += 2;
        const path_len = std.mem.readInt(u16, &pl_buf, .little);
        if (path_len == 0 or path_len > 4096) break; // sanity cap
        bytes_read += 2;

        // Read path
        const path_buf = allocator.alloc(u8, path_len) catch return false;
        defer allocator.free(path_buf);
        const prn = file.readPositionalAll(io, path_buf, read_pos) catch return false;
        if (prn != path_len) break;
        read_pos += path_len;
        bytes_read += path_len;

        // Read content_len(u32)
        var cl_buf: [4]u8 = undefined;
        const cln = file.readPositionalAll(io, &cl_buf, read_pos) catch return false;
        if (cln != 4) break;
        read_pos += 4;
        const content_len = std.mem.readInt(u32, &cl_buf, .little);
        if (content_len > 64 * 1024 * 1024) break; // sanity cap: 64MB per file
        bytes_read += 4;

        // Read content
        const content = allocator.alloc(u8, content_len) catch return false;
        defer allocator.free(content);
        const crn = file.readPositionalAll(io, content, read_pos) catch return false;
        if (crn != content_len) break;
        read_pos += content_len;
        bytes_read += content_len;

        // Re-index from disk if file was modified after the snapshot
        var disk_content: ?[]u8 = null;
        if (snap_mtime > 0) blk: {
            const df = std.Io.Dir.cwd().openFile(io, path_buf, .{}) catch break :blk;
            defer df.close(io);
            const ds = df.stat(io) catch break :blk;
            const ds_mtime: i128 = @intCast(ds.mtime.nanoseconds);
            if (ds_mtime <= snap_mtime) break :blk;
            disk_content = std.Io.Dir.cwd().readFileAlloc(io, path_buf, allocator, .limited(16 * 1024 * 1024)) catch break :blk;
        }
        defer if (disk_content) |dc| allocator.free(dc);
        const effective = if (disk_content) |dc| dc else content;

        // Index into explorer (this dupes path and content internally)
        explorer.indexFile(path_buf, effective) catch continue;

        // Record in store for sequence tracking
        const hash = std.hash.Wyhash.hash(0, effective);
        _ = store.recordSnapshot(path_buf, effective.len, hash) catch {};

        file_count += 1;
    }

    // Validate file_count matches META expectation (issue-40)
    if (file_count == 0) return false;
    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    }

    // Load frequency table if present
    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("../index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            var fp: u64 = freq_entry.offset;
            var row_buf: [256 * 2]u8 = undefined;
            for (0..256) |a| {
                const nr = file.readPositionalAll(io, &row_buf, fp) catch {
                    allocator.destroy(ft);
                    return file_count > 0;
                };
                if (nr != 512) {
                    allocator.destroy(ft);
                    return file_count > 0;
                }
                fp += 512;
                for (0..256) |b| {
                    ft[a][b] = std.mem.readInt(u16, row_buf[b * 2 ..][0..2], .little);
                }
            }
            index_mod.setFrequencyTable(ft);
            allocator.destroy(ft);
        }
    }

    return true;
}

pub fn deinitOutlineStateMap(map: *std.StringHashMap(FileOutline), allocator: std.mem.Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    map.deinit();
}

pub fn loadOutlineStateMap(io: std.Io, snapshot_path: []const u8, allocator: std.mem.Allocator) !std.StringHashMap(FileOutline) {
    const bytes = (try readSectionBytes(io, snapshot_path, .outline_state, allocator)) orelse return error.InvalidData;
    defer allocator.free(bytes);

    var result = std.StringHashMap(FileOutline).init(allocator);
    errdefer deinitOutlineStateMap(&result, allocator);

    var cursor: usize = 0;
    const file_count = try readSectionInt(u32, bytes, &cursor);
    for (0..file_count) |_| {
        const path = try readSectionString(bytes, &cursor, allocator, 4096);
        if (path.len == 0) return error.InvalidData;
        errdefer allocator.free(path);

        var outline = FileOutline.init(allocator, path);
        errdefer outline.deinit();

        const language_raw = try readSectionByte(bytes, &cursor);
        outline.language = std.enums.fromInt(Language, language_raw) orelse return error.InvalidData;
        outline.line_count = try readSectionInt(u32, bytes, &cursor);
        outline.byte_size = try readSectionInt(u64, bytes, &cursor);

        const import_count = try readSectionInt(u32, bytes, &cursor);
        for (0..import_count) |_| {
            // The writer caps import strings at maxInt(u16) (see writer.zig), so the
            // read cap must match — a 4096 cap silently disabled the borrow-path
            // fast-restore for any import between 4096 and 65535 bytes (#7d0a083).
            const imp = try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16));
            errdefer allocator.free(imp);
            try outline.imports.append(allocator, imp);
        }

        const symbol_count = try readSectionInt(u32, bytes, &cursor);
        for (0..symbol_count) |_| {
            const name = try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16));
            if (name.len == 0) return error.InvalidData;
            errdefer allocator.free(name);

            const kind_raw = try readSectionByte(bytes, &cursor);
            const kind = std.enums.fromInt(SymbolKind, kind_raw) orelse return error.InvalidData;
            const line_start = try readSectionInt(u32, bytes, &cursor);
            const line_end = try readSectionInt(u32, bytes, &cursor);
            const has_detail = try readSectionByte(bytes, &cursor);
            const detail = switch (has_detail) {
                0 => null,
                1 => try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16)),
                else => return error.InvalidData,
            };
            errdefer if (detail) |d| allocator.free(d);

            // v3: return_type
            const has_return_type = try readSectionByte(bytes, &cursor);
            const return_type = switch (has_return_type) {
                0 => null,
                1 => try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16)),
                else => return error.InvalidData,
            };
            errdefer if (return_type) |rt| allocator.free(rt);

            // v3: param_types
            const param_types_count = try readSectionInt(u32, bytes, &cursor);
            const param_types = try allocator.alloc([]const u8, param_types_count);
            errdefer allocator.free(param_types);
            for (0..param_types_count) |pi| {
                param_types[pi] = try readSectionString(bytes, &cursor, allocator, std.math.maxInt(u16));
                errdefer for (param_types[0..pi]) |pt| allocator.free(pt);
            }

            try outline.symbols.append(allocator, Symbol{
                .name = name,
                .kind = kind,
                .line_start = line_start,
                .line_end = line_end,
                .detail = detail,
                .return_type = return_type,
                .param_types = param_types,
            });
        }

        try result.put(path, outline);
    }

    if (cursor != bytes.len) return error.InvalidData;
    return result;
}

pub fn rebuildDepsFromOutline(explorer: *Explorer, path: []const u8, outline: *const FileOutline, allocator: std.mem.Allocator) !void {
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer deps.deinit(allocator);

    for (outline.imports.items) |imp| {
        if (std.mem.indexOf(u8, imp, "..") != null) continue;
        try deps.append(allocator, imp);
    }

    try explorer.dep_graph.setDeps(path, deps);
}

pub fn insertRestoredFile(
    explorer: *Explorer,
    path: []const u8,
    content: []const u8,
    outline: FileOutline,
    allocator: std.mem.Allocator,
) !void {
    var restored_outline = outline;
    restored_outline.path = path;

    const outline_gop = try explorer.outlines.getOrPut(path);
    if (outline_gop.found_existing) return error.InvalidData;
    outline_gop.key_ptr.* = path;
    outline_gop.value_ptr.* = restored_outline;

    try explorer.contents.put(path, content);

    try rebuildDepsFromOutline(explorer, path, &restored_outline, allocator);
}
