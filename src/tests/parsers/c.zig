const std = @import("std");
const cio = @import("../../cio.zig");
const testing = std.testing;
const io = std.testing.io;

const Store = @import("../../store.zig").Store;
const ChangeEntry = @import("../../store.zig").ChangeEntry;
const AgentRegistry = @import("../../agent.zig").AgentRegistry;
const Explorer = @import("../../explore.zig").Explorer;
const csharp_parser = @import("../../csharp_parser.zig");
const tsql_parser = @import("../../tsql_parser.zig");
const ssrs_parser = @import("../../ssrs_parser.zig");
const SearchResult = @import("../../explore.zig").SearchResult;
const WordIndex = @import("../../index.zig").WordIndex;
const TrigramIndex = @import("../../index.zig").TrigramIndex;
const SparseNgramIndex = @import("../../index.zig").SparseNgramIndex;
const pairWeight = @import("../../index.zig").pairWeight;
const extractSparseNgrams = @import("../../index.zig").extractSparseNgrams;
const buildCoveringSet = @import("../../index.zig").buildCoveringSet;
const setFrequencyTable = @import("../../index.zig").setFrequencyTable;
const resetFrequencyTable = @import("../../index.zig").resetFrequencyTable;
const buildFrequencyTable = @import("../../index.zig").buildFrequencyTable;
const writeFrequencyTable = @import("../../index.zig").writeFrequencyTable;
const readFrequencyTable = @import("../../index.zig").readFrequencyTable;

const WordTokenizer = @import("../../index.zig").WordTokenizer;
const splitIdentifier = @import("../../index.zig").splitIdentifier;

const version = @import("../../version.zig");
const watcher = @import("../../watcher.zig");
const edit_mod = @import("../../edit.zig");
const snapshot_json = @import("../../snapshot_json.zig");
const explore = @import("../../explore.zig");
const extractLines = explore.extractLines;
const isCommentOrBlank = explore.isCommentOrBlank;
const Language = explore.Language;
const SymbolKind = explore.SymbolKind;
const DependencyGraph = explore.DependencyGraph;
const SymbolLocation = explore.SymbolLocation;
const mcp_mod = @import("../../mcp.zig");
const main_mod = @import("../../main.zig");
const nuke_mod = @import("../../nuke.zig");
const update_mod = @import("../../update.zig");
const Config = @import("../../config.zig").Config;
// Pull in unit tests that were extracted from implementation files into
// dedicated `*__tests.zig` companions. Zig collects test blocks through
// @import, so referencing them here makes the test runner discover them.
comptime {
    _ = @import("../../config_tests.zig");
    _ = @import("../../hot_cache_tests.zig");
    _ = @import("../../root_policy_tests.zig");
    _ = @import("../../tsql_parser_tests.zig");
}
const snapshot_mod = @import("../../snapshot.zig");
const telemetry_mod = @import("../../telemetry.zig");
const release_info = @import("../../release_info.zig");
// ── Store tests ─────────────────────────────────────────────

const decomposeRegex = @import("../../index.zig").decomposeRegex;

const RegexQuery = @import("../../index.zig").RegexQuery;

const packTrigram = @import("../../index.zig").packTrigram;

const git_mod = @import("../../git.zig");

const regexMatch = explore.regexMatch;

const PostingMask = @import("../../index.zig").PostingMask;

const normalizeChar = @import("../../index.zig").normalizeChar;

const Trigram = @import("../../index.zig").Trigram;

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

const MmapTrigramIndex = @import("../../index.zig").MmapTrigramIndex;

const AnyTrigramIndex = @import("../../index.zig").AnyTrigramIndex;

const fuzzyScore = @import("../../explore.zig").fuzzyScore;

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

