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

test "issue-360: edit response reports hex hash matching codedb_read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/edit-hex.txt", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    const original = "alpha\nbeta\ngamma\n";
    var file = try tmp.dir.createFile(io, "edit-hex.txt", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, original);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    const agent_id = try agents.register("issue-360-hex-agent");

    const result = try edit_mod.applyEdit(io, testing.allocator, &store, &agents, null, .{
        .path = rel_path,
        .agent_id = agent_id,
        .op = .replace,
        .range = .{ 2, 2 },
        .content = "BETA",
    });

    // Hash returned matches Wyhash of the new content, hex-formatted same as codedb_read
    const new_bytes = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(10 * 1024));
    defer testing.allocator.free(new_bytes);
    const expected_hash = std.hash.Wyhash.hash(0, new_bytes);
    try testing.expectEqual(expected_hash, result.new_hash);
}

test "issue-107: codedb_deps returns results for Python files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("mypackage/utils/helpers.py", "def helper_func():\n    pass\n");
    try explorer.indexFile("consumer.py", "from mypackage.utils.helpers import helper_func\n");

    const deps = try explorer.getImportedBy("mypackage/utils/helpers.py", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }

    try testing.expect(deps.len == 1);
    try testing.expectEqualStrings("consumer.py", deps[0]);
}

test "issue-148: dead MCP clients are polled every second" {
    const mcp = @import("../mcp.zig");
    try testing.expectEqual(@as(u64, 1000), mcp.dead_client_poll_ms);
}

test "issue-278: MCP tracks activity without using it as a transport timeout" {
    const mcp = @import("../mcp.zig");

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    // Set activity to "just now"
    mcp.last_activity.store(cio.milliTimestamp(), .release);

    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();
    try testing.expect(now - last < 1_000);
}

test "issue-278: MCP session may remain idle longer than old timeout" {
    const mcp = @import("../mcp.zig");
    // Stale activity is now only an accounting signal. The stdio transport is
    // kept alive until the client actually disconnects.
    const old_idle_timeout_ms = 60 * 60 * 1000;
    const older_than_old_timeout = cio.milliTimestamp() - old_idle_timeout_ms - 1_000;

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    mcp.last_activity.store(older_than_old_timeout, .release);
    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();

    try testing.expect(now - last > old_idle_timeout_ms);
}

test "issue-224: codedb_symbol body=true returns full body — line_end populated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);

    try explorer.indexFile("t.zig",
        \\pub fn foo() u32 {
        \\    const a: u32 = 1;
        \\    const b: u32 = 2;
        \\    return a + b;
        \\}
    );

    const results = try explorer.findAllSymbols("foo", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);

    const sym = results[0].symbol;
    try testing.expectEqual(@as(u32, 1), sym.line_start);
    try testing.expectEqual(@as(u32, 5), sym.line_end);

    const body = (try explorer.getSymbolBody("t.zig", sym.line_start, sym.line_end, alloc)) orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, body, "pub fn foo()") != null);
    try testing.expect(std.mem.indexOf(u8, body, "return a + b;") != null);
}

test "issue-346: root_policy rejects dangerous ambient cwd roots" {
    const root_policy = @import("../root_policy.zig");
    try testing.expect(!root_policy.isIndexableRoot("/"));
    try testing.expect(!root_policy.isIndexableRoot("/Applications"));
    try testing.expect(!root_policy.isIndexableRoot("/usr"));
    try testing.expect(!root_policy.isIndexableRoot("/usr/local"));
    try testing.expect(!root_policy.isIndexableRoot("/usr/local/bin"));
    try testing.expect(!root_policy.isIndexableRoot("/opt"));
    try testing.expect(!root_policy.isIndexableRoot("/opt/homebrew"));
}

