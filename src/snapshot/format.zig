// snapshot.zig — Portable `.codedb` artifact writer/reader
//
// Produces a single binary file containing the full indexed state of a repo.
// Any agent can read this file to understand the codebase without re-indexing.
//
// Format (all integers little-endian):
//   Header (52 bytes):
//     magic:         "CDB\x01"  (4 bytes)
//     version:       u16
//     flags:         u16         (reserved)
//     git_head:      [40]u8      (hex SHA or zeroes)
//     section_count: u32
//   Section Table (section_count × 20 bytes):
//     id:     u32    (section type)
//     offset: u64    (byte offset from file start)
//     length: u64    (byte length)
//   Sections:
//     TREE    (1): JSON array of {path, language, line_count, byte_size, symbol_count}
//     OUTLINE (2): legacy JSON object mapping path → [{name, kind, line, detail}]
//     CONTENT (3): for each file: path_len(u16) + path + content_len(u32) + content
//     FREQ    (5): 256×256×u16 LE frequency table
//     META    (6): JSON {file_count, total_bytes, indexed_at, format_version, codedbignore_hash}
//     OUTLINE_STATE (7): binary per-file outline/import metadata for fast warm restore

const std = @import("std");
const cio = @import("../cio.zig");
const path_safety = @import("../path_safety.zig");

pub const MAGIC = [4]u8{ 'C', 'D', 'B', 0x01 };
pub const FORMAT_VERSION: u16 = 4;
/// Semantic version of indexed outline/search data. Increment this whenever a
/// parser or indexing rule changes in a way that requires unchanged source
/// files to be parsed again. Unlike FORMAT_VERSION, this does not describe the
/// binary container layout.
/// v3: OUTLINE_STATE now persists symbol decorators — older snapshots restored
/// outlines without them, so they must be rescanned, not warm-loaded.
pub const INDEX_VERSION: u32 = 3;

pub const SectionId = enum(u32) {
    tree = 1,
    outline = 2,
    content = 3,
    freq_table = 5,
    meta = 6,
    outline_state = 7,
};

pub const SectionEntry = struct {
    id: u32,
    offset: u64,
    length: u64,
};

/// Write a portable `.codedb` snapshot file.
pub fn readSectionsFromFile(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator) !?std.AutoHashMap(u32, SectionEntry) {
    var magic_buf: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic_buf, 0) catch return null;
    if (n != 4 or !std.mem.eql(u8, &magic_buf, &MAGIC)) return null;

    // offset 4 + 44 = 48: skip version + flags + git_head
    var sc_buf: [4]u8 = undefined;
    const scn = file.readPositionalAll(io, &sc_buf, 48) catch return null;
    if (scn != 4) return null;
    const section_count = std.mem.readInt(u32, &sc_buf, .little);

    var result = std.AutoHashMap(u32, SectionEntry).init(allocator);
    errdefer result.deinit();

    var pos: u64 = 52;
    for (0..section_count) |_| {
        var entry_buf: [20]u8 = undefined;
        const en = file.readPositionalAll(io, &entry_buf, pos) catch return null;
        if (en != 20) return null;
        pos += 20;
        try result.put(
            std.mem.readInt(u32, entry_buf[0..4], .little),
            .{
                .id = std.mem.readInt(u32, entry_buf[0..4], .little),
                .offset = std.mem.readInt(u64, entry_buf[4..12], .little),
                .length = std.mem.readInt(u64, entry_buf[12..20], .little),
            },
        );
    }
    return result;
}

pub fn readSections(io: std.Io, path: []const u8, allocator: std.mem.Allocator) !?std.AutoHashMap(u32, SectionEntry) {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    return readSectionsFromFile(io, file, allocator);
}

/// Read a section's raw bytes from a `.codedb` file.
pub fn readSectionBytes(io: std.Io, path: []const u8, section_id: SectionId, allocator: std.mem.Allocator) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var sections = try readSectionsFromFile(io, file, allocator) orelse return null;
    defer sections.deinit();

    const entry = sections.get(@intFromEnum(section_id)) orelse return null;
    if (entry.length > 256 * 1024 * 1024) return null; // sanity cap: 256MB

    // Validate section fits within file
    const file_size = file.length(io) catch return null;
    if (entry.offset + entry.length > file_size) return null;

    const buf = try allocator.alloc(u8, @intCast(entry.length));
    errdefer allocator.free(buf);
    const nr = try file.readPositionalAll(io, buf, entry.offset);
    if (nr != buf.len) {
        allocator.free(buf);
        return null;
    }
    return buf;
}