test "disk index: readDiskHeader returns file_count and git_head" {
    const alloc = testing.allocator;
    var ti = TrigramIndex.init(alloc);
    defer ti.deinit();

    try ti.indexFile("x.zig", "pub const X = 42;");
    try ti.indexFile("y.zig", "pub const Y = 99;");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const fake_head = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".*;
    try ti.writeToDisk(io, dir_path, fake_head);

    const hdr = try TrigramIndex.readDiskHeader(io, dir_path, alloc);
    try testing.expect(hdr != null);
    try testing.expectEqual(@as(u32, 2), hdr.?.file_count);
    try testing.expect(hdr.?.git_head != null);
    try testing.expectEqualSlices(u8, &fake_head, &hdr.?.git_head.?);
}

test "nuke: removeCodexMcpServerBlock matches indented header with inline comment" {
    const input =
        \\  [mcp_servers.codedb] # local override
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "codedb") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
}

test "issue-319: C parser extracts includes macros types and functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/core.c",
        \\#include <stdio.h>
        \\#include "local.h"
        \\#define MAX_SIZE 64
        \\#define SQUARE(x) ((x) * (x))
        \\struct Worker {
        \\    int id;
        \\};
        \\enum Mode {
        \\    MODE_A,
        \\};
        \\union Value {
        \\    int i;
        \\};
        \\typedef unsigned long size_alias_t;
        \\static inline const char *worker_name(const struct Worker *worker) {
        \\    return "worker";
        \\}
        \\void *alloc_item(size_t size)
        \\{
        \\    return malloc(size);
        \\}
    );

    const outline = try explorer.getOutline("src/core.c", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.c, outline.language);
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("stdio.h", outline.imports.items[0]);
    try testing.expectEqualStrings("local.h", outline.imports.items[1]);

    const max_size = try explorer.findAllSymbols("MAX_SIZE", alloc);
    defer alloc.free(max_size);
    try testing.expectEqual(@as(usize, 1), max_size.len);
    try testing.expectEqual(SymbolKind.macro_def, max_size[0].symbol.kind);

    const square = try explorer.findAllSymbols("SQUARE", alloc);
    defer alloc.free(square);
    try testing.expectEqual(@as(usize, 1), square.len);
    try testing.expectEqual(SymbolKind.macro_def, square[0].symbol.kind);

    const worker = try explorer.findAllSymbols("Worker", alloc);
    defer alloc.free(worker);
    try testing.expectEqual(@as(usize, 1), worker.len);
    try testing.expectEqual(SymbolKind.struct_def, worker[0].symbol.kind);

    const mode = try explorer.findAllSymbols("Mode", alloc);
    defer alloc.free(mode);
    try testing.expectEqual(@as(usize, 1), mode.len);
    try testing.expectEqual(SymbolKind.enum_def, mode[0].symbol.kind);

    const value = try explorer.findAllSymbols("Value", alloc);
    defer alloc.free(value);
    try testing.expectEqual(@as(usize, 1), value.len);
    try testing.expectEqual(SymbolKind.union_def, value[0].symbol.kind);

    const alias = try explorer.findAllSymbols("size_alias_t", alloc);
    defer alloc.free(alias);
    try testing.expectEqual(@as(usize, 1), alias.len);
    try testing.expectEqual(SymbolKind.type_alias, alias[0].symbol.kind);

    const worker_name = try explorer.findAllSymbols("worker_name", alloc);
    defer alloc.free(worker_name);
    try testing.expectEqual(@as(usize, 1), worker_name.len);
    try testing.expectEqual(SymbolKind.function, worker_name[0].symbol.kind);

    const alloc_item = try explorer.findAllSymbols("alloc_item", alloc);
    defer alloc.free(alloc_item);
    try testing.expectEqual(@as(usize, 1), alloc_item.len);
    try testing.expectEqual(SymbolKind.function, alloc_item[0].symbol.kind);
}

