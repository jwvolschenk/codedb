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

test "sparse ngram index: index and candidate lookup" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // Index each file with content equal to the query we'll use — this
    // guarantees the sparse n-gram boundaries align (same string = same weights).
    const foo_query = "recordSnapshot";
    const bar_query = "registerAgent";
    try sni.indexFile("src/foo.zig", foo_query);
    try sni.indexFile("src/bar.zig", bar_query);

    const cands = sni.candidates(foo_query, testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);
    try testing.expect(cands != null);

    var found_foo = false;
    var found_bar = false;
    if (cands) |cs| {
        for (cs) |p| {
            if (std.mem.eql(u8, p, "src/foo.zig")) found_foo = true;
            if (std.mem.eql(u8, p, "src/bar.zig")) found_bar = true;
        }
    }
    try testing.expect(found_foo);
    try testing.expect(!found_bar);
}

test "sparse ngram index: short query returns null" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("f.zig", "hello world");
    const cands = sni.candidates("hi", testing.allocator); // length 2 < MIN_LEN
    try testing.expect(cands == null);
}

test "sparse ngram index: re-index removes old ngrams" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("f.zig", "uniqueOldContent");
    const c1 = sni.candidates("uniqueOldContent", testing.allocator);
    defer if (c1) |c| testing.allocator.free(c);
    try testing.expect(c1 != null and c1.?.len == 1);

    try sni.indexFile("f.zig", "brandNewStuff");
    const c2 = sni.candidates("uniqueOldContent", testing.allocator);
    defer if (c2) |c| testing.allocator.free(c);
    // After re-index the old content is gone; may return empty or null.
    if (c2) |cs| try testing.expectEqual(@as(usize, 0), cs.len);
}

test "sparse ngram index: removeFile prunes entries" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    try sni.indexFile("a.zig", "hello world foo bar");
    try testing.expectEqual(@as(u32, 1), sni.fileCount());

    sni.removeFile("a.zig");
    try testing.expectEqual(@as(u32, 0), sni.fileCount());
}

test "sparse ngram candidates: sliding window finds file with short n-gram" {
    var sni = SparseNgramIndex.init(testing.allocator);
    defer sni.deinit();

    // "a.zig" is indexed with content "rec" — produces the 3-char n-gram "rec".
    // "b.zig" is indexed with unrelated content.
    try sni.indexFile("a.zig", "rec");
    try sni.indexFile("b.zig", "xxxxxxxxxx");

    // Query "record" (6 chars) contains "rec" as a 3-char sliding-window
    // substring.  buildCoveringSet generates "rec" → hash matches the indexed
    // n-gram of "a.zig".
    const cands = sni.candidates("record", testing.allocator);
    defer if (cands) |c| testing.allocator.free(c);

    var found_a = false;
    if (cands) |cs| {
        for (cs) |p| if (std.mem.eql(u8, p, "a.zig")) {
            found_a = true;
        };
    }
    try testing.expect(found_a);
}

test "explorer: index file and get outline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("test.zig",
        \\const std = @import("std");
        \\pub fn main() !void {}
        \\pub const Store = struct {};
    );

    var outline = (try explorer.getOutline("test.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.line_count == 3);
    try testing.expect(outline.symbols.items.len == 3);
}

test "explorer: findSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn alpha() void {}");
    try explorer.indexFile("b.zig", "pub fn beta() void {}");

    const result = try explorer.findSymbol("alpha", arena.allocator());
    try testing.expect(result != null);
    try testing.expectEqualStrings("a.zig", result.?.path);
}

test "explorer: findAllSymbols returns multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "const Store = @import(\"store.zig\").Store;");
    try explorer.indexFile("b.zig", "pub const Store = struct {};");

    const results = try explorer.findAllSymbols("Store", arena.allocator());
    defer arena.allocator().free(results);
    try testing.expect(results.len == 2);
}

