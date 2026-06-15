const std = @import("std");
const explore_mod = @import("../explore.zig");
const Explorer = explore_mod.Explorer;
const FileOutline = explore_mod.FileOutline;
const Store = @import("../store.zig").Store;
const format = @import("format.zig");
const loader_validated = @import("loader_validated.zig");
const SectionId = format.SectionId;
const readSections = format.readSections;
const loadOutlineStateMap = loader_validated.loadOutlineStateMap;
const deinitOutlineStateMap = loader_validated.deinitOutlineStateMap;
const insertRestoredFile = loader_validated.insertRestoredFile;

pub fn loadSnapshotFast(
    io: std.Io,
    snapshot_path: []const u8,
    expected_file_count: ?u32,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) !bool {
    var outline_states = loadOutlineStateMap(io, snapshot_path, allocator) catch std.StringHashMap(FileOutline).init(allocator);
    defer deinitOutlineStateMap(&outline_states, allocator);

    var sections = (try readSections(io, snapshot_path, allocator)) orelse return false;
    defer sections.deinit();

    const content_entry = sections.get(@intFromEnum(SectionId.content)) orelse return false;
    const content_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return false;
    defer content_file.close(io);

    const file_stat = content_file.stat(io) catch return false;
    if (content_entry.offset + content_entry.length > file_stat.size) return false;

    var read_pos: u64 = content_entry.offset;
    const snap_mtime: i128 = @intCast(file_stat.mtime.nanoseconds);
    var bytes_read: u64 = 0;
    var file_count: u32 = 0;
    var word_index_can_load_from_disk = true;
    while (bytes_read < content_entry.length) {
        var pl_buf: [2]u8 = undefined;
        const pln = content_file.readPositionalAll(io, &pl_buf, read_pos) catch return false;
        if (pln != 2) break;
        read_pos += 2;
        const path_len = std.mem.readInt(u16, &pl_buf, .little);
        if (path_len == 0 or path_len > 4096) break;
        bytes_read += 2;

        const path_buf = allocator.alloc(u8, path_len) catch return false;
        const prn = content_file.readPositionalAll(io, path_buf, read_pos) catch return false;
        if (prn != path_len) {
            allocator.free(path_buf);
            break;
        }
        read_pos += path_len;
        bytes_read += path_len;

        var cl_buf: [4]u8 = undefined;
        const cln = content_file.readPositionalAll(io, &cl_buf, read_pos) catch return false;
        if (cln != 4) {
            allocator.free(path_buf);
            break;
        }
        read_pos += 4;
        const content_len = std.mem.readInt(u32, &cl_buf, .little);
        if (content_len > 64 * 1024 * 1024) {
            allocator.free(path_buf);
            break;
        }
        bytes_read += 4;

        const content = allocator.alloc(u8, content_len) catch return false;
        const crn = content_file.readPositionalAll(io, content, read_pos) catch return false;
        if (crn != content_len) {
            allocator.free(path_buf);
            allocator.free(content);
            break;
        }
        read_pos += content_len;
        bytes_read += content_len;

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

        if (disk_content) |dc| {
            word_index_can_load_from_disk = false;
            if (outline_states.fetchRemove(path_buf)) |removed| {
                allocator.free(removed.key);
                var stale_outline = removed.value;
                stale_outline.deinit();
            }

            explorer.indexFileOutlineOnly(path_buf, dc) catch {
                allocator.free(path_buf);
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, dc);
            _ = store.recordSnapshot(path_buf, dc.len, hash) catch {};
            allocator.free(path_buf);
            allocator.free(content);
        } else if (outline_states.fetchRemove(path_buf)) |removed| {
            allocator.free(path_buf);
            insertRestoredFile(explorer, removed.key, content, removed.value, allocator) catch {
                allocator.free(removed.key);
                var bad_outline = removed.value;
                bad_outline.deinit();
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(removed.key, content.len, hash) catch {};
            allocator.free(content);
        } else {
            word_index_can_load_from_disk = false;
            explorer.indexFileOutlineOnly(path_buf, content) catch {
                allocator.free(path_buf);
                allocator.free(content);
                continue;
            };
            const hash = std.hash.Wyhash.hash(0, content);
            _ = store.recordSnapshot(path_buf, content.len, hash) catch {};
            allocator.free(path_buf);
            allocator.free(content);
        }

        file_count += 1;
    }

    if (file_count == 0) return false;
    if (expected_file_count) |expected| {
        if (file_count != expected) return false;
    }

    if (outline_states.count() != 0) return false;

    explorer.markWordIndexIncomplete(word_index_can_load_from_disk);

    if (sections.get(@intFromEnum(SectionId.freq_table))) |freq_entry| {
        if (freq_entry.length == 256 * 256 * 2) {
            const index_mod = @import("../index.zig");
            const ft = allocator.create([256][256]u16) catch return file_count > 0;
            const freq_file = std.Io.Dir.cwd().openFile(io, snapshot_path, .{}) catch return file_count > 0;
            defer freq_file.close(io);
            var fp: u64 = freq_entry.offset;
            var row_buf: [256 * 2]u8 = undefined;
            for (0..256) |a| {
                const nr = freq_file.readPositionalAll(io, &row_buf, fp) catch {
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