test "issue-319: C parser avoids comments strings prototypes and macro calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/noise.c",
        \\// int fake_comment(void) {
        \\/* int fake_block(void) { */
        \\const char *s = "int fake_string(void) {";
        \\typedef int (*handler_fn)(int);
        \\int prototype_only(void);
        \\EXPORT_SYMBOL(real_function);
        \\if (real_function()) {
        \\}
        \\int real_function(void) {
        \\    return 1;
        \\}
    );

    const real = try explorer.findAllSymbols("real_function", alloc);
    defer alloc.free(real);
    try testing.expectEqual(@as(usize, 1), real.len);
    try testing.expectEqual(SymbolKind.function, real[0].symbol.kind);

    const fake_comment = try explorer.findAllSymbols("fake_comment", alloc);
    defer alloc.free(fake_comment);
    try testing.expectEqual(@as(usize, 0), fake_comment.len);

    const fake_block = try explorer.findAllSymbols("fake_block", alloc);
    defer alloc.free(fake_block);
    try testing.expectEqual(@as(usize, 0), fake_block.len);

    const fake_string = try explorer.findAllSymbols("fake_string", alloc);
    defer alloc.free(fake_string);
    try testing.expectEqual(@as(usize, 0), fake_string.len);

    const prototype = try explorer.findAllSymbols("prototype_only", alloc);
    defer alloc.free(prototype);
    try testing.expectEqual(@as(usize, 0), prototype.len);

    const handler = try explorer.findAllSymbols("handler_fn", alloc);
    defer alloc.free(handler);
    try testing.expectEqual(@as(usize, 0), handler.len);
}

test "issue-331: C parser does not index indented call sites as functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var explorer = Explorer.init(a);

    try explorer.indexFile("test.c",
        \\void real_func(int x) {
        \\    fprintf(stderr, "curl_easy_perform() failed: %s\n",
        \\            curl_easy_strerror(res));
        \\    curl_easy_perform(curl);
        \\    if (SSL_get_options(ctx))
        \\        return;
        \\}
    );

    const syms = explorer.outlines.get("test.c").?.symbols.items;
    var found_false = false;
    for (syms) |sym| {
        if (sym.kind == .function) {
            if (std.mem.eql(u8, sym.name, "fprintf") or
                std.mem.eql(u8, sym.name, "curl_easy_perform") or
                std.mem.eql(u8, sym.name, "curl_easy_strerror") or
                std.mem.eql(u8, sym.name, "SSL_get_options"))
            {
                found_false = true;
            }
        }
    }
    try testing.expect(!found_false);
    var found_real = false;
    for (syms) |sym| {
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "real_func"))
            found_real = true;
    }
    try testing.expect(found_real);
}

test "issue-331: C parser finds nginx-style split-line definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var explorer = Explorer.init(a);

    try explorer.indexFile("ngx_http_request.c",
        \\ngx_int_t
        \\ngx_http_init_connection(ngx_connection_t *c)
        \\{
        \\    ngx_http_connection_t  *hc;
        \\}
        \\
        \\static ngx_int_t
        \\ngx_http_create_request(ngx_http_request_t *r)
        \\{
        \\    return NGX_OK;
        \\}
    );

    const syms = explorer.outlines.get("ngx_http_request.c").?.symbols.items;
    var found_init = false;
    var found_create = false;
    for (syms) |sym| {
        if (sym.kind == .function) {
            if (std.mem.eql(u8, sym.name, "ngx_http_init_connection")) found_init = true;
            if (std.mem.eql(u8, sym.name, "ngx_http_create_request")) found_create = true;
        }
    }
    try testing.expect(found_init);
    try testing.expect(found_create);
}