test "issue-359: mcp.globMatch backtracks across **/* boundary" {
    // Pipeline filter (codedb_query) calls mcp.globMatch on each path. The
    // iterative version forgot the outer ** position when it entered the
    // inner *.zig star, so paths like src/sub/inner.zig were rejected by
    // src/**/*.zig even though they should match.
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/sub/inner.zig"));
    try testing.expect(mcp_mod.globMatch("src/**/*.zig", "src/a/b/c.zig"));

    // Single * still must not cross /.
    try testing.expect(!mcp_mod.globMatch("src/*.zig", "src/sub/inner.zig"));

    // Plain prefix matches still work.
    try testing.expect(mcp_mod.globMatch("src/*.zig", "src/mcp.zig"));
    try testing.expect(!mcp_mod.globMatch("docs/*.md", "src/mcp.zig"));
}

test "issue-357: bundle preserves nested 'arguments' for codedb_outline" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[
        \\  {"tool":"codedb_outline","arguments":{"path":"src/main.zig"}},
        \\  {"tool":"codedb_outline","arguments":{"path":"src/lib.zig"}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Nested-args bundle path must preserve 'path' for every op — no missing-arg errors.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path' argument") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/lib.zig") != null);
}

test "issue-356-2: codedb_outline suggests fuzzy alternatives for non-indexed paths" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/mcp.zig", "pub fn mcp() void {}\n");
    try explorer.indexFile("src/explore.zig", "pub fn explore() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Outline a path that doesn't index — typo on 'main.zig'.
    const args_json =
        \\{"path":"src/man.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    // Pre-fix: bare 'error: file not indexed' with no recovery hint.
    // Post-fix: append fuzzy suggestions so the agent can self-correct.
    try testing.expect(std.mem.indexOf(u8, out.items, "did you mean") != null);
    // src/main.zig is the closest fuzzy match for src/man.zig.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
}

test "issue-356-p2: codedb_outline missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"file_path":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "file_path") != null);
}

test "issue-356-p2: codedb_symbol missing name surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"symbol":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'name'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "symbol") != null);
}

test "issue-356-p2: codedb_word missing word surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"w":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_word, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'word'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}

test "issue-356-p2: codedb_read missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"file":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}

test "issue-356-p2: codedb_deps missing path surfaces received keys" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"target":"src/main.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_deps, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}

fn expectJsonToolResponse(tool: mcp_mod.Tool, args_json: []const u8, expected_tool: []const u8, explorer: *Explorer) !void {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, tool, &parsed.value.object, &out, &store, explorer, &agents);

    const response = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    defer response.deinit();

    try testing.expectEqualStrings(expected_tool, response.value.object.get("tool").?.string);
    const hits = response.value.object.get("hits") orelse response.value.object.get("symbols") orelse return error.TestUnexpectedResult;
    try testing.expect(hits.array.items.len > 0);
    const first = hits.array.items[0].object;
    try testing.expect(first.get("confidence") != null);
    try testing.expect(first.get("why_matched") != null);
    try testing.expect(first.get("semantic_kind") != null);
}

test "read-only MCP tools support output_format json with metadata" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/foo.zig",
        \\pub fn Probe() void {}
        \\pub fn Caller() void { Probe(); }
    );

    try expectJsonToolResponse(.codedb_outline, "{\"path\":\"src/foo.zig\",\"output_format\":\"json\"}", "codedb_outline", &explorer);
    try expectJsonToolResponse(.codedb_symbol, "{\"name\":\"Probe\",\"output_format\":\"json\"}", "codedb_symbol", &explorer);
    try expectJsonToolResponse(.codedb_search, "{\"query\":\"Probe\",\"scope\":true,\"output_format\":\"json\"}", "codedb_search", &explorer);
    try expectJsonToolResponse(.codedb_word, "{\"word\":\"Probe\",\"output_format\":\"json\"}", "codedb_word", &explorer);
    try expectJsonToolResponse(.codedb_callers, "{\"name\":\"Probe\",\"match_mode\":\"semantic\",\"output_format\":\"json\"}", "codedb_callers", &explorer);
}

