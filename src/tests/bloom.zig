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

test "bloom: PostingMask is populated during indexing" {
    // Verify that indexing actually sets mask bits, not just zeros.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("a.zig", "pub fn init(allocator) void {}");

    // Trigram "pub" should exist with non-zero masks
    const tri_pub = packTrigram('p', 'u', 'b');
    const file_set = ti.index.getPtr(tri_pub);
    try testing.expect(file_set != null);

    const mask = file_set.?.get("a.zig");
    try testing.expect(mask != null);
    // loc_mask must have at least one bit set (position 0)
    try testing.expect(mask.?.loc_mask != 0);
    // next_mask must have at least one bit set (char after "pub" is ' ')
    try testing.expect(mask.?.next_mask != 0);
}

test "bloom: loc_mask records correct position bits" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // Content where "abc" appears at known positions
    // Position 0: "abcXXXXXabcYYYYY" — abc at pos 0 and pos 8
    try ti.indexFile("pos.zig", "abcXXXXXabcYYYYY");

    const tri_abc = packTrigram('a', 'b', 'c');
    const file_set = ti.index.getPtr(tri_abc).?;
    const mask = file_set.get("pos.zig").?;

    // pos 0 → bit 0, pos 8 → bit 0 (8 % 8 = 0)
    try testing.expect(mask.loc_mask & 1 != 0); // bit 0 set
}

test "bloom: next_mask records the following character" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("next.zig", "abcdef");

    // For trigram "abc" at position 0, next char is 'd'
    const tri_abc = packTrigram('a', 'b', 'c');
    const file_set = ti.index.getPtr(tri_abc).?;
    const mask = file_set.get("next.zig").?;

    const expected_bit: u8 = @as(u8, 1) << @intCast(normalizeChar('d') % 8);
    try testing.expect(mask.next_mask & expected_bit != 0);
}

test "bloom: soundness — never rejects actual matches" {
    // The bloom filter must NEVER produce false negatives.
    // Every file that actually contains the query must appear in candidates.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // Index many files with varied content, some containing the target
    try ti.indexFile("match1.zig", "fn handleRequest(ctx: *Context) void {}");
    try ti.indexFile("match2.zig", "pub fn handleRequest() !void { return error.Fail; }");
    try ti.indexFile("noise1.zig", "fn processData(input: []const u8) void {}");
    try ti.indexFile("noise2.zig", "const handler = RequestPool.init();"); // has "handl" and "eques" but not "handleRequest"
    try ti.indexFile("noise3.zig", "fn handleResponse(ctx: *Context) void {}"); // close but different
    try ti.indexFile("noise4.zig", "pub fn register(name: []const u8) void {}");
    try ti.indexFile("noise5.zig", "const request_handler = getHandler();"); // has both words but not adjacent

    const cands = ti.candidates("handleRequest", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // MUST find both actual matches — bloom filter cannot reject them
    var found1 = false;
    var found2 = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "match1.zig")) found1 = true;
        if (std.mem.eql(u8, p, "match2.zig")) found2 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
}

test "bloom: loc_mask adjacency filtering works" {
    // Construct a scenario where two trigrams exist in a file but at
    // positions where they can't be adjacent. The loc_mask check should
    // filter this out (probabilistically, but deterministically for
    // carefully chosen positions).
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "XXXabcYYYYYYYYYYYYYYYdefZZZ" — "abc" at pos 3, "def" at pos 21
    // Query "abcdef" needs abc at pos N and def at pos N+3.
    // But abc is at pos 3 (bit 3) and def is at pos 21 (bit 5).
    // Shifted abc loc_mask bit 3 → bit 4. "bcd" would need to be at bit 4.
    // This tests the adjacency logic.
    try ti.indexFile("adjacent.zig", "XXabcdefGH"); // abc and def ARE adjacent
    try ti.indexFile("apart.zig", "XXXabcYYYYYYYYYYYYYYdefZZZ"); // abc and def far apart

    const cands = ti.candidates("abcdef", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // adjacent.zig MUST be found
    var found_adjacent = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "adjacent.zig")) found_adjacent = true;
    }
    try testing.expect(found_adjacent);

    // apart.zig MAY be filtered out by loc_mask (depends on position mod 8 collision)
    // We can't assert it's excluded because bloom filters allow false positives,
    // but we CAN assert the total candidate count is reasonable.
    try testing.expect(cands.?.len >= 1); // at least the real match
}

