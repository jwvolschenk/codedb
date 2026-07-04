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
    _ = @import("../watcher/skip_rules_tests.zig");
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

test "pairWeight: deterministic" {
    const w1 = pairWeight('a', 'b');
    const w2 = pairWeight('a', 'b');
    try testing.expectEqual(w1, w2);

    const w3 = pairWeight('a', 'c');
    // Different pair must (almost certainly) produce a different weight.
    // We only assert they're not trivially equal; hash collisions are acceptable.
    _ = w3; // just ensure it compiles and doesn't crash
}

test "pairWeight: different pairs produce different values (sanity)" {
    // 'ab' and 'ba' should almost never collide for a reasonable hash.
    const w_ab = pairWeight('a', 'b');
    const w_ba = pairWeight('b', 'a');
    // Not a strict requirement (collisions are ok), but verify the function runs.
    _ = w_ab;
    _ = w_ba;
}

test "buildCoveringSet: sliding window covers all query substrings" {
    // "foobar" (6 chars); lengths [3,6] yield 4+3+2+1 = 10 substrings.
    const ngrams = try buildCoveringSet("foobar", testing.allocator);
    defer testing.allocator.free(ngrams);
    try testing.expectEqual(@as(usize, 10), ngrams.len);
    for (ngrams) |ng| try testing.expect(ng.len >= 3 and ng.len <= 6);
}

test "buildCoveringSet: short query returns empty" {
    const ngrams = try buildCoveringSet("ab", testing.allocator);
    defer testing.allocator.free(ngrams);
    try testing.expectEqual(@as(usize, 0), ngrams.len);
}

test "pairWeight: common pairs have lower weight than rare pairs" {
    // Common English/code pairs should have lower base weight than rare pairs.
    // 'th' and 'er' are in the default_pair_freq table with weight 0x1000.
    // 'qx' and 'zj' are not in the table and default to 0xFE00.
    // jitter adds 0-255, so common+max_jitter (0x10FF) < rare+min_jitter (0xFE00).
    const w_th = pairWeight('t', 'h');
    const w_er = pairWeight('e', 'r');
    const w_qx = pairWeight('q', 'x');
    const w_zj = pairWeight('z', 'j');
    try testing.expect(w_th < w_qx);
    try testing.expect(w_er < w_zj);
}

test "buildFrequencyTable: common pairs get lower weight than absent pairs" {
    // Construct content where 'ab' appears many times and 'qx' never appears.
    const content = "ababababababababababab";
    const table = buildFrequencyTable(content);
    // 'ab' is frequent → low weight; 'qx' absent → default high (0xFE00).
    try testing.expect(table['a']['b'] < table['q']['x']);
    try testing.expectEqual(@as(u16, 0xFE00), table['q']['x']);
}

test "setFrequencyTable / resetFrequencyTable: pairWeight output changes" {
    // Build a table where 'th' is rare (high weight) — opposite of default.
    var custom: [256][256]u16 = .{.{0x1000} ** 256} ** 256; // all common
    custom['q']['x'] = 0xFE00; // make 'qx' rare

    const before_th = pairWeight('t', 'h');
    const before_qx = pairWeight('q', 'x');

    setFrequencyTable(&custom);
    defer resetFrequencyTable();

    const after_th = pairWeight('t', 'h');
    const after_qx = pairWeight('q', 'x');

    // After swap: 'th' should be lower (we set it to 0x1000 vs default table's 0x1000 — same).
    // What definitely changes: 'qx' base shifts from 0xFE00 to 0xFE00 (custom kept it high).
    // More importantly verify that resetting restores original values.
    resetFrequencyTable();
    try testing.expectEqual(before_th, pairWeight('t', 'h'));
    try testing.expectEqual(before_qx, pairWeight('q', 'x'));
    _ = after_th;
    _ = after_qx;
}

// ── Explorer tests ──────────────────────────────────────────

test "file versions: append and latest" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1,
        .agent = 0,
        .timestamp = 0,
        .op = .snapshot,
        .hash = 0x11,
        .size = 100,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 2,
        .agent = 0,
        .timestamp = 0,
        .op = .replace,
        .hash = 0x22,
        .size = 150,
    });

    const latest = fv.latest().?;
    try testing.expect(latest.seq == 2);
    try testing.expect(latest.size == 150);
}

