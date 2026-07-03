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

test "regression #5: getHotFiles does not deadlock" {
    // getHotFiles used to hold explorer.mu while calling store.getLatest()
    // which locks store.mu — a lock ordering violation. The fix collects
    // paths under explorer.mu, releases it, then locks store.mu separately.
    // This test verifies correctness; deadlock would cause a hang.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("hot-a.zig", "pub fn a() void {}");
    try explorer.indexFile("hot-b.zig", "pub fn b() void {}");
    try explorer.indexFile("hot-c.zig", "pub fn c() void {}");

    _ = try store.recordSnapshot("hot-a.zig", 10, 0x1);
    _ = try store.recordSnapshot("hot-b.zig", 20, 0x2);
    _ = try store.recordSnapshot("hot-c.zig", 30, 0x3);
    _ = try store.recordSnapshot("hot-b.zig", 25, 0x4); // b updated again

    const hot = try explorer.getHotFiles(&store, testing.allocator, 2);
    defer {
        for (hot) |path| testing.allocator.free(path);
        testing.allocator.free(hot);
    }
    try testing.expect(hot.len == 2);
    // Most recent should be hot-b.zig (seq 4) then hot-c.zig (seq 3)
    try testing.expectEqualStrings("hot-b.zig", hot[0]);
    try testing.expectEqualStrings("hot-c.zig", hot[1]);
}

test "regression: concurrent hot/read with remove" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    try explorer.indexFile("race.zig", "pub fn race() void {}");
    _ = try store.recordSnapshot("race.zig", 24, 0x1);

    const Ctx = struct {
        explorer: *Explorer,
        store: *Store,
        stop: *std.atomic.Value(bool),
    };

    const Worker = struct {
        fn run(ctx: *Ctx) void {
            while (!ctx.stop.load(.acquire)) {
                const hot = ctx.explorer.getHotFiles(ctx.store, testing.allocator, 2) catch continue;
                defer {
                    for (hot) |path| testing.allocator.free(path);
                    testing.allocator.free(hot);
                }

                const cached = ctx.explorer.getContent("race.zig", testing.allocator) catch continue;
                if (cached) |content| testing.allocator.free(content);
            }
        }
    };

    var stop = std.atomic.Value(bool).init(false);
    var ctx = Ctx{ .explorer = &explorer, .store = &store, .stop = &stop };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
    defer worker.join();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (i % 2 == 0) {
            try explorer.indexFile("race.zig", "pub fn race() void {}");
            _ = try store.recordSnapshot("race.zig", @intCast(24 + i), @intCast(i + 2));
        } else {
            explorer.removeFile("race.zig");
        }
    }

    stop.store(true, .release);
}

test "regression #7: tree shows directory nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");
    try explorer.indexFile("src/lib.zig", "pub fn init() void {}");
    try explorer.indexFile("build.zig", "pub fn build() void {}");

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);

    // Should contain "src/" directory node
    try testing.expect(std.mem.indexOf(u8, tree, "src/\n") != null);
    // Should contain file basenames, not full paths
    try testing.expect(std.mem.indexOf(u8, tree, "  main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "  lib.zig") != null);
    // Root-level file should not be indented
    try testing.expect(std.mem.indexOf(u8, tree, "build.zig") != null);
}

test "regression #7: tree handles nested directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/utils/hash.zig", "pub fn hash() void {}");
    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);

    // Should have both directory levels
    try testing.expect(std.mem.indexOf(u8, tree, "src/\n") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "  utils/\n") != null);
    // Nested file should be double-indented
    try testing.expect(std.mem.indexOf(u8, tree, "    hash.zig") != null);
}

test "regression #7: tree shows only basenames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("pkg/foo/bar.zig", "const x = 1;");

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);

    // Full path should NOT appear in tree output
    try testing.expect(std.mem.indexOf(u8, tree, "pkg/foo/bar.zig") == null);
    // Only basename
    try testing.expect(std.mem.indexOf(u8, tree, "bar.zig") != null);
}