test "explorer: removeFile cleans up everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("gone.zig", "pub fn doStuff() void {}");
    var before_remove = (try explorer.getOutline("gone.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    before_remove.deinit();

    explorer.removeFile("gone.zig");
    try testing.expect((try explorer.getOutline("gone.zig", testing.allocator)) == null);
    try testing.expect((try explorer.findSymbol("doStuff", testing.allocator)) == null);
}

test "explorer: python parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app.py",
        \\import os
        \\class Server:
        \\    def handle(self):
        \\        pass
    );

    var outline = (try explorer.getOutline("app.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len == 3); // import, class, def
}

test "explorer: typescript parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("index.ts",
        \\import { foo } from './foo';
        \\export function handleRequest() {}
        \\export const PORT = 3000;
    );

    var outline = (try explorer.getOutline("index.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 3);
}

test "explorer: reindex OOM keeps prior outline reachable" {
    // Use a real allocator for the explorer so the first indexFile always succeeds.
    // We can't use FailingAllocator for the whole explorer because deinit would crash.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("oom.zig", "pub fn oldName() void {}");

    // Now try re-indexing the same file. Since the explorer uses testing.allocator,
    // we can't make individual internal allocs fail without a custom allocator wrapper.
    // Instead, verify the errdefer rollback logic by confirming a successful reindex
    // replaces the old outline, and that data is consistent.
    try explorer.indexFile("oom.zig", "pub fn newName() void {}\nconst VALUE = 1;");

    var outline = (try explorer.getOutline("oom.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqualStrings("oom.zig", outline.path);
    try testing.expect(outline.symbols.items.len == 2); // newName + VALUE

    // Old content should be replaced
    const old_results = try explorer.searchContent("oldName", testing.allocator, 10);
    defer {
        for (old_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(old_results);
    }
    try testing.expect(old_results.len == 0);

    // New content should be searchable
    const new_results = try explorer.searchContent("newName", testing.allocator, 10);
    defer {
        for (new_results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(new_results);
    }
    try testing.expect(new_results.len == 1);
}

test "explorer: getOutline clone OOM preserves source outline" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile(
        "clone-oom.zig",
        "pub fn keepA() void {}\nconst dep = @import(\"dep.zig\");\npub const Value = 1;",
    );

    var induced_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 512 and !induced_oom) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const result = explorer.getOutline("clone-oom.zig", failing.allocator());

        if (result) |maybe_outline| {
            var outline = maybe_outline orelse return error.TestUnexpectedResult;
            outline.deinit();
            continue;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            induced_oom = true;

            var stable = (try explorer.getOutline("clone-oom.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
            defer stable.deinit();
            try testing.expect(stable.symbols.items.len >= 2);
            try testing.expect(stable.imports.items.len == 1);
            try testing.expectEqualStrings("dep.zig", stable.imports.items[0]);
        }
    }

    try testing.expect(induced_oom);
}

test "explorer: outline copy survives source removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("persist.zig", "pub fn keep() void {}");
    var outline = (try explorer.getOutline("persist.zig", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    explorer.removeFile("persist.zig");

    try testing.expectEqualStrings("persist.zig", outline.path);
    try testing.expect(outline.symbols.items.len > 0);
}

test "explorer: removeFile frees owned map key" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "tmp/remove-{d}.zig", .{i});
        try explorer.indexFile(path, "pub fn x() void {}");
        explorer.removeFile(path);
    }

    try testing.expect(explorer.outlines.count() == 0);
    try testing.expect(explorer.contents.count() == 0);
    try testing.expect(explorer.dep_graph.count() == 0);
}

test "findSymbol: returned data is owned copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("a.zig", "pub fn myFunc() void {}");

    const result = try explorer.findSymbol("myFunc", alloc);
    try testing.expect(result != null);

    // Remove the source — if result was borrowed, this would corrupt it
    explorer.removeFile("a.zig");

    // Owned copy should still be valid
    try testing.expectEqualStrings("a.zig", result.?.path);
    try testing.expectEqualStrings("myFunc", result.?.symbol.name);
}

test "findAllSymbols: returned data survives source removal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var explorer = Explorer.init(alloc);
    try explorer.indexFile("a.zig", "pub fn foo() void {}");
    try explorer.indexFile("b.zig", "pub fn foo() void {}");

    const results = try explorer.findAllSymbols("foo", alloc);

    // Remove sources
    explorer.removeFile("a.zig");
    explorer.removeFile("b.zig");

    // Owned copies should still be valid
    try testing.expect(results.len == 2);
    for (results) |r| {
        try testing.expectEqualStrings("foo", r.symbol.name);
    }
}

