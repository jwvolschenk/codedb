const std = @import("std");
const cio = @import("../cio.zig");
const testing = std.testing;
const io = std.testing.io;

const Store = @import("../store.zig").Store;
const ChangeEntry = @import("../store.zig").ChangeEntry;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const Explorer = @import("../explore.zig").Explorer;
const csharp_parser = @import("../csharp_parser.zig");
const tsql_parser = @import("../tsql_parser.zig");
const ssrs_parser = @import("../ssrs_parser.zig");
const SearchResult = @import("../explore.zig").SearchResult;
const WordIndex = @import("../index.zig").WordIndex;
const TrigramIndex = @import("../index.zig").TrigramIndex;
const SparseNgramIndex = @import("../index.zig").SparseNgramIndex;
const pairWeight = @import("../index.zig").pairWeight;
const extractSparseNgrams = @import("../index.zig").extractSparseNgrams;
const buildCoveringSet = @import("../index.zig").buildCoveringSet;
const setFrequencyTable = @import("../index.zig").setFrequencyTable;
const resetFrequencyTable = @import("../index.zig").resetFrequencyTable;
const buildFrequencyTable = @import("../index.zig").buildFrequencyTable;
const writeFrequencyTable = @import("../index.zig").writeFrequencyTable;
const readFrequencyTable = @import("../index.zig").readFrequencyTable;

const WordTokenizer = @import("../index.zig").WordTokenizer;
const splitIdentifier = @import("../index.zig").splitIdentifier;

const version = @import("../version.zig");
const watcher = @import("../watcher.zig");
const edit_mod = @import("../edit.zig");
const snapshot_json = @import("../snapshot_json.zig");
const explore = @import("../explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("../mcp.zig");
const main_mod = @import("../main.zig");
const nuke_mod = @import("../nuke.zig");
const update_mod = @import("../update.zig");
const Config = @import("../config.zig").Config;
// Pull in unit tests that were extracted from implementation files into
// dedicated `*__tests.zig` companions. Zig collects test blocks through
// @import, so referencing them here makes the test runner discover them.
comptime {
    _ = @import("../config_tests.zig");
    _ = @import("../hot_cache_tests.zig");
    _ = @import("../root_policy_tests.zig");
    _ = @import("../tsql_parser_tests.zig");
}
const snapshot_mod = @import("../snapshot.zig");
const telemetry_mod = @import("../telemetry.zig");
const release_info = @import("../release_info.zig");
// ── Store tests ─────────────────────────────────────────────

const decomposeRegex = @import("../index.zig").decomposeRegex;

const RegexQuery = @import("../index.zig").RegexQuery;

const packTrigram = @import("../index.zig").packTrigram;

const git_mod = @import("../git.zig");

const regexMatch = explore.regexMatch;

const PostingMask = @import("../index.zig").PostingMask;

const normalizeChar = @import("../index.zig").normalizeChar;

const Trigram = @import("../index.zig").Trigram;

fn buildCliForHelpTests() !void {
    const build = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}

const MmapTrigramIndex = @import("../index.zig").MmapTrigramIndex;

const AnyTrigramIndex = @import("../index.zig").AnyTrigramIndex;

const fuzzyScore = @import("../explore.zig").fuzzyScore;

fn expectOutlineSymbol(outline: *const explore.FileOutline, name: []const u8, kind: SymbolKind) !void {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name) and sym.kind == kind) return;
    }
    return error.TestUnexpectedResult;
}

fn expectOutlineImport(outline: *const explore.FileOutline, import_path: []const u8) !void {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, import_path)) return;
    }
    return error.TestUnexpectedResult;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "disk index: round-trip write and read preserves candidates" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("src/main.zig", "pub fn main() void { const store = Store.init(allocator); }");
    try ti.indexFile("src/index.zig", "pub fn indexFile(self: *TrigramIndex, path: []const u8) !void {}");
    try ti.indexFile("src/watcher.zig", "pub fn initialScan(store: *Store) !void {}");

    // Verify candidates before write
    const cands_before = ti.candidates("indexFile", testing.allocator);
    defer if (cands_before) |c| alloc.free(c);
    try testing.expect(cands_before != null);
    try testing.expect(cands_before.?.len >= 1);

    // Write to temp dir
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    // Read back
    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    // Same candidates should be returned
    const cands_after = loaded_ti.candidates("indexFile", testing.allocator);
    defer if (cands_after) |c| alloc.free(c);
    try testing.expect(cands_after != null);
    try testing.expectEqual(cands_before.?.len, cands_after.?.len);

    // Verify specific file is present
    var found = false;
    for (cands_after.?) |p| {
        if (std.mem.eql(u8, p, "src/index.zig")) found = true;
    }
    try testing.expect(found);
}

test "disk index: readFromDisk returns null for missing files" {
    const loaded = TrigramIndex.readFromDisk(io, "/tmp/codedb_nonexistent_dir_12345", testing.allocator);
    try testing.expect(loaded == null);
}

test "disk index: readFromDisk returns null for corrupt magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Write garbage postings file
    const postings_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.postings", .{dir_path});
    defer testing.allocator.free(postings_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, postings_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "BAADMAGIC");
    }
    // Write garbage lookup file
    const lookup_path = try std.fmt.allocPrint(testing.allocator, "{s}/trigram.lookup", .{dir_path});
    defer testing.allocator.free(lookup_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, lookup_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "BAADMAGIC");
    }

    const loaded = TrigramIndex.readFromDisk(io, dir_path, testing.allocator);
    try testing.expect(loaded == null);
}