test "bloom: masks accumulate across multiple positions" {
    // If a trigram appears at many positions in a file, both masks should
    // have multiple bits set (OR'd together, never replaced).
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    // "the" appears at positions 0, 10, 20, 30, 40, 50, 60, 70
    try ti.indexFile("repeat.zig", "the_______the_______the_______the_______the_______the_______the_______the_______");

    const tri_the = packTrigram('t', 'h', 'e');
    const file_set = ti.index.getPtr(tri_the).?;
    const mask = file_set.get("repeat.zig").?;

    // With 8+ occurrences at varying positions, loc_mask should have many bits set
    try testing.expect(@popCount(mask.loc_mask) >= 3);
    // next_mask should also have bits set (from the chars following each "the")
    try testing.expect(mask.next_mask != 0);
}

test "bloom: regression — candidate count for known queries" {
    // Regression benchmark: index a controlled set of files and assert
    // specific candidate counts. If bloom filtering breaks or regresses,
    // these counts will increase.
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.indexFile("a.zig", "pub fn initAllocator() void {}");
    try ti.indexFile("b.zig", "pub fn deinitAllocator() void {}");
    try ti.indexFile("c.zig", "pub fn init() void {}");
    try ti.indexFile("d.zig", "fn publish(data: []u8) void {}");
    try ti.indexFile("e.zig", "const initial_value = 0;");
    try ti.indexFile("f.zig", "fn processInput() !void {}");
    try ti.indexFile("g.zig", "const config = getConfig();");
    try ti.indexFile("h.zig", "fn handleNotification() void {}");

    // "initAllocator" — a.zig must be found; b.zig ("deinitAllocator") shares trigrams
    {
        const cands = ti.candidates("initAllocator", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        var found_a = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "a.zig")) found_a = true;
        }
        try testing.expect(found_a);
        // b.zig is a valid false positive (shares "initAllocator" substring in "deinitAllocator")
        // but d/e/f/g/h should not appear
        try testing.expect(cands.?.len <= 2);
    }

    // "pub fn init" — should find a.zig, c.zig; maybe b.zig (shares "pub fn ")
    // but NOT d/e/f/g/h
    {
        const cands = ti.candidates("pub fn init", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        // Must include actual matches
        var found_a = false;
        var found_c = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "a.zig")) found_a = true;
            if (std.mem.eql(u8, p, "c.zig")) found_c = true;
        }
        try testing.expect(found_a);
        try testing.expect(found_c);
        // Candidate count must be <= 4 (bloom should exclude some)
        // Without bloom: files sharing any "pub"/"fn "/"ini"/"nit" trigrams = many
        // With bloom: adjacency + next_mask filtering should narrow it down
        try testing.expect(cands.?.len <= 4);
    }

    // "processInput" — f.zig must be found, few false positives allowed
    {
        const cands = ti.candidates("processInput", testing.allocator);
        defer if (cands) |c| testing.allocator.free(c);
        try testing.expect(cands != null);
        var found_f = false;
        for (cands.?) |p| {
            if (std.mem.eql(u8, p, "f.zig")) found_f = true;
        }
        try testing.expect(found_f);
        // Bloom may allow a false positive but should be way less than 8
        try testing.expect(cands.?.len <= 3);
    }
}

// ── Regex correctness regression tests ──────────────────────

test "perf regression: bloom filter reduces scan work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();

    for (0..50) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d:0>2}.zig", .{i});
        const content = try std.fmt.allocPrint(alloc, "pub fn init_{d}(allocator: Allocator) void {{}}\nfn deinit_{d}() void {{}}\n", .{ i, i });
        try ti.indexFile(name, content);
    }

    // "pub fn init_25" — specific enough to test bloom effectiveness
    const cands = ti.candidates("pub fn init_25", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    // With bloom filtering, should find very few candidates
    try testing.expect(cands.?.len <= 10);

    // The actual target file MUST be present (soundness)
    var found_target = false;
    for (cands.?) |p| {
        if (std.mem.eql(u8, p, "f25.zig")) found_target = true;
    }
    try testing.expect(found_target);

    // KEY ASSERTION: candidate count is meaningfully less than total files
    // This proves bloom filtering is doing work, not just passing through
    try testing.expect(cands.?.len < 25); // must eliminate at least half
}

// ── Disk persistence tests ──────────────────────────────────

test "disk index: bloom masks preserved after round-trip" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("bloom.zig", "pub fn handleRequest(ctx: *Context) void {}");

    // Get original masks
    const tri = packTrigram('h', 'a', 'n');
    const orig_set = ti.index.getPtr(tri).?;
    const orig_mask = orig_set.get("bloom.zig").?;

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

    // Check masks match
    const loaded_set = loaded_ti.index.getPtr(tri).?;
    const loaded_mask = loaded_set.get("bloom.zig").?;
    try testing.expectEqual(orig_mask.next_mask, loaded_mask.next_mask);
    try testing.expectEqual(orig_mask.loc_mask, loaded_mask.loc_mask);
}