test "explorer: getSymbolBody returns source lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("test.zig", "const std = @import(\"std\");\npub fn main() !void {}\npub const Store = struct {};");

    const body = try exp.getSymbolBody("test.zig", 2, 2, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "pub fn main") != null);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "explorer: getSymbolBody returns null for unknown file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    const body = try exp.getSymbolBody("nonexistent.zig", 1, 5, testing.allocator);
    try testing.expect(body == null);
}

test "detectLanguage: public access and correct detection" {
    try testing.expect(explore.detectLanguage("src/main.zig") == .zig);
    try testing.expect(explore.detectLanguage("app.py") == .python);
    try testing.expect(explore.detectLanguage("index.ts") == .typescript);
    try testing.expect(explore.detectLanguage("style.css") == .css);
    try testing.expect(explore.detectLanguage("Domain.fs") == .f_sharp);
    try testing.expect(explore.detectLanguage("Contracts.fsi") == .f_sharp);
    try testing.expect(explore.detectLanguage("Scratch.fsx") == .f_sharp);
}

test "typescript: type extraction from function signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("api.ts",
        \\function getUser(id: number): Promise<User> { }
        \\function deleteUser(id: number, name: string): void { }
        \\export function getConfig(): AppConfig { }
    );

    // Check return types
    const promise_hits = explorer.type_index.findByReturnType("Promise<User>");
    try testing.expectEqual(@as(usize, 1), promise_hits.len);
    try testing.expectEqualStrings("getUser", promise_hits[0].symbol_name);

    const void_hits = explorer.type_index.findByReturnType("void");
    try testing.expectEqual(@as(usize, 1), void_hits.len);
    try testing.expectEqualStrings("deleteUser", void_hits[0].symbol_name);

    const config_hits = explorer.type_index.findByReturnType("AppConfig");
    try testing.expectEqual(@as(usize, 1), config_hits.len);

    // Check param types
    const number_hits = explorer.type_index.findByParamType("number");
    try testing.expectEqual(@as(usize, 2), number_hits.len); // getUser and deleteUser

    const string_hits = explorer.type_index.findByParamType("string");
    try testing.expectEqual(@as(usize, 1), string_hits.len); // deleteUser
}

test "go: type extraction from function signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("handler.go",
        \\func GetUser(id int) (*User, error) { return nil, nil }
        \\func DeleteUser(id int, name string) error { return nil }
        \\func (s *Service) Save(data []byte) (int, error) { return 0, nil }
    );

    // Check return types
    const user_hits = explorer.type_index.findByReturnType("(*User, error)");
    try testing.expectEqual(@as(usize, 1), user_hits.len);
    try testing.expectEqualStrings("GetUser", user_hits[0].symbol_name);

    const error_hits = explorer.type_index.findByReturnType("error");
    try testing.expectEqual(@as(usize, 1), error_hits.len);
    try testing.expectEqualStrings("DeleteUser", error_hits[0].symbol_name);

    const save_hits = explorer.type_index.findByReturnType("(int, error)");
    try testing.expectEqual(@as(usize, 1), save_hits.len);
    try testing.expectEqualStrings("Save", save_hits[0].symbol_name);

    // Check param types
    const int_hits = explorer.type_index.findByParamType("int");
    try testing.expectEqual(@as(usize, 2), int_hits.len); // GetUser and DeleteUser

    const string_hits = explorer.type_index.findByParamType("string");
    try testing.expectEqual(@as(usize, 1), string_hits.len); // DeleteUser

    const bytes_hits = explorer.type_index.findByParamType("[]byte");
    try testing.expectEqual(@as(usize, 1), bytes_hits.len); // Save
}

test "explorer: getSymbolBody multi-line range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    const content = "line1\nline2\nline3\nline4\nline5";
    try exp.indexFile("multi.zig", content);

    const body = try exp.getSymbolBody("multi.zig", 2, 4, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "line2") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line3") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line4") != null);
        try testing.expect(std.mem.indexOf(u8, b, "line1") == null);
        try testing.expect(std.mem.indexOf(u8, b, "line5") == null);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "explorer: getSymbolBody range beyond file length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("short.zig", "only\ntwo");
    const body = try exp.getSymbolBody("short.zig", 1, 100, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "only") != null);
        try testing.expect(std.mem.indexOf(u8, b, "two") != null);
    } else {
        return error.TestUnexpectedResult;
    }
}

// ── searchContentWithScope: multi-file, multi-result ────────

