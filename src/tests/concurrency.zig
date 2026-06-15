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

test "nuke: removeJsonMcpServerEntry drops only codedb integration" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}

test "nuke: removeJsonMcpServerEntry removes empty mcpServers object" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"mcpServers\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}

test "nuke: removeCodexMcpServerBlock removes codedb block only" {
    const input =
        \\[mcp_servers.codedb]
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\startup_timeout_sec = 30
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.codedb]") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "command = \"other\"") != null);
}

test "dep-graph: setDeps removes old reverse edges" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // main.zig initially imports store.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try graph.setDeps("main.zig", deps1);

    const before = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (before) |p| testing.allocator.free(p);
        testing.allocator.free(before);
    }
    try testing.expectEqual(@as(usize, 1), before.len);

    // main.zig re-indexed, now imports utils.zig instead
    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "utils.zig");
    try graph.setDeps("main.zig", deps2);

    // store.zig should no longer have main.zig as a dependent
    const after = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (after) |p| testing.allocator.free(p);
        testing.allocator.free(after);
    }
    try testing.expectEqual(@as(usize, 0), after.len);

    // utils.zig should now have main.zig
    const utils_deps = try graph.getImportedBy("utils.zig", testing.allocator);
    defer {
        for (utils_deps) |p| testing.allocator.free(p);
        testing.allocator.free(utils_deps);
    }
    try testing.expectEqual(@as(usize, 1), utils_deps.len);
}

test "dep-graph: remove cleans forward and reverse edges" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try graph.setDeps("main.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    try testing.expectEqual(@as(usize, 2), graph.count());

    // Remove main.zig
    graph.remove("main.zig");
    try testing.expectEqual(@as(usize, 1), graph.count());

    // store.zig should only be imported by server.zig now
    const imported_by = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (imported_by) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by);
    }
    try testing.expectEqual(@as(usize, 1), imported_by.len);
    try testing.expectEqualStrings("server.zig", imported_by[0]);
}

test "bm25-state-sync: re-index and remove update total_tokens correctly" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("sync.txt", "alpha beta gamma delta epsilon");
    try testing.expectEqual(@as(u64, 5), explorer.word_index.total_tokens);

    try explorer.indexFile("sync.txt", "alpha beta");
    try testing.expectEqual(@as(u64, 2), explorer.word_index.total_tokens);

    explorer.removeFile("sync.txt");
    try testing.expectEqual(@as(u64, 0), explorer.word_index.total_tokens);
}