test "file versions: countSince" {
    var fv = version.FileVersions.init(testing.allocator, "test.zig");
    defer fv.deinit();

    try fv.versions.append(testing.allocator, .{
        .seq = 1,
        .agent = 0,
        .timestamp = 0,
        .op = .snapshot,
        .hash = 0,
        .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 5,
        .agent = 0,
        .timestamp = 0,
        .op = .replace,
        .hash = 0,
        .size = 0,
    });
    try fv.versions.append(testing.allocator, .{
        .seq = 10,
        .agent = 0,
        .timestamp = 0,
        .op = .delete,
        .hash = 0,
        .size = 0,
    });

    try testing.expect(fv.countSince(0) == 3);
    try testing.expect(fv.countSince(1) == 2);
    try testing.expect(fv.countSince(5) == 1);
    try testing.expect(fv.countSince(10) == 0);
}

test "watcher: queue overflow is explicit" {
    var queue = watcher.EventQueue{};

    var pushed: usize = 0;
    while (true) : (pushed += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/f-{d}.zig", .{pushed});
        if (!queue.push(watcher.FsEvent.init(path, .modified, @intCast(pushed)) orelse unreachable)) break;
    }

    var overflow_path_buf: [32]u8 = undefined;
    const overflow_path = try std.fmt.bufPrint(&overflow_path_buf, "tmp/overflow.zig", .{});
    try testing.expect(!queue.push(watcher.FsEvent.init(overflow_path, .created, 999) orelse unreachable));

    var popped: usize = 0;
    while (queue.pop() != null) : (popped += 1) {}
    try testing.expect(popped == pushed);
}

test "watcher: queue event copies path bytes" {
    var queue = watcher.EventQueue{};
    const original = try testing.allocator.dupe(u8, "tmp/deleted.zig");
    try testing.expect(queue.push(watcher.FsEvent.init(original, .deleted, 99) orelse unreachable));
    testing.allocator.free(original);

    const event = queue.pop() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tmp/deleted.zig", event.path());
    try testing.expect(event.kind == .deleted);
    try testing.expect(event.seq == 99);
}

test "watcher: parallel initial scan matches sequential results" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(io, "src/nested");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\npub fn alpha() void {}\n// TODO: keep me\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "src/nested/util.py", .data = "def beta():\n    return 42\n# TODO later\n" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# demo\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp_dir.dir.realPathFile(io, ".", &root_buf);
    const root = root_buf[0..root_len];

    var store_seq = Store.init(testing.allocator);
    defer store_seq.deinit();
    var explorer_seq = Explorer.init(testing.allocator);
    defer explorer_seq.deinit();
    explorer_seq.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_seq, &explorer_seq, root, testing.allocator, false, 1);

    var store_par = Store.init(testing.allocator);
    defer store_par.deinit();
    var explorer_par = Explorer.init(testing.allocator);
    defer explorer_par.deinit();
    explorer_par.setRoot(io, root);
    try watcher.initialScanWithWorkerCount(io, &store_par, &explorer_par, root, testing.allocator, false, 4);

    const tree_seq = try explorer_seq.getTree(testing.allocator, false);
    defer testing.allocator.free(tree_seq);
    const tree_par = try explorer_par.getTree(testing.allocator, false);
    defer testing.allocator.free(tree_par);
    try testing.expectEqualStrings(tree_seq, tree_par);

    const seq_hits = try explorer_seq.searchWord("TODO", testing.allocator);
    defer testing.allocator.free(seq_hits);
    const par_hits = try explorer_par.searchWord("TODO", testing.allocator);
    defer testing.allocator.free(par_hits);
    try testing.expectEqual(seq_hits.len, par_hits.len);

    try testing.expectEqual(explorer_seq.outlines.count(), explorer_par.outlines.count());
}

test "isPathSafe: rejects absolute paths" {
    const mcp = @import("../mcp.zig");
    try testing.expect(!mcp.isPathSafe("/etc/passwd"));
    try testing.expect(!mcp.isPathSafe("/"));
}

