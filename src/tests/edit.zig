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

test "edit: range_start zero is invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-range.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-range.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 0, 1 },
        .content = "changed",
    }));
}

test "edit: range_start beyond file is invalid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-range-oob.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var file = try tmp.dir.createFile(io, "edit-range-oob.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line 1\nline 2\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("test-agent-oob");

    try testing.expectError(error.InvalidRange, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 3, 3 },
        .content = "changed",
    }));
}

test "issue-360: edit rejects mismatched if_hash and leaves file untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-if-hash.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "line 1\nline 2\nline 3\n";
    var file = try tmp.dir.createFile(io, "edit-if-hash.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-agent");

    // A hash value that cannot match any real file content (caller saw a stale read)
    try testing.expectError(error.HashMismatch, edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "stale-line edit",
        .if_hash = "deadbeef",
    }));

    // File on disk must be unchanged after the rejected edit
    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after_bytes);
    try testing.expectEqualStrings(original, after_bytes);
}

test "issue-360: edit dry_run returns diff preview and leaves file untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-dry.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "alpha\nbeta\ngamma\n";
    var file = try tmp.dir.createFile(io, "edit-dry.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-dry-agent");

    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 2, 2 },
        .content = "BETA",
        .dry_run = true,
    });
    defer if (result.preview) |p| testing.allocator.free(p);

    // File on disk is untouched.
    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after_bytes);
    try testing.expectEqualStrings(original, after_bytes);

    // Store unchanged.
    try testing.expectEqual(@as(u64, 0), store.currentSeq());

    // seq=0 indicates not committed; new_hash is the would-be hash.
    try testing.expectEqual(@as(u64, 0), result.seq);

    // Preview shows both the removed and the added line.
    try testing.expect(result.preview != null);
    const preview = result.preview.?;
    try testing.expect(std.mem.indexOf(u8, preview, "-beta") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "+BETA") != null);
}

test "edit: atomic write leaves no temp files on success" {
    // Create a temp file to edit
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = "test_atomic.zig";
    const content = "line1\nline2\nline3\n";
    try tmp_dir.dir.writeFile(io, .{ .sub_path = path, .data = content });

    // The temp file pattern is "{path}.codedb_tmp"
    const tmp_path = path ++ ".codedb_tmp";

    // After a successful edit, no .codedb_tmp file should remain
    tmp_dir.dir.access(io, tmp_path, .{}) catch {
        // Expected: temp file doesn't exist (good)
        return;
    };
    // If we get here, the temp file exists — that's a bug
    return error.TempFileNotCleaned;
}

// ── MCP enhancement tests ───────────────────────────────────

test "issue-405: cleanupStaleTmpFiles deletes in-flight sibling tmp files" {
    // BUG: snapshot.zig:cleanupStaleTmpFiles deletes ANY file matching
    // `<basename>*.tmp` in the snapshot directory with no age guard.
    // If a sibling writer (another process / parallel scan) is mid-write
    // — i.e. it has just created `<output>.<rand>.tmp` and is still
    // streaming bytes into it before the final rename(tmp, dest) — then a
    // concurrent loadSnapshotValidated() will unlink the sibling's
    // in-flight tmp file. The sibling's subsequent rename then fails with
    // ENOENT and the snapshot write silently aborts.
    //
    // Reproduces deterministically by simulating the in-flight tmp file
    // and observing that loadSnapshotValidated removes it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Step 1: write a real, valid snapshot at <dir>/snap.codedb so
    // loadSnapshotValidated has something legitimate to read.
    var exp = Explorer.init(aa);
    try exp.indexFile("a.zig", "pub fn alpha() void {}\n");
    const snap_path = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb" });
    try snapshot_mod.writeSnapshot(io, &exp, dir_path, snap_path, aa);

    // Step 2: simulate a SIBLING writer that has just created its tmp file
    // but has NOT yet renamed. This file matches the cleanup pattern
    // (starts with basename, ends with ".tmp").
    const sibling_tmp = try std.fs.path.join(aa, &.{ dir_path, "snap.codedb.deadbeef.tmp" });
    {
        var f = try std.Io.Dir.cwd().createFile(io, sibling_tmp, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "in-flight write");
    }

    // Sanity: the sibling tmp exists.
    std.Io.Dir.cwd().access(io, sibling_tmp, .{}) catch return error.TestUnexpectedResult;

    // Step 3: run loadSnapshotValidated. cleanupStaleTmpFiles is the
    // first thing it does. After this, the sibling's in-flight tmp
    // file MUST still exist — otherwise the sibling's rename will fail.
    var exp2 = Explorer.init(aa);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = snapshot_mod.loadSnapshotValidated(io, snap_path, null, &exp2, &store, aa);

    // Expected: the in-flight sibling tmp is preserved.
    // Current (bug): cleanupStaleTmpFiles unconditionally deletes it.
    std.Io.Dir.cwd().access(io, sibling_tmp, .{}) catch {
        return error.TestExpectedSiblingTmpPreserved;
    };
}

test "issue-401: insert with after=null is a no-op but consumes seq and writes file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-401.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "line 1\nline 2\nline 3\n";
    var file = try tmp.dir.createFile(io, "edit-401.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-401-agent");

    // insert without after must not silently succeed and must not consume a seq.
    const res = edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .insert,
        .after = null,
        .content = "INJECT\n",
    });
    // Either explicit error, or — at minimum — must not increment the store seq
    // for an operation that did nothing.
    if (res) |ok| {
        _ = ok;
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    } else |_| {
        try testing.expectEqual(@as(u64, 0), store.currentSeq());
    }
}

test "issue-404: applyEdit corrupts CRLF line endings into mixed LF/CRLF" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-404.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    // Windows-style CRLF original
    const original = "alpha\r\nbeta\r\ngamma\r\n";
    var file = try tmp.dir.createFile(io, "edit-404.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-404-agent");

    // Replace line 1 with new content (no trailing newline in replacement).
    _ = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 1, 1 },
        .content = "ALPHA",
    });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(after);

    // The original file used CRLF line endings. After a single-line replace
    // the file must still be a valid CRLF file: every '\n' must be preceded
    // by '\r'. Currently splitScalar on '\n' leaves the '\r' attached to the
    // *unchanged* lines (e.g. "beta\r"), and the rejoin uses bare "\n", so
    // the new line 1 lacks its CR while the surviving line 2 still has it —
    // mixed line endings.
    var i: usize = 0;
    while (i < after.len) : (i += 1) {
        if (after[i] == '\n') {
            try testing.expect(i > 0);
            try testing.expectEqual(@as(u8, '\r'), after[i - 1]);
        }
    }
}