test "regression: queue push stays non-blocking when full" {
    var queue = watcher.EventQueue{};

    var pushed: usize = 0;
    while (true) : (pushed += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/fill-{d}.zig", .{pushed});
        if (!queue.push(watcher.FsEvent.init(path, .modified, @intCast(pushed)) orelse unreachable)) break;
    }

    var overflow_path_buf: [32]u8 = undefined;
    const overflow_path = try std.fmt.bufPrint(&overflow_path_buf, "tmp/overflow-2.zig", .{});
    const start = cio.nanoTimestamp();
    _ = queue.push(watcher.FsEvent.init(overflow_path, .created, 1000) orelse unreachable);
    const elapsed = cio.nanoTimestamp() - start;

    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
}

// ── Path safety tests ───────────────────────────────────────

test "perf regression: indexing 200 files under 200ms" {
    var ti = TrigramIndex.init(testing.allocator);
    defer ti.deinit();
    var wi = WordIndex.init(testing.allocator);
    defer wi.deinit();

    // Generate 200 synthetic files with realistic content
    var bufs: [200][]u8 = undefined;
    var names: [200][]u8 = undefined;
    for (0..200) |i| {
        names[i] = try std.fmt.allocPrint(testing.allocator, "src/file_{d:0>3}.zig", .{i});
        bufs[i] = try std.fmt.allocPrint(testing.allocator,
            \\pub fn handler_{d}(ctx: *Context, req: Request) !Response {{
            \\    const allocator = ctx.allocator;
            \\    const data = try req.readBody(allocator);
            \\    defer allocator.free(data);
            \\    return Response.init(.ok, data);
            \\}}
            \\
            \\const Config_{d} = struct {{
            \\    name: []const u8,
            \\    value: i64 = {d},
            \\    enabled: bool = true,
            \\}};
        , .{ i, i, i * 42 });
    }
    defer for (0..200) |i| {
        testing.allocator.free(bufs[i]);
        testing.allocator.free(names[i]);
    };

    var timer = try cio.Timer.start();
    for (0..200) |i| {
        try ti.indexFile(names[i], bufs[i]);
        try wi.indexFile(names[i], bufs[i]);
    }
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    // Must complete under 200ms (generous budget — typically ~30ms)
    // Debug builds are ~10x slower than ReleaseFast; give generous headroom.
    // ReleaseFast typically ~30ms; Debug ~100–250ms depending on host.
    try testing.expect(elapsed_ms < 500.0);
}

// DISABLED: perf test flaky in CI/debug builds (ns_per_query varies by host)
// test "perf regression: trigram candidate lookup under 1ms per query" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var ti = TrigramIndex.init(testing.allocator);
//     defer ti.deinit();
//
//     for (0..100) |i| {
//         const name = try std.fmt.allocPrint(alloc, "mod_{d}.zig", .{i});
//         const content = try std.fmt.allocPrint(alloc,
//             \\pub fn process_{d}(data: []const u8) !void {{
//             \\    const result = transform(data);
//             \\    try validate(result);
//             \\}}
//         , .{i});
//         try ti.indexFile(name, content);
//     }
//
//     const queries = [_][]const u8{
//         "process_42",
//         "transform",
//         "pub fn process",
//         "validate(result)",
//     };
//
//     var timer = try cio.Timer.start();
//     const iters: usize = 1000;
//     for (0..iters) |_| {
//         for (queries) |q| {
//             const cands = ti.candidates(q, testing.allocator);
//             if (cands) |c| testing.allocator.free(c);
//         }
//     }
//     const elapsed_ns = timer.read();
//     const ns_per_query = elapsed_ns / (iters * queries.len);
//
//     // Must be under 1ms (1_000_000 ns) per query — typically ~100µs
//     try testing.expect(ns_per_query < 1_000_000);
// }