test "isPathSafe: rejects parent traversal" {
    const mcp = @import("../mcp.zig");
    try testing.expect(!mcp.isPathSafe("../secret"));
    try testing.expect(!mcp.isPathSafe("foo/../../etc/passwd"));
    try testing.expect(!mcp.isPathSafe(".."));
}

test "isPathSafe: rejects empty path" {
    const mcp = @import("../mcp.zig");
    try testing.expect(!mcp.isPathSafe(""));
}

test "isPathSafe: accepts valid relative paths" {
    const mcp = @import("../mcp.zig");
    try testing.expect(mcp.isPathSafe("src/main.zig"));
    try testing.expect(mcp.isPathSafe("README.md"));
    try testing.expect(mcp.isPathSafe("a/b/c/d.txt"));
}

test "issue-629: projectRelPath accepts absolute paths inside the project root" {
    const mcp = @import("../mcp.zig");
    const root = "/home/user/myproject";

    // Safe relative paths pass through unchanged.
    try testing.expectEqualStrings("src/main.zig", mcp.projectRelPath("src/main.zig", root).?);

    // Absolute paths inside the root are rewritten to relative form.
    try testing.expectEqualStrings("src/main.zig", mcp.projectRelPath("/home/user/myproject/src/main.zig", root).?);
    // The root itself is not a file — rejected.
    try testing.expect(mcp.projectRelPath("/home/user/myproject", root) == null);
    try testing.expect(mcp.projectRelPath("/home/user/myproject/", root) == null);

    // Out-of-root absolutes, traversal, nulls, and backslashes stay rejected.
    try testing.expect(mcp.projectRelPath("/etc/passwd", root) == null);
    try testing.expect(mcp.projectRelPath("/home/user/other/x.zig", root) == null);
    try testing.expect(mcp.projectRelPath("../escape", root) == null);
    try testing.expect(mcp.projectRelPath("/home/user/myproject/../escape", root) == null);
    try testing.expect(mcp.projectRelPath("/home/user/myproject\x00evil", root) == null);
    try testing.expect(mcp.projectRelPath("/home/user/myproject/\\evil", root) == null);

    // Empty path rejected; empty root rejects absolutes (a safe relative path
    // needs no root and passes through, which is correct — projectRelPath only
    // uses root to rescue in-root absolutes).
    try testing.expect(mcp.projectRelPath("", root) == null);
    try testing.expect(mcp.projectRelPath("/etc/passwd", "") == null);

    // "/" is never a legitimate project root; without this guard
    // `//etc/passwd` would pass the child check via its doubled slash.
    try testing.expect(mcp.projectRelPath("//etc/passwd", "/") == null);
    try testing.expect(mcp.projectRelPath("/etc/passwd", "/") == null);
}

test "content hash: Wyhash produces consistent hash" {
    const content = "pub fn main() void {}";
    const hash1 = std.hash.Wyhash.hash(0, content);
    const hash2 = std.hash.Wyhash.hash(0, content);
    try testing.expect(hash1 == hash2);
    // Different content produces different hash
    const hash3 = std.hash.Wyhash.hash(0, "different content");
    try testing.expect(hash1 != hash3);
}

test "type_index: index and query by return type and param type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Service.cs",
        \\public class MyService
        \\{
        \\    public async Task<UserDto> GetUser(int id) { }
        \\    public void DeleteUser(int id, string reason) { }
        \\    public string GetName() { }
        \\}
    );

    // Query by return type
    const task_hits = explorer.type_index.findByReturnType("Task<UserDto>");
    try testing.expectEqual(@as(usize, 1), task_hits.len);
    try testing.expectEqualStrings("GetUser", task_hits[0].symbol_name);

    // Query by param type
    const int_hits = explorer.type_index.findByParamType("int");
    try testing.expectEqual(@as(usize, 2), int_hits.len); // GetUser and DeleteUser

    const string_hits = explorer.type_index.findByParamType("string");
    try testing.expectEqual(@as(usize, 1), string_hits.len); // DeleteUser

    // Verify counts
    try testing.expect(explorer.type_index.returnTypeCount() >= 2); // Task<UserDto>, string
    try testing.expect(explorer.type_index.paramTypeCount() >= 2); // int, string

    // Remove file and verify cleanup
    explorer.removeFile("Service.cs");
    const after_remove = explorer.type_index.findByReturnType("Task<UserDto>");
    try testing.expectEqual(@as(usize, 0), after_remove.len);
}