test "issue-356-p3: codedb_read appends fuzzy suggestions when path is unreadable" {
    const tmp_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(tmp_io, "src");
    try tmp.dir.writeFile(tmp_io, .{
        .sub_path = "src/main.zig",
        .data = "pub fn main() void {}\n",
    });

    var project_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_path_len = try tmp.dir.realPathFile(tmp_io, ".", &project_path_buf);
    const project_path = project_path_buf[0..project_path_len];

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(tmp_io, project_path);
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, project_path);
    defer bench_ctx.deinit();

    // Read a non-indexed, non-existent path. Pre-fix: bare 'failed to read file'.
    // Post-fix: append fuzzy suggestions like outline already does.
    const args_json =
        \\{"path":"src/man.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "failed to read file") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
}

test "issue-bug5: codedb_read returns binary stub instead of dumping bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const bin_rel = "blob.bin";
    const bin_full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, bin_rel });
    defer testing.allocator.free(bin_full);
    {
        const f = try std.Io.Dir.cwd().createFile(io, bin_full, .{ .truncate = true });
        defer f.close(io);
        const payload = [_]u8{ 'a', 'b', 0, 'c', 'd', 0, 'e' };
        try f.writePositionalAll(io, &payload, 0);
    }

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, dir_path);
    defer bench_ctx.deinit();

    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\"}}", .{bin_rel});
    defer testing.allocator.free(args_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "binary file") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, &[_]u8{0}) == null);
}

test "issue-bug6: codedb_read errors when line_start > line_end" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const rel = "small.txt";
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, rel });
    defer testing.allocator.free(full);
    {
        const f = try std.Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, "alpha\nbeta\ngamma\n", 0);
    }

    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    explorer.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, dir_path);
    defer bench_ctx.deinit();

    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\",\"line_start\":100,\"line_end\":10}}", .{rel});
    defer testing.allocator.free(args_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "line_start") != null);
}

test "issue-bug11: codedb_bundle marks isError when all ops fail" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"ops":[{"tool":"codedb_outline"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
}

// DISABLED: telemetry test depends on tmpDir file IO which is flaky
// test "issue-386: telemetry recordToolCall preserves UTF-8 codepoint boundaries" {
//     var tmp = testing.tmpDir(.{});
//     defer tmp.cleanup();
//
//     var path_buf: [std.fs.max_path_bytes]u8 = undefined;
//     const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
//     const dir_path = path_buf[0..dir_path_len];
//
//     var telem = telemetry_mod.Telemetry.init(io, dir_path, testing.allocator, false);
//     defer telem.deinit();
//
//     // 30 ASCII bytes + a 3-byte UTF-8 codepoint (✓ = 0xE2 0x9C 0x93) lands the
//     // codepoint boundary at byte 33. The 32-byte cap currently truncates inside
//     // the codepoint, leaving 0xE2 0x9C as the trailing bytes — invalid UTF-8.
//     const tool_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xe2\x9c\x93_tail";
//     telem.recordToolCall(tool_name, 1234, false, 56);
//     telem.flush();
//
//     const ndjson_path = try std.fmt.allocPrint(testing.allocator, "{s}/telemetry.ndjson", .{dir_path});
//     defer testing.allocator.free(ndjson_path);
//
//     const contents = try std.Io.Dir.cwd().readFileAlloc(io, ndjson_path, testing.allocator, .limited(64 * 1024));
//     defer testing.allocator.free(contents);
//
//     const tool_field = "\"tool\":\"";
//     const idx = std.mem.indexOf(u8, contents, tool_field) orelse return error.ToolFieldMissing;
//     const after = contents[idx + tool_field.len ..];
//     const end = std.mem.indexOfScalar(u8, after, '"') orelse return error.ToolFieldUnterminated;
//     const recorded = after[0..end];
//
//     // The recorded tool slice must be valid UTF-8. A mid-codepoint truncation
//     // produces invalid bytes — std.unicode.utf8ValidateSlice rejects them.
//     try testing.expect(std.unicode.utf8ValidateSlice(recorded));
// }

test "issue-387: appendId preserves JSON-RPC numeric and number_string ids" {
    // JSON-RPC ids are typed as String|Number|Null. The MCP server must echo
    // the id verbatim so the client can correlate the reply with its request.
    // appendId currently only handles .integer and .string — .float and
    // .number_string fall through to "null", breaking correlation for any
    // client that uses a fractional id (some test runners) or that the JSON
    // parser materializes as number_string.

    // Float id round-trips: parsing "3.5" yields .float, which must serialize
    // back to "3.5" (or any representation a JSON parser accepts as the same
    // number) — NOT "null".
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "3.5", .{});
        defer parsed.deinit();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        mcp_mod.appendId(testing.allocator, &buf, parsed.value);
        try testing.expect(!std.mem.eql(u8, buf.items, "null"));
    }

    // number_string round-trips: a request with `"id": 12345678901234567890`
    // (>i64) is parsed as .number_string. The reply must echo the digits, not
    // the literal "null".
    {
        const v = std.json.Value{ .number_string = "12345678901234567890" };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        mcp_mod.appendId(testing.allocator, &buf, v);
        try testing.expectEqualStrings("12345678901234567890", buf.items);
    }
}