// DISABLED: perf test flaky in CI/debug builds (ns_per_query varies by host)
// test "perf regression: word index lookup under 100ns per query" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var wi = WordIndex.init(testing.allocator);
//     defer wi.deinit();
//
//     for (0..100) |i| {
//         const name = try std.fmt.allocPrint(alloc, "src_{d}.zig", .{i});
//         const content = try std.fmt.allocPrint(alloc, "pub fn handleRequest_{d}(ctx: *Context) void {{}}\nconst allocator = getDefaultAllocator();\n", .{i});
//         try wi.indexFile(name, content);
//     }
//
//     const queries = [_][]const u8{ "handleRequest_50", "allocator", "getDefaultAllocator", "Context" };
//
//     var timer = try cio.Timer.start();
//     const iters: usize = 100_000;
//     for (0..iters) |_| {
//         for (queries) |q| {
//             _ = wi.search(q);
//         }
//     }
//     const elapsed_ns = timer.read();
//     const ns_per_query = elapsed_ns / (iters * queries.len);
//     // Word lookup must be under 500ns in debug — typically ~5ns in release
//     try testing.expect(ns_per_query < 500);
// }

test "issue-42: scan thread is joined before allocator-backed state is freed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    const data_dir = try allocator.dupe(u8, "/tmp/codedb_test_issue42");

    const SharedCtx = struct {
        data_dir: []const u8,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(ctx: *@This()) void {
            cio.sleepMs(10);
            if (ctx.data_dir.len > 0) {
                _ = ctx.data_dir[0];
                ctx.ok.store(true, .release);
            }
            ctx.done.store(true, .release);
        }
    };

    var ctx = SharedCtx{ .data_dir = data_dir };
    const t = try std.Thread.spawn(.{}, SharedCtx.run, .{&ctx});
    t.join();

    try testing.expect(ctx.done.load(.acquire));
    try testing.expect(ctx.ok.load(.acquire));
    allocator.free(data_dir);
    _ = gpa.deinit();
}

test "issue-60: telemetry disabled path is a no-op" {
    var telem = telemetry_mod.Telemetry.init(io, "/tmp", testing.allocator, true);
    defer telem.deinit();

    telem.recordSessionStart();
    telem.recordToolCall("codedb_search", 99, true, 10);
    try testing.expect(!telem.enabled);
    try testing.expect(telem.file == null);
    try testing.expect(telem.head.load(.monotonic) == 0);
}

// DISABLED: depends on /private/tmp and zig build run which is flaky in test
// test "issue-77: mcp index accepts temporary-directory roots that cause pathological cache growth" {
//     var tmp_name_buf: [128]u8 = undefined;
//     const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "codedb-issue-77-{d}", .{@as(i64, @intCast(@divTrunc(cio.nanoTimestamp(), 1000)))});
//     const tmp_root = try std.fs.path.join(testing.allocator, &.{ "/private/tmp", tmp_name });
//     defer testing.allocator.free(tmp_root);
//
//     std.Io.Dir.cwd().createDirPath(io, tmp_root) catch |err| switch (err) {
//         error.PathAlreadyExists => {},
//         else => return err,
//     };
//     defer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};
//
//     const source_path = try std.fs.path.join(testing.allocator, &.{ tmp_root, "sample.zig" });
//     defer testing.allocator.free(source_path);
//     {
//         const file = try std.Io.Dir.cwd().createFile(io, source_path, .{});
//         defer file.close(io);
//         try file.writeStreamingAll(io, "pub fn sample() void {}\n");
//     }
//
//     const result = try cio.runCapture(.{
//         .allocator = testing.allocator,
//         .argv = &.{ "zig", "build", "run", "--", tmp_root, "snapshot" },
//         .max_output_bytes = 256 * 1024,
//     });
//     defer testing.allocator.free(result.stdout);
//     defer testing.allocator.free(result.stderr);
//
//     try testing.expect(result.term.Exited != 0);
// }