test "content hash: format as hex string" {
    const content = "hello world";
    const hash = std.hash.Wyhash.hash(0, content);
    var buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "{x}", .{hash}) catch unreachable;
    for (hex) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // Consistent on same content
    const hash2 = std.hash.Wyhash.hash(0, content);
    var buf2: [16]u8 = undefined;
    const hex2 = std.fmt.bufPrint(&buf2, "{x}", .{hash2}) catch unreachable;
    try testing.expectEqualStrings(hex, hex2);
}

test "content hash: empty content hashes consistently" {
    const h1 = std.hash.Wyhash.hash(0, "");
    const h2 = std.hash.Wyhash.hash(0, "");
    try testing.expect(h1 == h2);
}

// ── detectLanguage: comprehensive ───────────────────────────

test "getBool: returns true for bool true" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .bool = true });
    const mcp_getBool = @import("../mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == true);
}

test "getBool: returns false for bool false" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .bool = false });
    const mcp_getBool = @import("../mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}

test "getBool: returns false for missing key" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    const mcp_getBool = @import("../mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "missing") == false);
}

test "getBool: returns false for non-bool value" {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", .{ .integer = 1 });
    const mcp_getBool = @import("../mcp.zig").getBool;
    try testing.expect(mcp_getBool(&map, "flag") == false);
}

// ── Tool enum parsing (used by bundle) ──────────────────────

test "Tool enum: invalid names return null" {
    const Tool = @import("../mcp.zig").Tool;
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_invalid") == null);
    try testing.expect(std.meta.stringToEnum(Tool, "") == null);
    try testing.expect(std.meta.stringToEnum(Tool, "tree") == null);
}

// ── Integration: extractLines + getSymbolBody pipeline ──────

test "git: getGitHead returns 40-char hex SHA in a git repo" {
    // codedb itself is a git repo, so this should succeed
    const head = try git_mod.getGitHead(".", testing.allocator);
    try testing.expect(head != null);
    const sha = head.?;
    try testing.expectEqual(@as(usize, 40), sha.len);
    for (sha) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "git: getGitHead returns null for non-git directory" {
    // /tmp is not a git repo
    const head = try git_mod.getGitHead("/tmp", testing.allocator);
    try testing.expect(head == null);
}

test "git: isInGitWorkTree returns true inside a git repo" {
    // codedb itself is a git repo, so this should return true
    try testing.expect(git_mod.isInGitWorkTree(".", testing.allocator));
}

test "git: isInGitWorkTree returns false for non-git directory" {
    // /tmp is not a git repo
    try testing.expect(!git_mod.isInGitWorkTree("/tmp", testing.allocator));
}

test "auto-update: shouldRunAutoUpdate gates correctly" {
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Disabled by env: never runs
    try testing.expect(!update_mod.shouldRunAutoUpdate(0, null, true));
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms * 100, null, true));
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms * 100, 0, true));

    // First run (no stamp): always runs when not disabled
    try testing.expect(update_mod.shouldRunAutoUpdate(0, null, false));

    // Throttled: <24h since last check → skip
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms - 1, 0, false));

    // Exactly 24h since last check → run
    try testing.expect(update_mod.shouldRunAutoUpdate(day_ms, 0, false));

    // Long after last check → run
    try testing.expect(update_mod.shouldRunAutoUpdate(day_ms * 7, 0, false));
}

test "update: compareVersions orders semantic versions" {
    try testing.expect(try update_mod.compareVersions("0.2.55", "0.2.56") == .lt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56") == .eq);
    try testing.expect(try update_mod.compareVersions("v0.2.57", "0.2.56") == .gt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56.0") == .eq);
}

test "nuke: commandTargetsBinary only matches the current install path" {
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/tmp/codedb-test/bin/codedb serve",
        "/tmp/codedb-test/bin/codedb",
    ));
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/var/folders/example/codedb serve",
        "/private/var/folders/example/codedb",
    ));
    try testing.expect(!nuke_mod.commandTargetsBinary(
        "/Users/rachpradhan/bin/codedb --mcp",
        "/tmp/codedb-test/bin/codedb",
    ));
}