test "issue-391: codedb_callers tool exists" {
    // codedb_callers is the proposed reverse-callgraph tool: given a symbol
    // name, return the call sites across the index. It fuses the existing
    // word index with outline scopes, replacing the multi-step
    // "codedb_word → eyeball → codedb_outline per file" workflow.
    //
    // The minimum surface contract: the Tool enum exposes a codedb_callers
    // variant so dispatch can route to it. Today it does not, so the
    // workflow has to be assembled by hand on the client side.
    try testing.expect(@hasField(mcp_mod.Tool, "codedb_callers"));
}

test "issue-391: codedb_callers returns call sites with scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");
    try explorer.indexFile("b.zig", "pub fn callerB() void {\n    fooBar();\n}\n");

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "2 call sites for 'fooBar'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "b.zig:2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "callerA") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "callerB") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "def.zig:1") == null);
}

test "codedb_status reports ignore patterns and built-in skip dirs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const patterns = [_][]const u8{ "secrets/", "*.pem" };
    try explorer.setIgnorePatterns(&patterns);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_status, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "ignore_patterns: 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "secrets/") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "*.pem") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "built_in_skip_dirs:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "node_modules") != null);
}

test "codedb_hierarchy reports bases and direct derived types" {
    try testing.expect(@hasField(mcp_mod.Tool, "codedb_hierarchy"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("Controllers/BaseController.cs",
        \\public class BaseController {
        \\}
    );
    try explorer.indexFile("Controllers/AccountsController.cs",
        \\public class AccountsController : BaseController, IAccountsController {
        \\}
    );
    try explorer.indexFile("Controllers/SpecialAccountsController.cs",
        \\public class SpecialAccountsController : AccountsController {
        \\}
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"AccountsController\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_hierarchy, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "hierarchy for 'AccountsController'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "BaseController") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "IAccountsController") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "SpecialAccountsController") != null);
}

test "codedb_ls and codedb_outline annotate stub-like files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("src/StubController.cs",
        \\public class StubController {
        \\    public IActionResult Index() { return View(); }
        \\}
    );

    const ls_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src\"}", .{});
    defer ls_parsed.deinit();
    var ls_out: std.ArrayList(u8) = .empty;
    defer ls_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &ls_parsed.value.object, &ls_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, ls_out.items, "StubController.cs") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out.items, "[stub]") != null);

    const outline_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/StubController.cs\"}", .{});
    defer outline_parsed.deinit();
    var outline_out: std.ArrayList(u8) = .empty;
    defer outline_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &outline_parsed.value.object, &outline_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, outline_out.items, "src/StubController.cs") != null);
    try testing.expect(std.mem.indexOf(u8, outline_out.items, "[stub]") != null);
}

test "codedb_outline grouped sections symbols by kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("src/grouped.ts",
        \\import { thing } from './thing';
        \\export const VALUE = 1;
        \\export function alpha() { return VALUE; }
        \\export function beta() { return thing(); }
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/grouped.ts\",\"grouped\":true}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "[function]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "symbols") != null);
}

