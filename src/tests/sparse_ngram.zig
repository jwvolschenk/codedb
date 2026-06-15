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

test "extractSparseNgrams: short content returns empty" {
    const ng = try extractSparseNgrams("ab", testing.allocator);
    defer testing.allocator.free(ng);
    try testing.expectEqual(@as(usize, 0), ng.len);
}

test "extractSparseNgrams: minimum length content yields one ngram" {
    const ng = try extractSparseNgrams("abc", testing.allocator);
    defer testing.allocator.free(ng);
    try testing.expect(ng.len >= 1);
    try testing.expectEqual(@as(usize, 3), ng[0].len);
    try testing.expectEqual(@as(usize, 0), ng[0].pos);
}

test "extractSparseNgrams: deterministic across calls" {
    const ng1 = try extractSparseNgrams("hello world", testing.allocator);
    defer testing.allocator.free(ng1);
    const ng2 = try extractSparseNgrams("hello world", testing.allocator);
    defer testing.allocator.free(ng2);

    try testing.expectEqual(ng1.len, ng2.len);
    for (ng1, ng2) |a, b| {
        try testing.expectEqual(a.hash, b.hash);
        try testing.expectEqual(a.pos, b.pos);
        try testing.expectEqual(a.len, b.len);
    }
}

test "extractSparseNgrams: case-insensitive hashing" {
    const ng_lower = try extractSparseNgrams("hello", testing.allocator);
    defer testing.allocator.free(ng_lower);
    const ng_upper = try extractSparseNgrams("HELLO", testing.allocator);
    defer testing.allocator.free(ng_upper);

    try testing.expectEqual(ng_lower.len, ng_upper.len);
    for (ng_lower, ng_upper) |lo, hi| {
        try testing.expectEqual(lo.hash, hi.hash);
    }
}

test "extractSparseNgrams: ngrams cover entire content" {
    const content = "the quick brown fox";
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    // Verify every byte position is covered by at least one n-gram.
    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);

    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| {
            covered[p] = true;
        }
    }
    for (covered) |c| {
        try testing.expect(c);
    }
}

test "extractSparseNgrams: coverage with force-split remainder 1 (len=17)" {
    // 17 identical chars → no interior local maxima → one span of length 17.
    // Force-split: one MAX_NGRAM_LEN=16 chunk, remainder=1 → must still cover byte 16.
    const content = "aaaaaaaaaaaaaaaaa"; // 17 'a's
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| covered[p] = true;
    }
    for (covered) |c| try testing.expect(c);
}

test "extractSparseNgrams: coverage with force-split remainder 2 (len=18)" {
    // 18 identical chars → remainder=2 → must still cover bytes 16-17.
    const content = "aaaaaaaaaaaaaaaaaa"; // 18 'a's
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    var covered = try testing.allocator.alloc(bool, content.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    for (ng) |n| {
        for (n.pos..n.pos + n.len) |p| covered[p] = true;
    }
    for (covered) |c| try testing.expect(c);
}

test "extractSparseNgrams: ngram length bounds" {
    const content = "abcdefghijklmnopqrstuvwxyz0123456789";
    const ng = try extractSparseNgrams(content, testing.allocator);
    defer testing.allocator.free(ng);

    for (ng) |n| {
        try testing.expect(n.len >= 3);
        try testing.expect(n.len <= 16);
    }
}

test "pairWeight: frequency-weighted produces fewer boundaries for common text" {
    // A string composed of very common pairs should produce few local maxima
    // (interior weights are low and similar), giving fewer n-grams than a
    // string of rare pairs.
    const common = "thehereinandonthere";
    const rare = "qxzjvkqxzjvkqxzjvk";
    const ng_common = try extractSparseNgrams(common, testing.allocator);
    defer testing.allocator.free(ng_common);
    const ng_rare = try extractSparseNgrams(rare, testing.allocator);
    defer testing.allocator.free(ng_rare);
    // Rare pairs create more local maxima → more (shorter) n-grams.
    try testing.expect(ng_rare.len >= ng_common.len);
}

test "pairWeight: deterministic with frequency table" {
    const w1 = pairWeight('a', 'b');
    const w2 = pairWeight('a', 'b');
    try testing.expectEqual(w1, w2);
    // Verify common and rare pairs also remain deterministic.
    try testing.expectEqual(pairWeight('t', 'h'), pairWeight('t', 'h'));
    try testing.expectEqual(pairWeight('q', 'x'), pairWeight('q', 'x'));
}

test "frequency table: disk round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    // Build a table with distinct values.
    const content = "ababcdcdefefghghijij";
    const original = buildFrequencyTable(content);

    try writeFrequencyTable(io, &original, dir_path);

    const loaded_opt = try readFrequencyTable(io, dir_path, testing.allocator);
    try testing.expect(loaded_opt != null);
    const loaded = loaded_opt.?;
    defer testing.allocator.destroy(loaded);

    // Byte-for-byte identical.
    try testing.expectEqualSlices(
        u16,
        @as([*]const u16, @ptrCast(&original))[0 .. 256 * 256],
        @as([*]const u16, @ptrCast(loaded))[0 .. 256 * 256],
    );
}

test "frequency table: little-endian byte order on disk" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    var table: [256][256]u16 = .{.{0} ** 256} ** 256;
    table[0][0] = 0x1234; // little-endian on disk: 0x34, 0x12
    table[0][1] = 0xABCD; // little-endian on disk: 0xCD, 0xAB
    try writeFrequencyTable(io, &table, dir_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/pair_freq.bin", .{dir_path});
    defer testing.allocator.free(file_path);
    const f = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer f.close(io);
    var raw: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try f.readPositionalAll(io, &raw, 0));
    try testing.expectEqual(@as(u8, 0x34), raw[0]);
    try testing.expectEqual(@as(u8, 0x12), raw[1]);
    try testing.expectEqual(@as(u8, 0xCD), raw[2]);
    try testing.expectEqual(@as(u8, 0xAB), raw[3]);

    const loaded = try readFrequencyTable(io, dir_path, testing.allocator);
    try testing.expect(loaded != null);
    defer testing.allocator.destroy(loaded.?);
    try testing.expectEqual(@as(u16, 0x1234), loaded.?[0][0]);
    try testing.expectEqual(@as(u16, 0xABCD), loaded.?[0][1]);
}

test "thread-safe: concurrent SparseNgramIndex.candidates() with per-thread allocators" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();
    try sni.indexFile("x.zig", "pub fn handleRequest(ctx: *Context) void {}");
    try sni.indexFile("y.zig", "pub fn processData(buf: []u8) void {}");
    const ThreadCtx = struct {
        sni: *SparseNgramIndex,
        errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        fn run(ctx: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            for (0..200) |_| {
                const cands = ctx.sni.candidates("handleRequest", alloc) orelse continue;
                defer alloc.free(cands);
                var found = false;
                for (cands) |p| {
                    if (std.mem.eql(u8, p, "x.zig")) found = true;
                }
                if (!found) _ = ctx.errors.fetchAdd(1, .monotonic);
            }
        }
    };
    var ctx = ThreadCtx{ .sni = &sni };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctx});
    for (threads) |t| t.join();
}