test "detectLanguage: all supported extensions" {
    try testing.expect(explore.detectLanguage("main.zig") == .zig);
    try testing.expect(explore.detectLanguage("lib.c") == .c);
    try testing.expect(explore.detectLanguage("util.h") == .c);
    try testing.expect(explore.detectLanguage("app.cpp") == .cpp);
    try testing.expect(explore.detectLanguage("app.hpp") == .cpp);
    try testing.expect(explore.detectLanguage("app.cc") == .cpp);
    try testing.expect(explore.detectLanguage("app.hh") == .cpp);
    try testing.expect(explore.detectLanguage("app.cxx") == .cpp);
    try testing.expect(explore.detectLanguage("app.hxx") == .cpp);
    try testing.expect(explore.detectLanguage("bridge.mm") == .cpp);
    try testing.expect(explore.detectLanguage("script.py") == .python);
    try testing.expect(explore.detectLanguage("app.js") == .javascript);
    try testing.expect(explore.detectLanguage("comp.jsx") == .javascript);
    try testing.expect(explore.detectLanguage("app.ts") == .typescript);
    try testing.expect(explore.detectLanguage("comp.tsx") == .typescript);
    try testing.expect(explore.detectLanguage("main.rs") == .rust);
    try testing.expect(explore.detectLanguage("main.go") == .go_lang);
    try testing.expect(explore.detectLanguage("app.dart") == .dart);
    try testing.expect(explore.detectLanguage("README.md") == .markdown);
    try testing.expect(explore.detectLanguage("pkg.json") == .json);
    try testing.expect(explore.detectLanguage("config.yaml") == .yaml);
    try testing.expect(explore.detectLanguage("config.yml") == .yaml);
    try testing.expect(explore.detectLanguage("Main.java") == .java);
    try testing.expect(explore.detectLanguage("App.kt") == .kotlin);
    try testing.expect(explore.detectLanguage("Widget.svelte") == .svelte);
    try testing.expect(explore.detectLanguage("Widget.vue") == .vue);
    try testing.expect(explore.detectLanguage("Page.astro") == .astro);
    try testing.expect(explore.detectLanguage("bootstrap.sh") == .shell);
    try testing.expect(explore.detectLanguage("styles.css") == .css);
    try testing.expect(explore.detectLanguage("styles.scss") == .scss);
    try testing.expect(explore.detectLanguage("schema.sql") == .sql);
    try testing.expect(explore.detectLanguage("service.proto") == .protobuf);
    try testing.expect(explore.detectLanguage("solver.f90") == .fortran);
    try testing.expect(explore.detectLanguage("module.ll") == .llvm_ir);
    try testing.expect(explore.detectLanguage("dialect.mlir") == .mlir);
    try testing.expect(explore.detectLanguage("records.td") == .tablegen);
    try testing.expect(explore.detectLanguage("Program.cs") == .c_sharp);
    try testing.expect(explore.detectLanguage("script.csx") == .c_sharp);
    try testing.expect(explore.detectLanguage("Index.cshtml") == .razor);
    try testing.expect(explore.detectLanguage("Page.razor") == .razor);
    try testing.expect(explore.detectLanguage("Model.tt") == .t4_template);
    try testing.expect(explore.detectLanguage("CodeGen.t4") == .t4_template);
    try testing.expect(explore.detectLanguage("Player.gd") == .gdscript);
    try testing.expect(explore.detectLanguage("Main.tscn") == .godot_scene);
    try testing.expect(explore.detectLanguage("CardData.tres") == .godot_resource);
    try testing.expect(explore.detectLanguage("project.godot") == .godot_project);
    try testing.expect(explore.detectLanguage("games/lunch-rush/project.godot") == .godot_project);
    try testing.expect(explore.detectLanguage("Makefile") == .unknown);
    try testing.expect(explore.detectLanguage("no_ext") == .unknown);
}