test "issue-422: search header count must reflect post-filter visible results" {
    // From the issue: a query whose ONLY match would be displayed instead
    // shows `1 results` then `(0 shown, 1 truncated)` — every match hidden
    // behind a misleading header. Root cause: the header reports the
    // unfiltered `results.len` from the explorer, but path_glob/compact
    // filters can drop items before they reach the renderer, so a "result"
    // that was filtered is mis-labeled as "truncated".
    //
    // Repro shape mirrors the reporter's call: scope=true, compact=true,
    // path_glob limited to a subtree. The match ITSELF is in-glob and not a
    // comment — the bug is purely in the bookkeeping.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    // Two files: one in the path_glob subtree (the real match), one outside
    // it (a decoy that the explorer would also return for the substring).
    // Without the fix the header counts both, then the renderer drops the
    // out-of-glob one and (because of unrelated bookkeeping) reports the
    // in-glob one as "truncated" too.
    try explorer.indexFile(
        "crates/forge_api/src/forge_api.rs",
        "// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\n// header\npub struct ForgeAPI<S, F> {\n",
    );
    // Decoy match outside the glob — explorer will return it, the renderer
    // must NOT count it toward "truncated".
    try explorer.indexFile("docs/forge_api.md", "struct ForgeAPI is documented here\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"struct ForgeAPI","max_results":20,"scope":true,"compact":true,"regex":false,"path_glob":"crates/**/*.rs"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // The actionable hit must be visible (path + line number).
    try testing.expect(std.mem.indexOf(u8, out.items, "crates/forge_api/src/forge_api.rs") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ":24:") != null);
    // Out-of-glob decoy must be excluded from the rendered output.
    try testing.expect(std.mem.indexOf(u8, out.items, "docs/forge_api.md") == null);
    // The misleading "(N shown, M truncated)" footer must NOT fire when M
    // is just the count of glob-filtered or compact-filtered items. Those
    // weren't truncated — they were filtered out, and saying "truncated"
    // implies the user could recover them by raising max_results.
    try testing.expect(std.mem.indexOf(u8, out.items, " truncated)") == null);
    // Header count must reflect post-filter visible matches (1), not the
    // raw explorer count (2). Otherwise users see a misleading "2 results"
    // when only 1 matched their glob.
    try testing.expect(std.mem.indexOf(u8, out.items, "1 results for 'struct ForgeAPI'") != null);
}

test "bm25-recall-c: df-saturation -- ubiquitous term has near-zero idf" {
    // "the" appears in all 11 docs -> idf near zero, barely contributes.
    // "unique_marker" appears only in special.txt -> high idf, special.txt ranks first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("d1.txt", "the quick brown fox");
    try explorer.indexFile("d2.txt", "the lazy dog jumps");
    try explorer.indexFile("d3.txt", "the sun rises east");
    try explorer.indexFile("d4.txt", "the moon shines bright");
    try explorer.indexFile("d5.txt", "the rain in spain");
    try explorer.indexFile("d6.txt", "the cat sat mat");
    try explorer.indexFile("d7.txt", "the wind blows cold");
    try explorer.indexFile("d8.txt", "the tide comes in");
    try explorer.indexFile("d9.txt", "the stars align now");
    try explorer.indexFile("d10.txt", "the clock ticks forward");
    try explorer.indexFile("special.txt", "the unique_marker is here");

    const results = try explorer.searchContentRanked("the unique_marker", testing.allocator, 20);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len > 0);
    try testing.expectEqualStrings("special.txt", results[0].path);
    if (results.len > 1) {
        try testing.expect(results[0].score > results[1].score);
    }
}

test "issue-429-c: searchContent rerank boosts lines that are symbol definitions" {
    // Two files. "aaa.zig" has a passing comment mention of `fooSym`. The
    // alphabetically-later "zzz_def.zig" has the actual definition. Both
    // tie on per-line occurrence count. Pre-fix the path-asc tiebreaker
    // promotes the comment mention ("aaa" < "zzz"). Post-fix the rerank
    // recognises that the line in zzz_def.zig is a symbol definition and
    // ranks it first.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("aaa.zig", "// fooSym is referenced here in a comment\n");
    try explorer.indexFile("zzz_def.zig", "pub fn fooSym() void {}\n");

    const results = try explorer.searchContent("fooSym", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len >= 2);
    try testing.expectEqualStrings("zzz_def.zig", results[0].path);
}
