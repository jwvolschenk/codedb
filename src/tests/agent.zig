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

test "agent: register and heartbeat" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("test-agent");
    try testing.expect(id == 1);

    agents.heartbeat(id);
    // No crash = success
}

test "agent: register multiple agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("alpha");
    const b = try agents.register("beta");
    try testing.expect(a == 1);
    try testing.expect(b == 2);
}

test "agent: lock and unlock" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("locker");

    const got = try agents.tryLock(id, "file.zig", 60_000);
    try testing.expect(got == true);

    agents.releaseLock(id, "file.zig");
}

test "agent: lock contention between agents" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const a = try agents.register("agent-a");
    const b = try agents.register("agent-b");

    // A locks the file
    const got_a = try agents.tryLock(a, "shared.zig", 60_000);
    try testing.expect(got_a == true);

    // B should be denied
    const got_b = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b == false);

    // A releases
    agents.releaseLock(a, "shared.zig");

    // B can now lock
    const got_b2 = try agents.tryLock(b, "shared.zig", 60_000);
    try testing.expect(got_b2 == true);
}

test "agent: same-agent relock does not duplicate lock key" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-relock");

    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "shared.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    try testing.expect(agent.locked_paths.count() == 1);

    agents.releaseLock(id, "shared.zig");
    try testing.expect(agent.locked_paths.count() == 0);
}

test "agent: reapStale frees lock keys and clears map" {
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();

    const id = try agents.register("agent-stale");
    try testing.expect(try agents.tryLock(id, "a.zig", 60_000));
    try testing.expect(try agents.tryLock(id, "b.zig", 60_000));

    const agent = agents.agents.getPtr(id) orelse return error.TestUnexpectedResult;
    agent.last_seen = 0;
    agents.reapStale(0);

    try testing.expect(agent.state == .crashed);
    try testing.expect(agent.locked_paths.count() == 0);
}
// ── Word index tests ────────────────────────────────────────