test "codedb_symbol filters and prints decorators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("Controllers/HomeController.cs",
        \\public class HomeController {
        \\    [HttpPost]
        \\    public IActionResult Save() { return View(); }
        \\    [HttpGet]
        \\    public IActionResult SaveDraft() { return View(); }
        \\}
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Save\",\"decorator_filter\":\"HttpPost\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "1 results for 'Save'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "decorators: [HttpPost]") != null);
}

test "codedb_routes extracts ASP.NET controller action routes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("Controllers/AccountsController.cs",
        \\[Authorize]
        \\[Route("api/[controller]")]
        \\public class AccountsController {
        \\    [HttpGet("{id}")]
        \\    public IActionResult Details(int id) { return View(); }
        \\    [HttpPost("save")]
        \\    [ValidateAntiForgeryToken]
        \\    public IActionResult Save() { return View(); }
        \\    [HttpPost("unsafe")]
        \\    public IActionResult Unsafe() { return View(); }
        \\}
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"framework\":\"aspnet\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_routes, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "GET /api/Accounts/{id} -> AccountsController.Details") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "POST /api/Accounts/save -> AccountsController.Save") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[authorize]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[antiforgery]") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Unsafe") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "[missing_antiforgery]") != null);
}

test "codedb_config_xref compares appsettings keys to IConfiguration reads" {
    try testing.expect(@hasField(mcp_mod.Tool, "codedb_config_xref"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("appsettings.json",
        \\{
        \\  "ConnectionStrings": {
        \\    "Default": "Server=."
        \\  },
        \\  "FeatureFlags": {
        \\    "Enabled": true,
        \\    "Unused": false
        \\  }
        \\}
    );
    try explorer.indexFile("Services/OptionsReader.cs",
        \\public class OptionsReader {
        \\    public OptionsReader(IConfiguration configuration) {
        \\        var cs = configuration["ConnectionStrings:Default"];
        \\        var enabled = configuration.GetValue<bool>("FeatureFlags:Enabled");
        \\        var missing = configuration.GetSection("Missing:Key");
        \\    }
        \\}
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"framework\":\"aspnet\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_config_xref, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "ASP.NET config xref") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "ConnectionStrings:Default") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "FeatureFlags:Enabled") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "FeatureFlags:Unused") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Missing:Key") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "Services/OptionsReader.cs:3") != null);
}

// test "codedb ls outline and tree include deterministic descriptors" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var explorer = Explorer.init(arena.allocator());
//     var store = Store.init(testing.allocator);
//     defer store.deinit();
//     var agents = AgentRegistry.init(testing.allocator);
//     defer agents.deinit();
//     _ = try agents.register("__filesystem__");
//     var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
//     defer bench_ctx.deinit();
//
//     try explorer.indexFile("Controllers/AccountsController.cs",
//         \\[Authorize]
//         \\[Route("api/[controller]")]
//         \\public class AccountsController : BaseController {
//         \\    [HttpGet("{id}")]
//         \\    public IActionResult Details(int id) { return View(); }
//         \\    [HttpPost("save")]
//         \\    public IActionResult Save() { return View(); }
//         \\}
//     );
//
//     const ls_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"Controllers\"}", .{});
//     defer ls_parsed.deinit();
//     var ls_out: std.ArrayList(u8) = .empty;
//     defer ls_out.deinit(testing.allocator);
//     bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &ls_parsed.value.object, &ls_out, &store, &explorer, &agents);
//     try testing.expect(std.mem.indexOf(u8, ls_out.items, "— class_def AccountsController extends BaseController") != null);
//     try testing.expect(std.mem.indexOf(u8, ls_out.items, "2 routes, 1 POST") != null);
//     try testing.expect(std.mem.indexOf(u8, ls_out.items, "authorized") != null);
//
//     const outline_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"Controllers/AccountsController.cs\"}", .{});
//     defer outline_parsed.deinit();
//     var outline_out: std.ArrayList(u8) = .empty;
//     defer outline_out.deinit(testing.allocator);
//     bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &outline_parsed.value.object, &outline_out, &store, &explorer, &agents);
//     try testing.expect(std.mem.indexOf(u8, outline_out.items, "— class_def AccountsController extends BaseController") != null);
//
//     const tree_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
//     defer tree_parsed.deinit();
//     var tree_out: std.ArrayList(u8) = .empty;
//     defer tree_out.deinit(testing.allocator);
//     bench_ctx.runDispatch(io, testing.allocator, .codedb_tree, &tree_parsed.value.object, &tree_out, &store, &explorer, &agents);
//     try testing.expect(std.mem.indexOf(u8, tree_out.items, "— class_def AccountsController extends BaseController") != null);
//
//     const no_desc_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"Controllers\",\"no_descriptor\":true}", .{});
//     defer no_desc_parsed.deinit();
//     var no_desc_out: std.ArrayList(u8) = .empty;
//     defer no_desc_out.deinit(testing.allocator);
//     bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &no_desc_parsed.value.object, &no_desc_out, &store, &explorer, &agents);
//     try testing.expect(std.mem.indexOf(u8, no_desc_out.items, "— class_def") == null);
// }