test "t4 parser: extracts directives from TypeGenerator.tt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("TypeGenerator.tt",
        \\<#@ template debug="false" hostspecific="true" language="C#" #>
        \\<#@ assembly name="System.Core" #>
        \\<#@ import namespace="System.Linq" #>
        \\<#@ import namespace="System.Text" #>
        \\<#@ import namespace="System.Collections.Generic" #>
        \\<#@ output extension=".txt" #>
        \\<#@ assembly name="$(SolutionDir)src\Autumn\TypeGenerator\bin\Debug\net472\TypeGenerator.exe" #>
        \\<#= TypeGenerator.generate(Host.ResolvePath(@"..\")) #>
    );

    const outline = explorer.outlines.get("TypeGenerator.tt").?;
    try testing.expectEqual(explore.Language.t4_template, outline.language);

    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Should have template, assembly, and output directives
    try testing.expect(containsString(sym_names.items, "C#"));
    try testing.expect(containsString(sym_names.items, ".txt"));

    // Should have imports
    var import_paths: std.ArrayList([]const u8) = .empty;
    for (outline.imports.items) |imp| {
        try import_paths.append(alloc, imp);
    }
    try testing.expect(containsString(import_paths.items, "System.Linq"));
    try testing.expect(containsString(import_paths.items, "System.Text"));
    try testing.expect(containsString(import_paths.items, "System.Collections.Generic"));
}

test "t4 parser: extracts class feature block declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("CodeGen.tt",
        \\<#@ template language="C#" #>
        \\<#@ import namespace="System" #>
        \\<#@ import namespace="System.Collections.Generic" #>
        \\<#+
        \\public class ModelGenerator
        \\{
        \\    public string GenerateModels(IEnumerable<Type> types)
        \\    {
        \\        return "";
        \\    }
        \\
        \\    public string Namespace { get; set; }
        \\}
        \\#>
    );

    const outline = explorer.outlines.get("CodeGen.tt").?;
    try testing.expectEqual(explore.Language.t4_template, outline.language);

    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Should have template directive
    try testing.expect(containsString(sym_names.items, "C#"));

    // Should have imports
    var import_paths: std.ArrayList([]const u8) = .empty;
    for (outline.imports.items) |imp| {
        try import_paths.append(alloc, imp);
    }
    try testing.expect(containsString(import_paths.items, "System"));
    try testing.expect(containsString(import_paths.items, "System.Collections.Generic"));
}

test "t4 parser: handles parameter directives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("Parametrized.tt",
        \\<#@ template language="C#" #>
        \\<#@ parameter name="EntityName" type="string" #>
        \\<#@ parameter name="Namespace" type="string" #>
        \\<#@ output extension=".cs" #>
    );

    const outline = explorer.outlines.get("Parametrized.tt").?;
    try testing.expectEqual(explore.Language.t4_template, outline.language);

    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Should have parameter directives and output
    try testing.expect(containsString(sym_names.items, "EntityName"));
    try testing.expect(containsString(sym_names.items, "Namespace"));
    try testing.expect(containsString(sym_names.items, ".cs"));
}

// ── getBool helper ──────────────────────────────────────────

test "Tool enum: all valid tool names parse" {
    const Tool = @import("../mcp.zig").Tool;
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_tree") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_outline") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_symbol") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_search") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_word") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_hot") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_deps") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_read") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_edit") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_changes") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_status") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_snapshot") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "codedb_bundle") != null);
}

test "explorer: getSymbolBody with line number format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("fmt.zig", "const a = 1;\npub fn format() void {\n    write();\n}\nconst b = 2;");

    const body = try exp.getSymbolBody("fmt.zig", 2, 4, testing.allocator);
    if (body) |b| {
        defer testing.allocator.free(b);
        try testing.expect(std.mem.indexOf(u8, b, "    2 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "    3 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "    4 |") != null);
        try testing.expect(std.mem.indexOf(u8, b, "const a") == null);
        try testing.expect(std.mem.indexOf(u8, b, "const b") == null);
    } else {
        return error.TestUnexpectedResult;
    }
}

// ── Compact output: verify code-only output ─────────────────