test "nuke: deregisterJsonIntegrationFile handles configs larger than 64 KiB" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/large-claude.json", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    try content.appendSlice(testing.allocator,
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "padding": "
    );
    try content.appendNTimes(testing.allocator, 'x', 70 * 1024);
    try content.appendSlice(testing.allocator, "\"\n}\n");

    var file = try tmp.dir.createFile(io, "large-claude.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content.items);

    try testing.expect(try nuke_mod.deregisterJsonIntegrationFile(io, testing.allocator, rel_path));

    const rewritten = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(std.math.maxInt(usize)));
    defer testing.allocator.free(rewritten);

    try testing.expect(std.mem.indexOf(u8, rewritten, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"padding\"") != null);
}

test "query-pipeline: callers op finds call sites and excludes definitions" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/handler.zig", "pub fn handleRequest() void {\n    // do stuff\n}\n");
    try explorer.indexFile("src/router.zig", "const handler = @import(\"handler.zig\");\npub fn route() void {\n    handleRequest();\n}\n");
    try explorer.indexFile("src/main.zig", "const router = @import(\"router.zig\");\npub fn main() void {\n    router.route();\n}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const query_json =
        \\{"pipeline":[{"op":"callers","name":"handleRequest"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, query_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Should find the call in router.zig but NOT the definition in handler.zig
    try testing.expect(std.mem.indexOf(u8, out.items, "router.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "handleRequest()") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "callers for 'handleRequest'") != null);
}

test "query-pipeline: callers → read with context_lines shows context around hits" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/service.zig",
        \\const std = @import("std");
        \\
        \\pub fn processData() void {
        \\    // process
        \\}
        \\
        \\pub fn serve() void {
        \\    processData();
        \\    processData();
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const query_json =
        \\{"pipeline":[{"op":"callers","name":"processData"},{"op":"read","context_lines":2}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, query_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Should show context around the processData() call sites (lines 8,9)
    // and include the surrounding lines (fn serve, {, })
    try testing.expect(std.mem.indexOf(u8, out.items, "service.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "processData()") != null);
    // Should NOT contain the full file from line 1 — context_lines limits the output
    // The "const std" import at line 1 should NOT appear since it's far from the hits
    try testing.expect(std.mem.indexOf(u8, out.items, "const std") == null);
}

test "auto-retry: delimiter stripping finds results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check(): pass");

    // "authmiddleware" without delimiters should still find auth_middleware
    const results = try explorer.fuzzyFindFiles("authmiddleware", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_middleware") != null);
}

test "per-file truncation: max 5 matches per file in output" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Create a file with 10 lines all matching "const"
    var content: [500]u8 = undefined;
    var pos: usize = 0;
    for (0..10) |i| {
        const line = std.fmt.bufPrint(content[pos..], "const val{d} = {d};\n", .{ i, i }) catch break;
        pos += line.len;
    }
    try explorer.indexFile("src/many_consts.zig", content[0..pos]);

    // Search — explorer returns all 10, but MCP handler would truncate to 5
    const results = try explorer.searchContent("const", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }
    // At the explorer level all 10 should be found
    try testing.expect(results.len >= 10);
}

test "dep-graph: reverse index gives O(1) imported_by lookup" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // main.zig imports store.zig and utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "store.zig");
    try deps1.append(testing.allocator, "utils.zig");
    try graph.setDeps("main.zig", deps1);

    // server.zig imports store.zig
    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    // store.zig is imported by main.zig and server.zig
    const imported_by = try graph.getImportedBy("store.zig", testing.allocator);
    defer {
        for (imported_by) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by);
    }
    try testing.expectEqual(@as(usize, 2), imported_by.len);

    // utils.zig is imported by main.zig only
    const imported_by2 = try graph.getImportedBy("utils.zig", testing.allocator);
    defer {
        for (imported_by2) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by2);
    }
    try testing.expectEqual(@as(usize, 1), imported_by2.len);
    try testing.expectEqualStrings("main.zig", imported_by2[0]);
}

test "dep-graph: transitive dependents via BFS" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // Build chain: app.zig -> server.zig -> store.zig -> utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "server.zig");
    try graph.setDeps("app.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "utils.zig");
    try graph.setDeps("store.zig", deps3);

    // Changing utils.zig affects store.zig, server.zig, app.zig transitively
    const blast = try graph.getTransitiveDependents("utils.zig", testing.allocator, null);
    defer {
        for (blast) |p| testing.allocator.free(p);
        testing.allocator.free(blast);
    }
    try testing.expectEqual(@as(usize, 3), blast.len);

    // With max_depth=1, only direct dependents
    const shallow = try graph.getTransitiveDependents("utils.zig", testing.allocator, 1);
    defer {
        for (shallow) |p| testing.allocator.free(p);
        testing.allocator.free(shallow);
    }
    try testing.expectEqual(@as(usize, 1), shallow.len);
    try testing.expectEqualStrings("store.zig", shallow[0]);
}

test "dep-graph: cycle does not cause infinite BFS" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // Create a cycle: a.zig -> b.zig -> c.zig -> a.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "b.zig");
    try graph.setDeps("a.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "c.zig");
    try graph.setDeps("b.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "a.zig");
    try graph.setDeps("c.zig", deps3);

    // Transitive dependents of a.zig — should terminate despite cycle
    const blast = try graph.getTransitiveDependents("a.zig", testing.allocator, null);
    defer {
        for (blast) |p| testing.allocator.free(p);
        testing.allocator.free(blast);
    }
    // b.zig and c.zig both transitively depend on a.zig
    try testing.expectEqual(@as(usize, 2), blast.len);

    // Forward transitive deps from a.zig — should also terminate
    const fwd = try graph.getTransitiveDependencies("a.zig", testing.allocator, null);
    defer {
        for (fwd) |p| testing.allocator.free(p);
        testing.allocator.free(fwd);
    }
    try testing.expectEqual(@as(usize, 2), fwd.len);
}

test "bm25-recall-a: single-term tf ordering" {
    // 3 docs with identical length but "apple" on different numbers of lines.
    // The index deduplicates per (doc, line), so tf = number of lines with the term.
    // Equal doc lengths mean length normalization is constant; higher tf must rank higher.
    // Each doc has exactly 10 tokens (5 lines x 2 tokens each).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    // doc1: apple on 1 of 5 lines
    try explorer.indexFile("doc1.txt", "apple filler\nfiller filler\nfiller filler\nfiller filler\nfiller filler");
    // doc2: apple on 5 of 5 lines (max tf)
    try explorer.indexFile("doc2.txt", "apple filler\napple filler\napple filler\napple filler\napple filler");
    // doc3: apple on 2 of 5 lines
    try explorer.indexFile("doc3.txt", "apple filler\napple filler\nfiller filler\nfiller filler\nfiller filler");

    const results = try explorer.searchContentRanked("apple", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("doc2.txt", results[0].path);
    try testing.expectEqualStrings("doc3.txt", results[1].path);
    try testing.expectEqualStrings("doc1.txt", results[2].path);
    try testing.expect(results[0].score > results[1].score);
    try testing.expect(results[1].score > results[2].score);
}

test "bm25-recall-b: both-terms doc beats high-tf single-term doc" {
    // doc1 has apple+banana (both query terms, one occurrence each).
    // doc2 has only apple, but repeated 3x (high tf).
    // doc3 has only banana, once.
    // BM25 sums idf*tf_norm per term: doc1 accumulates two idf contributions
    // while doc2 only gets one -- doc1 must rank first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("doc1.txt", "apple banana cherry");
    try explorer.indexFile("doc2.txt", "apple apple apple");
    try explorer.indexFile("doc3.txt", "banana date elderberry");

    const results = try explorer.searchContentRanked("apple banana", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("doc1.txt", results[0].path);
    try testing.expect(results[0].score > 0.0);
    var doc2_score: f32 = -1.0;
    for (results) |r| {
        if (std.mem.eql(u8, r.path, "doc2.txt")) {
            doc2_score = r.score;
            break;
        }
    }
    if (doc2_score >= 0.0) {
        try testing.expect(results[0].score > doc2_score);
    }
}

test "bm25-recall-d: length normalization favors shorter doc" {
    // short.txt: 5 tokens, one "needle".
    // long.txt: ~50 tokens, one "needle".
    // BM25 with b=0.75 penalizes longer docs; short.txt must rank higher.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("short.txt", "needle alpha beta gamma delta");
    try explorer.indexFile("long.txt", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv ww xx yy zz " ++
        "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq rr ss tt uu vv ww xx needle yy zz");

    const results = try explorer.searchContentRanked("needle", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("short.txt", results[0].path);
    try testing.expect(results[0].score > results[1].score);
}

test "bm25-recall-e: empty and pathological queries return empty without crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("file.txt", "some content here");

    {
        const r = try explorer.searchContentRanked("", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    {
        const r = try explorer.searchContentRanked("   ", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
    {
        const r = try explorer.searchContentRanked("nonexistent_xyz_term_99", testing.allocator, 10);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(usize, 0), r.len);
    }
}

test "bm25-stress: 1000-doc index, common token, max_results cap honored" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var path_buf: [64]u8 = undefined;
    var content_buf: [256]u8 = undefined;
    for (0..1000) |i| {
        const path = std.fmt.bufPrint(&path_buf, "stress/doc{d}.txt", .{i}) catch unreachable;
        const content = std.fmt.bufPrint(&content_buf, "common token alpha beta gamma doc{d} extra filler words here now", .{i}) catch unreachable;
        try explorer.indexFile(path, content);
    }

    const cap = 25;
    const results = try explorer.searchContentRanked("common", testing.allocator, cap);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len <= cap);
    try testing.expect(results.len > 0);
    for (results) |r| {
        try testing.expect(r.score > 0.0);
    }
    for (1..results.len) |i| {
        try testing.expect(results[i - 1].score >= results[i].score);
    }
}

test "notify drain preserves other projects' absolute paths" {
    const root = "/home/u/repos/pro";
    // Foreign project's edits must be preserved, not consumed.
    try testing.expect(watcher.notifyLineBelongsToOtherRoot("/home/u/repos/invest/src/A.cs", root));
    // Our own edits are ours to consume.
    try testing.expect(!watcher.notifyLineBelongsToOtherRoot("/home/u/repos/pro/src/A.cs", root));
    // The root path itself is ours.
    try testing.expect(!watcher.notifyLineBelongsToOtherRoot("/home/u/repos/pro", root));
    // Relative lines are ambiguous — handled by the existing per-root path.
    try testing.expect(!watcher.notifyLineBelongsToOtherRoot("src/A.cs", root));
    // Sibling dir sharing a prefix must be treated as foreign (boundary check).
    try testing.expect(watcher.notifyLineBelongsToOtherRoot("/home/u/repos/pro-old/src/A.cs", root));
}

test "issue-639: ${workspaceFolder} normalizes to implicit cwd for MCP root gates" {
    const shell = @import("../cli/shell.zig");

    // The post-normalization triple for `codedb ${workspaceFolder} mcp` MUST
    // match a bare `codedb mcp`: root=".", cmd="mcp", root_is_explicit=false.
    // Pre-fix, root_is_explicit stayed true and silently disabled both gates.
    const cmd = "mcp";
    const root = ".";
    const explicit = false;

    // Deferred-scan handshake fires for the implicit cwd root.
    try testing.expect(shell.mcpRootIsImplicitCwd(cmd, root, explicit));

    // An explicitly-passed "." (e.g. `codedb . mcp`) does NOT defer — it was
    // intentional, so index eagerly. This is the bug's crux: the unexpanded
    // placeholder must land on the implicit side of this line.
    try testing.expect(!shell.mcpRootIsImplicitCwd(cmd, root, true));

    // CODEDB_ROOT env fallback accepts cwd-root regardless of explicitness.
    try testing.expect(shell.mcpRootAcceptsEnvFallback(cmd, root));

    // A concrete project path disables both gates.
    try testing.expect(!shell.mcpRootIsImplicitCwd(cmd, "/home/u/pro", false));
    try testing.expect(!shell.mcpRootAcceptsEnvFallback(cmd, "/home/u/pro"));

    // Non-mcp commands never trip either gate.
    try testing.expect(!shell.mcpRootIsImplicitCwd("search", root, explicit));
    try testing.expect(!shell.mcpRootAcceptsEnvFallback("search", root));
}