test "issue-391: codedb_callers rejects missing name" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "name") != null);
}

test "issue-441: bundle rejects codedb_projects sub-op" {
    // codedb_projects lists every indexed project on the machine, which is a
    // global directory enumeration unrelated to whatever repo the agent is
    // working on. When a planner sees a previous bundle that called
    // codedb_projects, it tends to replay the same shape — re-emitting 5x
    // codedb_projects ops as if that were the canonical "what do I do here"
    // call. Block it at the dispatcher, mirroring the existing rejections of
    // codedb_bundle (recursive) and codedb_edit (write op).
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":"codedb_projects","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // The op must be rejected with an explicit error, not silently dispatched.
    try testing.expect(std.mem.indexOf(u8, out.items, "error: codedb_projects not allowed in bundle") != null);
}

test "issue-441: codedb_projects branch is excluded from augmented oneOf" {
    // Mirror of the dispatcher rejection at the schema level — when the
    // discriminated oneOf is opted into via CODEDB_DISCRIMINATED_SCHEMA=1,
    // there must not be a oneOf branch advertising codedb_projects as a
    // valid sub-tool, since the bundle dispatcher rejects it at runtime.
    const augmented = try mcp_mod.buildAugmentedToolsList(testing.allocator);
    defer testing.allocator.free(augmented);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, augmented, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_items: ?std.json.Value = null;
    for (tools.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "codedb_bundle")) {
            bundle_items = t.object.get("inputSchema").?.object.get("properties").?.object.get("ops").?.object.get("items").?;
            break;
        }
    }
    const one_of = bundle_items.?.object.get("oneOf").?.array;

    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const") orelse continue;
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_projects"));
    }
}

test "issue-443: codedb_bundle is omitted from default tools/list response" {
    // The codedb_bundle tool has been a footgun across multiple stages:
    //   #434 — schema permitted empty arguments (Stage 1 fix: required arguments)
    //   #437 — Stage 2 oneOf augmentation broke OpenAI strict-mode (#440 hotfix)
    //   #441 — codedb_projects sub-op replay loop in planners
    // Even with all of the above, OpenAI clients still emit
    // {"tool":"codedb_*","arguments":{}} because the default schema's
    // arguments field is a bare {type:"object"} with no inner shape, and
    // the discriminated oneOf is opt-in only.
    //
    // Disable codedb_bundle entirely until the schema can be reworked to
    // bind sub-tool arguments inline (no `arguments` wrapper), removing
    // the empty-args footgun structurally. The dispatcher-side handler
    // stays so clients with cached schemas don't crash, but the runtime
    // tools/list response no longer advertises it. CODEDB_BUNDLE_ENABLED=1
    // re-enables advertisement for callers that want to re-engage it.
    const response = try mcp_mod.buildToolsListResponse(testing.allocator, .{
        .bundle_enabled = false,
        .discriminated_opt_in = false,
    });
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        try testing.expect(!std.mem.eql(u8, name, "codedb_bundle"));
    }

    // Sanity: legitimate tools still advertised.
    var saw_search = false;
    var saw_outline = false;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_search")) saw_search = true;
        if (std.mem.eql(u8, name, "codedb_outline")) saw_outline = true;
    }
    try testing.expect(saw_search);
    try testing.expect(saw_outline);
}