test "disk index: empty index round-trips correctly" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    try testing.expectEqual(@as(u32, 0), loaded_ti.fileCount());
}

test "disk index: fileCount matches after round-trip" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("a.zig", "fn alpha() void {}");
    try ti.indexFile("b.zig", "fn beta() void {}");
    try ti.indexFile("c.zig", "fn gamma() void {}");

    try testing.expectEqual(@as(u32, 3), ti.fileCount());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();

    try testing.expectEqual(@as(u32, 3), loaded_ti.fileCount());
}

// ── Git HEAD + disk index tests ─────────────────────────────

test "disk index: writeToDisk with null git_head, readGitHead returns null" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try ti.writeToDisk(io, dir_path, null);

    const retrieved = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(retrieved == null);
}

test "disk index: v1 format (no git_head) still loads and readGitHead returns null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Manually write a v1 postings file (no git head bytes)
    const postings_path = try std.fmt.allocPrint(alloc, "{s}/trigram.postings", .{dir_path});
    defer alloc.free(postings_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, postings_path, .{});
        defer f.close(io);
        // magic(4) + version=1(2) + file_count=0(2) = 8 bytes total
        try f.writeStreamingAll(io, &.{ 'C', 'D', 'B', 'T' });
        try f.writeStreamingAll(io, &.{ 1, 0 }); // version = 1 LE
        try f.writeStreamingAll(io, &.{ 0, 0 }); // file_count = 0
    }
    // Write a matching v1 lookup file
    const lookup_path = try std.fmt.allocPrint(alloc, "{s}/trigram.lookup", .{dir_path});
    defer alloc.free(lookup_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io, lookup_path, .{});
        defer f.close(io);
        // magic(4) + version=1(2) + pad(2) + entry_count=0(4) = 12 bytes
        try f.writeStreamingAll(io, &.{ 'C', 'D', 'B', 'L' });
        try f.writeStreamingAll(io, &.{ 1, 0 }); // version = 1
        try f.writeStreamingAll(io, &.{ 0, 0 }); // pad
        try f.writeStreamingAll(io, &.{ 0, 0, 0, 0 }); // entry_count = 0
    }

    // readGitHead on a v1 file must return null (no git head stored)
    const git_head = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(git_head == null);

    // readFromDisk on a v1 file must still succeed (backward compat)
    const loaded = TrigramIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(loaded != null);
    var loaded_ti = loaded.?;
    defer loaded_ti.deinit();
    try testing.expectEqual(@as(u32, 0), loaded_ti.fileCount());
}

test "bm25-persistence: writeToDisk/readFromDisk preserves total_tokens and doc_lengths" {
    const alloc = testing.allocator;
    var wi = WordIndex.init(alloc);
    defer wi.deinit();

    try wi.indexFile("low.txt", "needle filler filler filler filler filler filler filler filler filler");
    try wi.indexFile("high.txt", "needle needle needle filler");
    try wi.indexFile("none.txt", "filler filler filler filler");

    const pre_total = wi.total_tokens;
    const pre_low_len = wi.docLength(wi.path_to_id.get("low.txt") orelse 0);
    const pre_high_len = wi.docLength(wi.path_to_id.get("high.txt") orelse 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try wi.writeToDisk(io, dir_path, null);

    const maybe_loaded = WordIndex.readFromDisk(io, dir_path, alloc);
    try testing.expect(maybe_loaded != null);
    var loaded = maybe_loaded.?;
    defer loaded.deinit();

    try testing.expectEqual(pre_total, loaded.total_tokens);

    const post_low_id = loaded.path_to_id.get("low.txt") orelse {
        try testing.expect(false);
        return;
    };
    const post_high_id = loaded.path_to_id.get("high.txt") orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(pre_low_len, loaded.docLength(post_low_id));
    try testing.expectEqual(pre_high_len, loaded.docLength(post_high_id));

    const hits = try loaded.searchDeduped("needle", alloc);
    defer alloc.free(hits);
    try testing.expect(hits.len >= 2);

    var saw_high = false;
    var saw_low = false;
    for (hits) |h| {
        const p = loaded.hitPath(h);
        if (std.mem.eql(u8, p, "high.txt")) saw_high = true;
        if (std.mem.eql(u8, p, "low.txt")) saw_low = true;
    }
    try testing.expect(saw_high);
    try testing.expect(saw_low);

    // Post-roundtrip ranked search must still work and return hits for "needle".
    var wi2 = WordIndex.init(alloc);
    defer wi2.deinit();
    try wi2.indexFile("low.txt", "needle filler filler filler filler filler filler filler filler filler");
    try wi2.indexFile("high.txt", "needle needle needle filler");
    try wi2.indexFile("none.txt", "filler filler filler filler");

    const low_id_orig = wi2.path_to_id.get("low.txt") orelse 0;
    const high_id_orig = wi2.path_to_id.get("high.txt") orelse 0;
    try testing.expectEqual(pre_low_len, wi2.docLength(low_id_orig));
    try testing.expectEqual(pre_high_len, wi2.docLength(high_id_orig));
    try testing.expectEqual(pre_total, wi2.total_tokens);
}