/// Read the git HEAD stored in a snapshot file header. Returns null if
/// the file doesn't exist, is invalid, or has an all-zero HEAD.
pub fn readSnapshotGitHead(io: std.Io, path: []const u8) ?[40]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var magic_buf: [4]u8 = undefined;
    const mn = file.readPositionalAll(io, &magic_buf, 0) catch return null;
    if (mn != 4) return null;
    if (!std.mem.eql(u8, &magic_buf, &MAGIC)) return null;

    // offset 4 + 4 = 8: skip version + flags
    var head_buf: [40]u8 = undefined;
    const hn = file.readPositionalAll(io, &head_buf, 8) catch return null;
    if (hn != 40) return null;

    // Return null for all-zero sentinel (no git HEAD available)
    if (std.mem.allEqual(u8, &head_buf, 0x00)) return null;
    // Also handle legacy 0xFF sentinel from older versions
    if (std.mem.allEqual(u8, &head_buf, 0xFF)) return null;

    return head_buf;
}

/// Read the codedbignore hash stored in a snapshot's META section.
/// Returns null if the file doesn't exist, has no META section,
/// or has no codedbignore_hash field (legacy snapshots).
/// Returns 0 if the snapshot was created without a .codedbignore file.
pub fn readSnapshotCodedbIgnoreHash(io: std.Io, path: []const u8, allocator: std.mem.Allocator) ?u64 {
    const sections = readSections(io, path, allocator) catch return null;
    var sections_mut = sections orelse return null;
    defer sections_mut.deinit();

    const meta_entry = sections_mut.get(@intFromEnum(SectionId.meta)) orelse return null;
    if (meta_entry.length > 256 * 1024 * 1024) return null;

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const mb = allocator.alloc(u8, @intCast(meta_entry.length)) catch return null;
    defer allocator.free(mb);
    const nr = file.readPositionalAll(io, mb, meta_entry.offset) catch return null;
    if (nr != mb.len) return null;

    return parseJsonU64(mb, "codedbignore_hash");
}

/// Read the semantic index version stored in META. Missing means the snapshot
/// predates parser-aware cache invalidation and must be rebuilt.
pub fn readSnapshotIndexVersion(io: std.Io, path: []const u8, allocator: std.mem.Allocator) ?u32 {
    const meta = readSectionBytes(io, path, .meta, allocator) catch return null;
    const mb = meta orelse return null;
    defer allocator.free(mb);
    return parseJsonU32(mb, "index_version");
}

/// Read the `dirty_paths` array from a snapshot's META section — the list of
/// working-tree paths that were dirty when the snapshot was written (see
/// watcher/reconcile.zig for why a warm start needs it). Returns null when the
/// file/META is unreadable or the key is absent (legacy snapshots, clean
/// trees) — callers treat null as "no recorded dirty paths". Free the result
/// with git.freePathList.
pub fn readSnapshotDirtyPaths(io: std.Io, path: []const u8, allocator: std.mem.Allocator) ?[][]u8 {
    const meta = readSectionBytes(io, path, .meta, allocator) catch return null;
    const mb = meta orelse return null;
    defer allocator.free(mb);
    return parseJsonStringArray(mb, "dirty_paths", allocator);
}