test "issue-443: codedb_bundle is advertised when CODEDB_BUNDLE_ENABLED=1" {
    // Re-enable path. When bundle_enabled is true the runtime response
    // includes codedb_bundle, exactly as it did before this gate.
    const response = try mcp_mod.buildToolsListResponse(testing.allocator, .{
        .bundle_enabled = true,
        .discriminated_opt_in = false,
    });
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var saw_bundle = false;
    for (tools.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "codedb_bundle")) saw_bundle = true;
    }
    try testing.expect(saw_bundle);
}

test "issue-434: codedb_bundle ops items schema requires arguments field" {
    // The codedb_bundle inputSchema in tools_list advertises ops items as
    // {required: ["tool"]} with arguments as a bare {type: "object"} that
    // permits {}. Function-calling LLMs read the schema as authoritative and
    // emit the minimum-valid payload — {tool: "...", arguments: {}} — which
    // misroutes through the inline-args fallback and surfaces as
    // "received keys: [tool, arguments]" from each sub-tool. Stage 1 fix:
    // add "arguments" to the items.required array so models are forced to
    // populate it. (Stage 2 — discriminated oneOf over tool — is a follow-up.)
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, mcp_mod.tools_list, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_schema: ?std.json.Value = null;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_bundle")) {
            bundle_schema = t.object.get("inputSchema").?;
            break;
        }
    }
    try testing.expect(bundle_schema != null);

    const ops = bundle_schema.?.object.get("properties").?.object.get("ops").?;
    const items = ops.object.get("items").?;
    const required = items.object.get("required").?.array;

    var has_tool = false;
    var has_arguments = false;
    for (required.items) |r| {
        if (std.mem.eql(u8, r.string, "tool")) has_tool = true;
        if (std.mem.eql(u8, r.string, "arguments")) has_arguments = true;
    }
    try testing.expect(has_tool);
    try testing.expect(has_arguments);
}

test "issue-437: codedb_bundle ops items schema has discriminated oneOf per sub-tool" {
    // Stage 2 of the bundle-schema fix. Stage 1 (#434) made `arguments`
    // required but left it as a bare {type: "object"} — so a schema-greedy
    // model can still emit `arguments: {}` to satisfy the required check
    // without populating real keys. Stage 2 binds the *contents* of
    // arguments to each sub-tool's actual inputSchema via a discriminated
    // oneOf on `tool` (const) → `arguments` (sub-tool inputSchema).
    //
    // The augmented schema is built at runtime from the per-sub-tool
    // schemas already advertised in tools_list, so there is no
    // hand-maintained duplication.
    const augmented = try mcp_mod.buildAugmentedToolsList(testing.allocator);
    defer testing.allocator.free(augmented);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, augmented, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_items: ?std.json.Value = null;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_bundle")) {
            bundle_items = t.object.get("inputSchema").?.object.get("properties").?.object.get("ops").?.object.get("items").?;
            break;
        }
    }
    try testing.expect(bundle_items != null);

    // `oneOf` array must exist on items.
    const one_of_val = bundle_items.?.object.get("oneOf");
    try testing.expect(one_of_val != null);
    const one_of = one_of_val.?.array;

    // Must have at least one branch per dispatchable codedb_* sub-tool.
    // codedb_bundle (recursive) and codedb_edit (write op) are explicitly
    // rejected by handleBundle, so they are excluded.
    try testing.expect(one_of.items.len >= 10);

    // Find the codedb_outline branch and verify it pins tool to a const
    // and binds arguments to a populated schema (with `path` property).
    var found_outline = false;
    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const");
        if (tool_const == null) continue;
        if (!std.mem.eql(u8, tool_const.?.string, "codedb_outline")) continue;
        found_outline = true;

        const args_schema = props.get("arguments").?;
        const args_props = args_schema.object.get("properties").?.object;
        try testing.expect(args_props.get("path") != null);
        // codedb_outline requires `path` — preserved by the augmentation.
        const args_required = args_schema.object.get("required").?.array;
        var path_required = false;
        for (args_required.items) |r| {
            if (std.mem.eql(u8, r.string, "path")) path_required = true;
        }
        try testing.expect(path_required);
        break;
    }
    try testing.expect(found_outline);

    // No branch should be for the recursive codedb_bundle or the write-op codedb_edit.
    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const") orelse continue;
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_bundle"));
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_edit"));
    }
}

