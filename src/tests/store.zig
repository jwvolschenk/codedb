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

test "store: record and retrieve snapshots" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const seq1 = try store.recordSnapshot("foo.zig", 100, 0xABC);
    const seq2 = try store.recordSnapshot("bar.zig", 200, 0xDEF);

    try testing.expect(seq1 == 1);
    try testing.expect(seq2 == 2);
    try testing.expect(store.currentSeq() == 2);
}

test "store: getLatest returns most recent version" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("foo.zig", 100, 0x111);
    _ = try store.recordSnapshot("foo.zig", 200, 0x222);

    const latest = store.getLatest("foo.zig").?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 200);
    try testing.expect(latest.hash == 0x222);
}

test "store: getLatest returns null for unknown file" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect(store.getLatest("nope.zig") == null);
}

test "store: changesSince counts correctly" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("c.zig", 30, 0);

    try testing.expect(store.changesSince(0) == 3);
    try testing.expect(store.changesSince(1) == 2);
    try testing.expect(store.changesSince(3) == 0);
}

test "store: changesSinceDetailed" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("a.zig", 10, 0);
    _ = try store.recordSnapshot("b.zig", 20, 0);
    _ = try store.recordSnapshot("a.zig", 15, 0);

    const changes = try store.changesSinceDetailed(1, testing.allocator);
    defer testing.allocator.free(changes);

    try testing.expect(changes.len == 2); // a.zig and b.zig both changed
}

test "store: recordDelete creates tombstone" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("del.zig", 50, 0);
    _ = try store.recordDelete("del.zig", 0);

    const latest = store.getLatest("del.zig").?;
    try testing.expect(latest.op == .tombstone);
    try testing.expect(latest.size == 0);
}

test "store: getAtCursor" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("f.zig", 10, 0x10);
    _ = try store.recordSnapshot("f.zig", 20, 0x20);
    _ = try store.recordSnapshot("f.zig", 30, 0x30);

    const at1 = store.getAtCursor("f.zig", 1).?;
    try testing.expect(at1.size == 10);

    const at2 = store.getAtCursor("f.zig", 2).?;
    try testing.expect(at2.size == 20);

    const at3 = store.getAtCursor("f.zig", 99).?;
    try testing.expect(at3.size == 30);
}

test "store: recordEdit persists diff data to data log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.openDataLog(io, log_path);

    const diff = "replace body";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0x1234, diff.len, diff);

    const latest = store.getLatest("foo.zig").?;
    try testing.expectEqual(@as(?u64, 0), latest.data_offset);
    try testing.expectEqual(@as(u32, diff.len), latest.data_len);

    const log_file = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer log_file.close(io);

    var buf: [32]u8 = undefined;
    const read_len = try log_file.readPositionalAll(io, buf[0..diff.len], 0);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
}

// ── Agent tests ─────────────────────────────────────────────

test "regression #5: getHotFiles with no store entries" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("orphan.zig", "pub fn x() void {}");

    const hot = try explorer.getHotFiles(&store, testing.allocator, 10);
    defer {
        for (hot) |path| testing.allocator.free(path);
        testing.allocator.free(hot);
    }
    // File exists in explorer but not in store — seq defaults to 0
    try testing.expect(hot.len == 1);
    try testing.expectEqualStrings("orphan.zig", hot[0]);
}

test "regression #5: store getLatestSeqUnlocked" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("seq.zig", 100, 0xAA);
    _ = try store.recordSnapshot("seq.zig", 200, 0xBB);

    store.mu.lock();
    const seq = store.getLatestSeqUnlocked("seq.zig");
    const missing = store.getLatestSeqUnlocked("nope.zig");
    store.mu.unlock();

    try testing.expect(seq == 2);
    try testing.expect(missing == 0);
}

test "disk index: writeToDisk stores git_head, readGitHead retrieves it" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("a.zig", "fn hello() void {}");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "aabbccddeeff00112233445566778899aabbccdd".*;
    try ti.writeToDisk(io, dir_path, fake_head);

    const retrieved = try TrigramIndex.readGitHead(io, dir_path, alloc);
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, &fake_head, &retrieved.?);
}

test "issue-220: snapshot fast load restores outlines and lazily rebuilds word index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa);
    try exp.indexFile("src/store.zig", "pub const Store = struct {};\n");
    try exp.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/fast.codedb", .{dir_path});
    defer testing.allocator.free(snap_path);
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, testing.allocator);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    var exp2 = Explorer.init(arena2.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const loaded = snapshot_mod.loadSnapshot(io, snap_path, "", &exp2, &store, arena2.allocator());
    try testing.expect(loaded);
    try testing.expectEqual(@as(usize, 2), exp2.outlines.count());
    try testing.expectEqual(@as(u32, 0), exp2.trigram_index.fileCount());
    try testing.expectEqual(@as(usize, 0), exp2.word_index.index.count());
    try testing.expect(exp2.wordIndexCanLoadFromDisk());
    try testing.expect(!exp2.wordIndexIsComplete());
    try testing.expect(!exp2.wordIndexNeedsPersist());

    const deps = try exp2.getImportedBy("src/store.zig", testing.allocator);
    defer {
        for (deps) |dep| testing.allocator.free(dep);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expect(std.mem.eql(u8, deps[0], "src/main.zig"));

    const hits = try exp2.searchWord("Store", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len >= 1);
    try testing.expect(exp2.word_index.index.count() > 0);
    try testing.expect(exp2.wordIndexIsComplete());
    try testing.expect(exp2.wordIndexNeedsPersist());
}

test "issue-101: Store.max_versions is configurable (caps per-file history)" {
    // Default cap is 100. After setting max_versions = 3, writing 5 versions
    // of the same file must leave exactly 3 in-memory.
    var store = Store.init(testing.allocator);
    defer store.deinit();

    store.max_versions = 3;

    _ = try store.recordSnapshot("foo.zig", 10, 0x111);
    _ = try store.recordSnapshot("foo.zig", 20, 0x222);
    _ = try store.recordSnapshot("foo.zig", 30, 0x333);
    _ = try store.recordSnapshot("foo.zig", 40, 0x444);
    _ = try store.recordSnapshot("foo.zig", 50, 0x555);

    const entry = store.files.get("foo.zig") orelse return error.MissingFile;
    try testing.expectEqual(@as(usize, 3), entry.versions.items.len);
    // Oldest two dropped — newest survives.
    try testing.expectEqual(@as(u64, 0x555), entry.versions.items[2].hash);
}

test "issue-101+102: Config.parse wires into Store.max_versions and Explorer.content_cache_limit" {
    // End-to-end: parse a .codedbrc body, apply to Store + Explorer,
    // verify both fields pick up the configured values.
    const body =
        \\# test config
        \\max_versions = 7
        \\max_cached = 42
        \\
    ;
    const cfg = try Config.parse(body);
    try testing.expectEqual(@as(usize, 7), cfg.max_versions);
    try testing.expectEqual(@as(u32, 42), cfg.max_cached);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    store.max_versions = cfg.max_versions;

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.content_cache_limit = cfg.max_cached;

    try testing.expectEqual(@as(usize, 7), store.max_versions);
    try testing.expectEqual(@as(u32, 42), explorer.content_cache_limit);
}