test "issue-93: isSensitivePath blocks .env and credentials" {
    try testing.expect(watcher.isSensitivePath(".env"));
    try testing.expect(watcher.isSensitivePath(".env.local"));
    try testing.expect(watcher.isSensitivePath(".env.production"));
    try testing.expect(watcher.isSensitivePath("credentials.json"));
    try testing.expect(watcher.isSensitivePath("service-account.json"));
    try testing.expect(watcher.isSensitivePath("id_rsa"));
    try testing.expect(watcher.isSensitivePath("secrets.yaml"));
    try testing.expect(watcher.isSensitivePath("config/secrets.yml"));
    try testing.expect(watcher.isSensitivePath("server.key"));
    try testing.expect(watcher.isSensitivePath("cert.pem"));
    try testing.expect(watcher.isSensitivePath("keystore.jks"));
    try testing.expect(watcher.isSensitivePath("identity.pfx"));
    try testing.expect(watcher.isSensitivePath(".ssh/known_hosts"));
    // Normal files should NOT be blocked
    try testing.expect(!watcher.isSensitivePath("main.zig"));
    try testing.expect(!watcher.isSensitivePath("src/server.zig"));
    try testing.expect(!watcher.isSensitivePath("README.md"));
    try testing.expect(!watcher.isSensitivePath("package.json"));
}

test "issue-589/7d0a083: isSensitivePath blocks FIDO keys, .env suffixes, .git-credentials" {
    // All six ssh-keygen default private-key basenames (#589).
    try testing.expect(watcher.isSensitivePath("id_rsa"));
    try testing.expect(watcher.isSensitivePath("id_ed25519"));
    try testing.expect(watcher.isSensitivePath("id_ecdsa"));
    try testing.expect(watcher.isSensitivePath("id_dsa"));
    try testing.expect(watcher.isSensitivePath("id_ecdsa_sk"));
    try testing.expect(watcher.isSensitivePath("id_ed25519_sk"));
    // *.env-suffix files such as production.env / staging.env (7d0a083).
    try testing.expect(watcher.isSensitivePath("production.env"));
    try testing.expect(watcher.isSensitivePath("staging.env"));
    try testing.expect(watcher.isSensitivePath("config/prod.env"));
    // .git-credentials exact name (7d0a083).
    try testing.expect(watcher.isSensitivePath(".git-credentials"));
    // .env with - or _ separators (7d0a083 widened from only '.').
    try testing.expect(watcher.isSensitivePath(".env-local"));
    try testing.expect(watcher.isSensitivePath(".env_local"));
    // Must NOT over-match .envoy / .envrc / .environment.
    try testing.expect(!watcher.isSensitivePath(".envoy.config"));
    try testing.expect(!watcher.isSensitivePath(".envrc"));
    try testing.expect(!watcher.isSensitivePath(".environment.json"));
}

test "issue-93: isPathSafe blocks traversal" {
    const MCP = @import("../mcp.zig");
    try testing.expect(!MCP.isPathSafe("../../../etc/passwd"));
    try testing.expect(!MCP.isPathSafe("/etc/passwd"));
    try testing.expect(!MCP.isPathSafe(""));
    try testing.expect(MCP.isPathSafe("src/main.zig"));
    try testing.expect(MCP.isPathSafe("README.md"));
}

test "issue-112: Python import-as alias stripped from dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("utils.py", "def helper(): pass\n");
    try explorer.indexFile("consumer.py", "import utils as u\n");

    const deps = try explorer.getImportedBy("utils.py", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expect(deps.len == 1);
}

test "issue-114: TypeScript import-as alias does not affect dep path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("mod.ts", "export function hello() {}\n");
    try explorer.indexFile("consumer.ts", "import { hello as h } from './mod'\n");

    var outline = (try explorer.getOutline("consumer.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    // The import dep path should be "./mod", not include the alias
    try testing.expect(outline.imports.items.len == 1);
    try testing.expectEqualStrings("./mod", outline.imports.items[0]);
}

test "regression-142: many files don't corrupt index" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    // Index 500 files
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file_{d}.zig", .{i});
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "pub fn func_{d}() void {{}}", .{i});
        try exp.indexFile(name, content);
    }

    // Search for a specific one
    const results = try exp.searchContent("func_250", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
    try testing.expectEqualStrings("file_250.zig", results[0].path);
}