test "issue-425: codedb_callers excludes substring matches in unrelated identifiers" {
    // handleCallers (mcp.zig:1339) currently calls searchContentWithScope(name)
    // which is a *substring* full-text search. The only de-dup it performs is
    // dropping lines that match the canonical definition of `name` itself.
    // That means a search for "fooBar" returns lines mentioning the unrelated
    // identifier "fooBarExtended" — both its definition site and any reference
    // — as if they were call sites. The fix is a whole-word check on the hit
    // line so substring matches in longer identifiers are excluded.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    // A different symbol whose name contains "fooBar" as a substring.
    try explorer.indexFile("other.zig", "pub fn fooBarExtended() void {}\n");
    // A genuine call site.
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Real call site must still appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    // Substring-only matches in unrelated identifiers must NOT.
    try testing.expect(std.mem.indexOf(u8, out.items, "other.zig") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "fooBarExtended") == null);
    // Header reports the real count (1), not the inflated count (2).
    try testing.expect(std.mem.indexOf(u8, out.items, "1 call sites for 'fooBar'") != null);
}

test "issue-426: codedb_callers excludes non-code files (markdown, docs)" {
    // handleCallers (mcp.zig:1339) feeds searchContentWithScope across every
    // indexed file regardless of language. Markdown and other documentation
    // files that mention the symbol in prose surface as if they were call
    // sites. The fix is a language gate: skip results from non-code files.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    try explorer.indexFile("def.zig", "pub fn fooBar() void {}\n");
    try explorer.indexFile("a.zig", "pub fn callerA() void {\n    fooBar();\n}\n");
    // Prose mention in a docs file — the identifier appears as a whole
    // word, so this is independent of the substring-match bug (#425):
    // even a perfect whole-word match on a markdown file is still not a
    // call site.
    try explorer.indexFile(
        "docs/notes.md",
        "# Notes\n\nThe fooBar helper is documented here for posterity.\n",
    );

    const args_json =
        \\{"name":"fooBar"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Real call site present.
    try testing.expect(std.mem.indexOf(u8, out.items, "a.zig:2") != null);
    // Markdown mention must NOT appear as a call site.
    try testing.expect(std.mem.indexOf(u8, out.items, "docs/notes.md") == null);
    // Header reflects the real count.
    try testing.expect(std.mem.indexOf(u8, out.items, "1 call sites for 'fooBar'") != null);
}

test "csharp: single or initialized field defers to single-field path" {
    var buf: [csharp_parser.max_field_names][]const u8 = undefined;
    // Single declarator — extractFieldName handles it, multi returns 0.
    try testing.expectEqual(@as(usize, 0), csharp_parser.extractFieldNames("private int a;", &buf));
    // Initializer lists stay conservative — bail to the single-field path.
    try testing.expectEqual(@as(usize, 0), csharp_parser.extractFieldNames("private int a = 1, b = 2;", &buf));
    // Non-field line.
    try testing.expectEqual(@as(usize, 0), csharp_parser.extractFieldNames("DoWork(a, b, c);", &buf));
}