/// Minimal JSON string-array extractor for META's key-lookup parsing style
/// (same family as parseJsonU64). Handles the escape set json_utils emits:
/// \" \\ \n \r \t and \u00XX. Returns null when the key is absent or the
/// array is malformed.
pub fn parseJsonStringArray(json: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[][]u8 {
    // Locate `"key"` then the following `[`.
    var i: usize = 0;
    const arr_start: usize = blk: {
        while (i + key.len + 2 <= json.len) : (i += 1) {
            if (json[i] == '"' and
                std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
                json[i + 1 + key.len] == '"')
            {
                var j = i + 2 + key.len;
                while (j < json.len and (json[j] == ':' or json[j] == ' ')) j += 1;
                if (j < json.len and json[j] == '[') break :blk j + 1;
                return null;
            }
        }
        return null;
    };

    var out: std.ArrayList([]u8) = .empty;

    var j = arr_start;
    while (j < json.len and json[j] != ']') {
        if (json[j] == ',' or json[j] == ' ') {
            j += 1;
            continue;
        }
        if (json[j] != '"') return freeAndNull(&out, allocator);
        j += 1;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        while (j < json.len and json[j] != '"') {
            if (json[j] == '\\') {
                if (j + 1 >= json.len) return freeAndNull(&out, allocator);
                const esc = json[j + 1];
                switch (esc) {
                    '"', '\\', '/' => buf.append(allocator, esc) catch return freeAndNull(&out, allocator),
                    'n' => buf.append(allocator, '\n') catch return freeAndNull(&out, allocator),
                    'r' => buf.append(allocator, '\r') catch return freeAndNull(&out, allocator),
                    't' => buf.append(allocator, '\t') catch return freeAndNull(&out, allocator),
                    'u' => {
                        if (j + 5 >= json.len) return freeAndNull(&out, allocator);
                        const cp = std.fmt.parseInt(u16, json[j + 2 .. j + 6], 16) catch return freeAndNull(&out, allocator);
                        if (cp > 0xFF) return freeAndNull(&out, allocator); // writer only emits \u00XX
                        buf.append(allocator, @intCast(cp)) catch return freeAndNull(&out, allocator);
                        j += 4;
                    },
                    else => return freeAndNull(&out, allocator),
                }
                j += 2;
            } else {
                buf.append(allocator, json[j]) catch return freeAndNull(&out, allocator);
                j += 1;
            }
        }
        if (j >= json.len) return freeAndNull(&out, allocator); // unterminated string
        j += 1; // closing quote
        const duped = allocator.dupe(u8, buf.items) catch return freeAndNull(&out, allocator);
        out.append(allocator, duped) catch {
            allocator.free(duped);
            return freeAndNull(&out, allocator);
        };
    }
    if (j >= json.len) return freeAndNull(&out, allocator); // no closing ]

    return out.toOwnedSlice(allocator) catch return freeAndNull(&out, allocator);
}

fn freeAndNull(out: *std.ArrayList([]u8), allocator: std.mem.Allocator) ?[][]u8 {
    for (out.items) |p| allocator.free(p);
    out.deinit(allocator);
    out.* = .empty;
    return null;
}

/// Load a snapshot into an Explorer. Populates contents, outlines, and
/// rebuilds trigram + sparse n-gram indexes from the loaded content.
/// Returns true on success, false if the snapshot couldn't be loaded.
pub fn readSectionInt(comptime T: type, buf: []const u8, cursor: *usize) !T {
    const size = @sizeOf(T);
    if (cursor.* + size > buf.len) return error.InvalidData;
    const value = std.mem.readInt(T, buf[cursor.*..][0..size], .little);
    cursor.* += size;
    return value;
}

pub fn readSectionByte(buf: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= buf.len) return error.InvalidData;
    const value = buf[cursor.*];
    cursor.* += 1;
    return value;
}

pub fn readSectionString(buf: []const u8, cursor: *usize, allocator: std.mem.Allocator, max_len: usize) ![]u8 {
    const len = try readSectionInt(u16, buf, cursor);
    if (len > max_len) return error.InvalidData;
    if (cursor.* + len > buf.len) return error.InvalidData;
    const out = try allocator.dupe(u8, buf[cursor.* .. cursor.* + len]);
    cursor.* += len;
    return out;
}

pub fn parseJsonU32(json: []const u8, key: []const u8) ?u32 {
    const val = parseJsonU64(json, key) orelse return null;
    return if (val <= std.math.maxInt(u32)) @intCast(val) else null;
}

pub fn parseJsonU64(json: []const u8, key: []const u8) ?u64 {
    var i: usize = 0;
    while (i + key.len + 2 <= json.len) : (i += 1) {
        if (json[i] == '"' and
            i + 1 + key.len + 1 <= json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 2 + key.len;
            while (j < json.len and (json[j] == ':' or json[j] == ' ')) j += 1;
            const start = j;
            while (j < json.len and json[j] >= '0' and json[j] <= '9') j += 1;
            if (j > start) {
                return std.fmt.parseInt(u64, json[start..j], 10) catch null;
            }
        }
    }
    return null;
}

// Sensitive-path filter lives in path_safety.zig so the watcher, snapshot
// writer, and HTTP/MCP servers all share one reviewable implementation.

fn endsWith(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    return std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

pub fn cleanupStaleTmpFiles(io: std.Io, output_path: []const u8) void {
    // Derive parent directory and basename from output_path
    const sep = std.mem.lastIndexOfScalar(u8, output_path, '/');
    const dir_path = if (sep) |s| output_path[0..s] else ".";
    const basename = if (sep) |s| output_path[s + 1 ..] else output_path;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const now_ns: i128 = cio.nanoTimestamp();
    const min_age_ns: i128 = @as(i128, std.time.s_per_min) * std.time.ns_per_s;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        // Match: starts with basename, ends with .tmp
        if (name.len > basename.len and
            std.mem.startsWith(u8, name, basename) and
            endsWith(name, ".tmp"))
        {
            // Age guard: skip in-flight tmps from concurrent writers.
            // Only delete leftovers crashed processes left behind (>60s old).
            const st = dir.statFile(io, name, .{}) catch continue;
            const m_ns: i128 = @intCast(st.mtime.nanoseconds);
            if (now_ns - m_ns < min_age_ns) continue;
            dir.deleteFile(io, name) catch {};
        }
    }
}