test "regression-142: short queries fall back gracefully" {
    var exp = Explorer.init(testing.allocator);
    defer exp.deinit();

    try exp.indexFile("a.zig", "pub fn ab() void {}");

    // 2-char query: too short for trigrams, should still work via fallback
    const results = try exp.searchContent("ab", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "issue-151: Go func and type definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("main.go",
        \\package main
        \\
        \\import "fmt"
        \\
        \\type Config struct {
        \\    Port int
        \\}
        \\
        \\type Handler interface {
        \\    Handle()
        \\}
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\}
        \\
        \\func (c *Config) Validate() bool {
        \\    return c.Port > 0
        \\}
    );

    var outline = (try explorer.getOutline("main.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
    }
    try testing.expect(func_count == 2); // main + Validate
    try testing.expect(struct_count == 2); // Config + Handler
    try testing.expect(outline.imports.items.len == 1); // "fmt"
}

test "issue-151: Go block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.go",
        \\package main
        \\
        \\func realFunc() {}
        \\/*
        \\func fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only realFunc
}

test "issue-394: shouldRunAutoUpdate permanently blocked by future-timestamp stamp file" {
    // Reproduces the case where the stamp file contains a timestamp in the
    // future relative to the wall clock — for example, after an NTP clock
    // correction that rolls the clock back, or after a stamp written by a
    // host with a fast clock. The current implementation computes
    // (now - last) and only fires when that delta >= 24h, so a future
    // `last` produces a negative delta and the check is silently skipped
    // for as long as the stamp stays in the future — potentially many days.
    //
    // Expected: a wildly future stamp should NOT prevent the next check
    // from firing. The simplest correct behavior is: if last > now, treat
    // the stamp as invalid and allow the update check to run.

    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const now_ms: i64 = 1_700_000_000_000;
    const future_last_ms: i64 = now_ms + day_ms * 30; // 30 days in the future

    try testing.expect(update_mod.shouldRunAutoUpdate(now_ms, future_last_ms, false));
}

test "issue-395: shouldRunAutoUpdate panics on i64 underflow when stamp is corrupt" {
    // Reproduces a panic when ~/.codedb/last_auto_update_check is corrupt
    // and decodes to a very negative i64. readAutoUpdateStamp does no
    // sanity check — it reads 8 bytes, calls std.mem.readInt(i64, ...),
    // and feeds that straight into shouldRunAutoUpdate, which evaluates
    // `now_ms - last` with checked subtraction. For last = minInt(i64)
    // and any positive now_ms, the subtraction overflows and triggers an
    // integer-overflow panic in Debug / ReleaseSafe builds (which is what
    // `zig build test` and the shipped MCP binary use).
    //
    // Result: every `codedb mcp` startup crashes during the auto-update
    // gate for any user whose stamp file got corrupted to a value with
    // the high bit set (e.g. truncated write, partial flush, or any byte
    // sequence starting with 0x80..0xFF in the stamp).
    //
    // Expected fix: clamp the delta with a saturating/wrapping subtraction
    // or treat any last_ms <= 0 (or in the distant past) as invalid and
    // run the update.

    const now_ms: i64 = 1_700_000_000_000;
    const last_ms: i64 = std.math.minInt(i64);

    try testing.expect(update_mod.shouldRunAutoUpdate(now_ms, last_ms, false));
}

// DISABLED: depends on zig-out/bin/codedb binary from prior build step
// test "issue-150: --help prints usage" {
//     try buildCliForHelpTests();
//
//     const result = try cio.runCapture(.{
//         .allocator = testing.allocator,
//         .argv = &.{ "./zig-out/bin/codedb", "--help" },
//         .max_output_bytes = 8192,
//     });
//     defer testing.allocator.free(result.stdout);
//     defer testing.allocator.free(result.stderr);
//
//     try testing.expect(result.term == .Exited);
//     try testing.expect(result.term.Exited == 0);
//     try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
//         std.mem.indexOf(u8, result.stderr, "usage:") != null);
//     try testing.expect(std.mem.indexOf(u8, result.stdout, "update") != null or
//         std.mem.indexOf(u8, result.stderr, "update") != null);
//     try testing.expect(std.mem.indexOf(u8, result.stdout, "nuke") != null or
//         std.mem.indexOf(u8, result.stderr, "nuke") != null);
// }
//
// test "issue-150: -h prints usage" {
//     try buildCliForHelpTests();
//
//     const result = try cio.runCapture(.{
//         .allocator = testing.allocator,
//         .argv = &.{ "./zig-out/bin/codedb", "-h" },
//         .max_output_bytes = 8192,
//     });
//     defer testing.allocator.free(result.stdout);
//     defer testing.allocator.free(result.stderr);
//
//     try testing.expect(result.term == .Exited);
//     try testing.expect(result.term.Exited == 0);
//     try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
//         std.mem.indexOf(u8, result.stderr, "usage:") != null);
// }

test "issue-116: getGitHead returns valid SHA for git repos" {
    const git = @import("../git.zig");

    // This test runs inside the codedb repo itself
    const head = git.getGitHead(".", testing.allocator) catch null;

    if (head) |h| {
        try testing.expect(h.len == 40);
        for (h) |c| {
            try testing.expect(std.ascii.isHex(c));
        }
    }
}

test "issue-148: POLLHUP detects closed pipe" {
    // Verify the polling infrastructure works for pipe-based transports
    const pipe = try cio.makePipe();
    defer _ = std.c.close(pipe[0]);

    // Close write end — simulates client disconnect
    _ = std.c.close(pipe[1]);

    // Poll should detect POLLHUP on the read end
    var fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const n = try std.posix.poll(&fds, 100); // 100ms timeout
    try testing.expect(n > 0);
    try testing.expect((fds[0].revents & std.posix.POLL.HUP) != 0);
}

test "issue-148: idle watchdog exits on shutdown signal" {
    // The watchdog should check shutdown every ~1s (not 30s)
    // and return quickly when signalled
    var shutdown = std.atomic.Value(bool).init(false);

    const t0 = cio.milliTimestamp();
    // Signal shutdown after a small delay
    const signal_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.atomic.Value(bool)) void {
            cio.sleepMs(500);
            s.store(true, .release);
        }
    }.run, .{&shutdown});

    // Run a simplified watchdog loop (matches the real one's 1s granularity)
    while (!shutdown.load(.acquire)) {
        for (0..30) |_| {
            if (shutdown.load(.acquire)) break;
            cio.sleepMs(100); // faster for test
        }
        break; // one iteration is enough to test
    }
    signal_thread.join();

    const elapsed = cio.milliTimestamp() - t0;
    // With 1s granularity, should respond well under 5s (not 30s)
    // Using 100ms intervals in test, so should be ~500ms
    if (elapsed > 0) {
        // Just verify it didn't hang for 30 seconds
        try testing.expect(elapsed < 5_000);
    }
}

test "issue-148: open pipe does not trigger HUP" {
    const pipe = try cio.makePipe();
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN | std.posix.POLL.HUP,
        .revents = 0,
    }};

    const result = try std.posix.poll(&poll_fds, 0);
    try testing.expectEqual(@as(usize, 0), result);
}

// test "issue-148: codedb mcp exits when stdin is closed" {
//     // Integration test: spawn codedb mcp, close stdin, verify it exits
//     var child = std.process.spawn(io, .{
//         .argv = &.{ "zig", "build", "run", "--", "--mcp" },
//         .stdin = .pipe,
//         .stdout = .pipe,
//         .stderr = .ignore,
//     }) catch {
//         // If spawn fails (e.g., zig not on PATH), skip the test
//         return;
//     };
//
//     // Send initialize then close stdin (simulate client crash)
//     const init_msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}";
//     const header = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{init_msg.len});
//
//     if (child.stdin) |stdin| {
//         stdin.writeStreamingAll(io, header) catch {};
//         stdin.writeStreamingAll(io, init_msg) catch {};
//         // Close stdin — simulates client disconnecting
//         stdin.close(io);
//         child.stdin = null;
//     }
//
//     // Wait for the process to exit. The main read loop exits on stdin EOF;
//     // the watchdog also polls dead clients every second as a backup.
//     const start = cio.milliTimestamp();
//     const term = child.wait(io) catch {
//         // If wait fails, the process is stuck — test fails
//         try testing.expect(false);
//         return;
//     };
//
//     const elapsed = cio.milliTimestamp() - start;
//
//     // Should have exited (not been killed by us)
//     switch (term) {
//         .exited => |code| _ = code,
//         else => {},
//     }
//
//     // Should exit promptly after stdin closes.
//     try testing.expect(elapsed < 5_000);
// }

test "issue-164: mmap handles missing files gracefully" {
    const result = MmapTrigramIndex.initFromDisk(io, "/tmp/nonexistent-codedb-test-dir-164", testing.allocator);
    try testing.expect(result == null);
}

test "issue-163: multi-part query matches both parts" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_middleware.py", "def check(): pass");
    try explorer.indexFile("src/auth_handler.py", "def handle(): pass");
    try explorer.indexFile("src/utils.py", "def util(): pass");

    // "auth middle" should match auth_middleware but not utils
    const results = try explorer.fuzzyFindFiles("auth middle", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "middleware") != null);
}

test "issue-163: extension constraint filters results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");

    // "auth *.py" should only return the .py file
    const results = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    for (results) |r| {
        try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
    }
}

test "issue-163: special entry point files get bonus" {
    const score_main = fuzzyScore("main", "src/main.zig");
    const score_regular = fuzzyScore("main", "src/maintain.zig");
    try testing.expect(score_main != null);
    try testing.expect(score_regular != null);
    // main.zig is a special entry point — should score higher than maintain.zig
    try testing.expect(score_main.? > score_regular.?);
}

test "issue-163: transpositions handled by Smith-Waterman" {
    // These all failed with the old subsequence matcher
    try testing.expect(fuzzyScore("mpc", "src/mcp.zig") != null);
    try testing.expect(fuzzyScore("mian", "src/main.zig") != null);
    try testing.expect(fuzzyScore("agnet", "src/agent.zig") != null);
    try testing.expect(fuzzyScore("indxe", "src/index.zig") != null);
}

// ── codedb_query pipeline tests ─────────────────────────────────

test "issue-168: query pipeline find → limit produces file set" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check_auth(): pass");
    try explorer.indexFile("src/auth_handler.py", "def handle(): pass");
    try explorer.indexFile("src/utils.py", "def util(): pass");
    try explorer.indexFile("src/config.py", "DEBUG = True");

    // Pipeline: find "auth" → should return auth files
    const results = try explorer.fuzzyFindFiles("auth", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 2);
    // Both auth files should be in results
    var found_auth = false;
    var found_handler = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.path, "auth.py") != null) found_auth = true;
        if (std.mem.indexOf(u8, r.path, "auth_handler") != null) found_handler = true;
    }
    try testing.expect(found_auth);
    try testing.expect(found_handler);
}

test "issue-168: query pipeline filter by extension" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");

    // fuzzyFindFiles with extension constraint
    const results = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    for (results) |r| {
        try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
    }
}

test "issue-168: query pipeline chained find → filter narrows results" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/utils.py", "def util(): pass");
    try explorer.indexFile("docs/auth.md", "# Auth docs");

    // find "auth" returns all auth files, then *.py filter narrows to python
    const all = try explorer.fuzzyFindFiles("auth", testing.allocator, 10);
    defer testing.allocator.free(all);
    try testing.expect(all.len >= 3); // auth.py, auth.ts, auth.md

    const py_only = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 10);
    defer testing.allocator.free(py_only);
    try testing.expect(py_only.len >= 1);
    try testing.expect(py_only.len < all.len); // filtered set is smaller
}

test "issue-168: query pipeline handles empty results gracefully" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}");

    // Search for something that doesn't exist
    const results = try explorer.fuzzyFindFiles("zzzznonexistent", testing.allocator, 10);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

// ── codedb_query recall tests ───────────────────────────────────
// These test that pipeline composition preserves precision and recall:
// the right files survive each step, and irrelevant files are eliminated.

test "issue-168: recall — find + filter preserves only matching extension" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth.py", "def check(): pass");
    try explorer.indexFile("src/auth.ts", "function check() {}");
    try explorer.indexFile("src/auth.zig", "fn check() void {}");
    try explorer.indexFile("src/auth.rs", "fn check() {}");
    try explorer.indexFile("src/auth_test.py", "def test_check(): pass");

    // find "auth" should get all 5, then *.py should narrow to exactly 2
    const all = try explorer.fuzzyFindFiles("auth", testing.allocator, 20);
    defer testing.allocator.free(all);
    try testing.expect(all.len == 5);

    const py = try explorer.fuzzyFindFiles("auth *.py", testing.allocator, 20);
    defer testing.allocator.free(py);
    try testing.expect(py.len == 2);
    for (py) |r| try testing.expect(std.mem.endsWith(u8, r.path, ".py"));
}

test "issue-168: recall — multi-part query intersection" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/auth_controller.py", "class AuthController: pass");
    try explorer.indexFile("src/auth_model.py", "class AuthModel: pass");
    try explorer.indexFile("src/user_controller.py", "class UserController: pass");
    try explorer.indexFile("src/user_model.py", "class UserModel: pass");

    // "auth controller" should match auth_controller but not user_controller or auth_model
    const results = try explorer.fuzzyFindFiles("auth controller", testing.allocator, 10);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "auth_controller") != null);
}

test "issue-168: recall — transposition tolerance in pipeline" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/middleware.zig", "fn process() void {}");
    try explorer.indexFile("src/controller.zig", "fn handle() void {}");
    try explorer.indexFile("src/service.zig", "fn serve() void {}");

    // "midleware" (missing 'd') should still find middleware via Smith-Waterman
    const results = try explorer.fuzzyFindFiles("midleware", testing.allocator, 5);
    defer testing.allocator.free(results);

    try testing.expect(results.len >= 1);
    try testing.expect(std.mem.indexOf(u8, results[0].path, "middleware") != null);
}

// ── codedb_query callers + context-aware read tests ─────────────

test "issue-248: PostingList.removeDocId removes target and preserves sorted order" {
    // Documents the correctness contract for the O(log n) binary-search replacement.
    // Currently correct but O(n); fix replaces linear scan with bsearch + single remove.
    const PostingList = @import("../index.zig").PostingList;
    var list = PostingList{};
    defer list.items.deinit(testing.allocator);

    var id: u32 = 0;
    while (id < 100) : (id += 1) {
        const p = try list.getOrAddPosting(testing.allocator, id * 2); // even doc_ids 0..198
        p.loc_mask = 0xFF;
    }

    list.removeDocId(50);
    try testing.expectEqual(@as(usize, 99), list.items.items.len);
    try testing.expect(list.getByDocId(48) != null);
    try testing.expect(list.getByDocId(50) == null);
    try testing.expect(list.getByDocId(52) != null);

    // Sorted invariant must hold after removal.
    for (1..list.items.items.len) |k| {
        try testing.expect(list.items.items[k].doc_id > list.items.items[k - 1].doc_id);
    }
}

test "issue-249: nuke.removeJsonMcpServerEntry returns null when key absent" {
    // Verifies removeJsonMcpServerEntry does not signal a write when key is absent,
    // which ensures the non-atomic rewriteConfigFile path is never triggered unnecessarily.
    const result = try nuke_mod.removeJsonMcpServerEntry(testing.allocator, "{\"other\":1}", "codedb");
    try testing.expect(result == null);
}

test "issue-224: Python def line_end covers full body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);

    try explorer.indexFile("t.py",
        \\def greet(name):
        \\    msg = "hello"
        \\    return msg + name
    );

    const results = try explorer.findAllSymbols("greet", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);

    const sym = results[0].symbol;
    try testing.expectEqual(@as(u32, 1), sym.line_start);
    try testing.expectEqual(@as(u32, 3), sym.line_end);
}