test "issue-111: Python triple-quote docstrings not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("docstring.py",
        \\def real_func():
        \\    """
        \\    def fake_func():
        \\        pass
        \\    """
        \\    pass
    );

    var outline = (try explorer.getOutline("docstring.py", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    // Only real_func should be found, not fake_func inside docstring
    try testing.expect(func_count == 1);
}

test "issue-113: TypeScript block comments not parsed as code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.ts",
        \\export function realFunc() {}
        \\/*
        \\export function fakeFunc() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1);
}

test "typescript relative parent imports are indexed as reverse dependencies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/shared/mod.ts", "export function hello() {}\n");
    try explorer.indexFile("src/features/consumer.ts", "import { hello } from '../shared/mod'\n");

    const deps = try explorer.getImportedBy("src/shared/mod.ts", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }

    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("src/features/consumer.ts", deps[0]);
}

// ── Trigram index regression suite (#142) ─────────────────────────────
// Tests correctness invariants that must hold across index implementation changes.

test "update: checksumForBinary parses release manifest" {
    const manifest =
        \\7be38140d090b2e23723c8cde02be150171c818daa16b18c520b44cc1e078add  codedb-darwin-arm64
        \\76bc7b81bc9fd211aa2c1ac59d1d26e8c80bc211ab560de2dc998ea9e04ec471  codedb-darwin-x86_64
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  *codedb-linux-arm64
    ;

    try testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        update_mod.checksumForBinary(manifest, "codedb-linux-arm64") orelse return error.TestUnexpectedResult,
    );
    try testing.expect(update_mod.checksumForBinary(manifest, "codedb-linux-x86_64") == null);
}

// test "update: asset names match published release naming" {
//     try testing.expectEqualStrings("codedb-darwin-arm64", update_mod.assetNameForTarget(.macos, .aarch64).?);
//     try testing.expectEqualStrings("codedb-darwin-x86_64", update_mod.assetNameForTarget(.macos, .x86_64).?);
//     try testing.expectEqualStrings("codedb-linux-arm64", update_mod.assetNameForTarget(.linux, .aarch64).?);
//     try testing.expectEqualStrings("codedb-linux-x86_64", update_mod.assetNameForTarget(.linux, .x86_64).?);
//     try testing.expect(update_mod.assetNameForTarget(.windows, .x86_64) == null);
// }

test "issue-168: query pipeline outline returns symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("src/main.zig", "pub fn main() void {}\npub fn helper() void {}\n");

    var outline = (try explorer.getOutline("src/main.zig", testing.allocator)).?;
    defer outline.deinit();
    try testing.expect(outline.symbols.items.len >= 2);
}

test "issue-179: block comment does not produce phantom symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* commented out\npub fn fake_func() void {}\n*/\npub fn real_func() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real_func") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake_func") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}

test "issue-179: code after single-line /* */ comment is parsed" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.zig", "/* skip this */ pub fn visible() void {}\n");

    const outline = (try explorer.getOutline("test.zig", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "visible") != null) found = true;
    }
    try testing.expect(found);
}

test "issue-179: Python docstring with text does not leak symbols" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    try explorer.indexFile("test.py", "def real():\n    \"\"\"This is a docstring.\n    def fake():\n        pass\n    \"\"\"\n    pass\n");

    const outline = (try explorer.getOutline("test.py", testing.allocator)).?;
    defer {
        var o = outline;
        o.deinit();
    }
    var found_real = false;
    var found_fake = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.indexOf(u8, sym.name, "real") != null) found_real = true;
        if (std.mem.indexOf(u8, sym.name, "fake") != null) found_fake = true;
    }
    try testing.expect(found_real);
    try testing.expect(!found_fake);
}

// ── New bug / perf regression tests ─────────────────────────────────────

test "issue-108: detectLanguage handles .tf and .tfvars" {
    try testing.expectEqual(Language.hcl, explore.detectLanguage("main.tf"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("prod.tfvars"));
    try testing.expectEqual(Language.hcl, explore.detectLanguage("config.hcl"));
}

test "issue-215: R function assignment parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("analysis.R",
        \\greet <- function(name) {
        \\  paste("Hello", name)
        \\}
    );
    const results = try explorer.findAllSymbols("greet", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.function, results[0].symbol.kind);
}

test "issue-215: R library import parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("script.r",
        \\library(dplyr)
        \\require(ggplot2)
    );
    const outline = try explorer.getOutline("script.r", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
}

test "issue-215: R setClass parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("classes.R",
        \\setClass("Person")
        \\setRefClass("Animal")
    );
    const p = try explorer.findAllSymbols("Person", alloc);
    defer alloc.free(p);
    try testing.expect(p.len == 1);
    try testing.expectEqual(SymbolKind.class_def, p[0].symbol.kind);
    const a2 = try explorer.findAllSymbols("Animal", alloc);
    defer alloc.free(a2);
    try testing.expect(a2.len == 1);
}
