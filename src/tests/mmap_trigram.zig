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

test "issue-164: AnyTrigramIndex dispatches to mmap variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("foo.zig", "pub fn fooBar(x: i32) i32 { return x + 1; }");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    const mmap_loaded = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;

    explorer.trigram_index.deinit();
    explorer.trigram_index = .{ .mmap = mmap_loaded };

    const results = try explorer.searchContent("fooBar", allocator, 10);
    try testing.expect(results.len >= 1);

    try testing.expect(explorer.trigram_index.containsFile("foo.zig"));
    try testing.expect(!explorer.trigram_index.containsFile("bar.zig"));
}

test "issue-593: mmap overlay masks stale base entries (no ghost matches)" {
    // Build heap, persist, load as mmap, then removeFile a file. Pre-fix the
    // .mmap removeFile was a no-op, so the deleted file's base trigrams kept
    // answering candidates() — ghost matches from a deleted file.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("keepme.zig", "pub fn keepFunc() void {}");
    try explorer.indexFile("goner.zig", "pub fn ghostFunc() void {}");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);
    const mmap_loaded = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    explorer.trigram_index.deinit();
    explorer.trigram_index = .{ .mmap = mmap_loaded };

    // Confirm the file is reachable before removal.
    try testing.expect(explorer.trigram_index.containsFile("goner.zig"));

    // removeFile promotes to mmap_overlay and masks the base entry.
    explorer.trigram_index.removeFile("goner.zig");
    try testing.expect(explorer.trigram_index != .mmap); // promoted
    // #593: the masked base path must no longer answer containsFile, and its
    // trigrams must not leak into candidates (no ghost).
    try testing.expect(!explorer.trigram_index.containsFile("goner.zig"));
    try testing.expect(explorer.trigram_index.containsFile("keepme.zig"));

    // ghostFunc appears ONLY in goner.zig — candidates must not return it.
    const tri_idx = &explorer.trigram_index;
    const cands = tri_idx.candidates("ghostFunc", allocator);
    if (cands) |list| {
        for (list) |p| try testing.expect(!std.mem.eql(u8, p, "goner.zig"));
        allocator.free(list);
    }
}

test "issue-600: mmap_overlay writeToDisk persists overlay edits" {
    // Pre-fix the .mmap_overlay writeToDisk was a no-op, so overlay edits
    // vanished on restart. Materialize+serialize must persist the merged state.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("base.zig", "pub fn baseFn() void {}");
    try explorer.indexFile("edited.zig", "pub fn oldContent() void {}");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPathFile(io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try explorer.trigram_index.writeToDisk(io, tmp_path, null);
    const mmap_loaded = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapInitFailed;
    explorer.trigram_index.deinit();
    explorer.trigram_index = .{ .mmap = mmap_loaded };

    // Re-index "edited.zig" with new content (promotes to mmap_overlay).
    try explorer.trigram_index.indexFile("edited.zig", "pub fn newContent() void {}");
    try testing.expect(explorer.trigram_index == .mmap_overlay);

    // Persist the overlay (this was the no-op bug).
    try explorer.trigram_index.writeToDisk(io, tmp_path, null);

    // Reload fresh: the new content must survive, the old must be gone.
    var explorer2 = Explorer.init(testing.allocator);
    defer explorer2.deinit();
    const reloaded = MmapTrigramIndex.initFromDisk(io, tmp_path, testing.allocator) orelse
        return error.MmapReloadFailed;
    explorer2.trigram_index = .{ .mmap = reloaded };

    // newContent (overlay) persisted; oldContent (superseded base) did not.
    const new_cands = explorer2.trigram_index.candidates("newContent", allocator);
    var found_new = false;
    if (new_cands) |list| {
        for (list) |p| if (std.mem.eql(u8, p, "edited.zig")) {
            found_new = true;
        };
        allocator.free(list);
    }
    try testing.expect(found_new);
}
