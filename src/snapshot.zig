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
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const Store = @import("store.zig").Store;

const format = @import("snapshot/format.zig");
const writer = @import("snapshot/writer.zig");
const loader_validated = @import("snapshot/loader_validated.zig");
const loader_fast = @import("snapshot/loader_fast.zig");
const sensitive = @import("snapshot/sensitive.zig");

pub const SectionId = format.SectionId;
pub const readSections = format.readSections;
pub const readSectionBytes = format.readSectionBytes;
pub const readSnapshotGitHead = format.readSnapshotGitHead;
pub const readSnapshotCodedbIgnoreHash = format.readSnapshotCodedbIgnoreHash;
pub const writeSnapshot = writer.writeSnapshot;
pub const writeSnapshotDual = writer.writeSnapshotDual;
pub const writeProjectCacheSnapshot = writer.writeProjectCacheSnapshot;
pub const isRootSnapshot = writer.isRootSnapshot;
pub const ensureGitIgnoresSnapshot = writer.ensureGitIgnoresSnapshot;
pub const loadSnapshotValidated = loader_validated.loadSnapshotValidated;
pub const loadSnapshotFast = loader_fast.loadSnapshotFast;
pub const isSensitivePath = sensitive.isSensitivePath;

pub fn loadSnapshot(
    io: std.Io,
    snapshot_path: []const u8,
    abs_root: []const u8,
    explorer: *Explorer,
    store: *Store,
    allocator: std.mem.Allocator,
) bool {
    return loadSnapshotValidated(io, snapshot_path, null, abs_root, explorer, store, allocator);
}
