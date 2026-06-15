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

test "issue-215: detectLanguage handles .r and .R" {
    try testing.expectEqual(Language.r, explore.detectLanguage("script.r"));
    try testing.expectEqual(Language.r, explore.detectLanguage("analysis.R"));
}

test "issue-321: common detected extensions produce outlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/math.cc",
        \\#include <vector>
        \\class Calculator {
        \\public:
        \\    int add(int a, int b) {
        \\        return a + b;
        \\    }
        \\};
        \\int free_add(int a, int b) {
        \\    return a + b;
        \\}
    );
    try explorer.indexFile("src/Bridge.mm",
        \\#import "Bridge.h"
        \\@interface BrowserController
        \\- (void)loadPage:(NSString *)url;
        \\@end
        \\@implementation BrowserController
        \\- (void)loadPage:(NSString *)url { }
        \\@end
        \\class BrowserBridge {
        \\};
        \\int bridge_main(void) {
        \\    return 0;
        \\}
    );
    try explorer.indexFile("src/App.java",
        \\package demo;
        \\import java.util.List;
        \\public class Worker {
        \\    public void run() {}
        \\}
        \\interface RunnableThing {}
        \\enum Mode { A }
        \\record Pair(int left, int right) {}
    );
    try explorer.indexFile("src/App.kt",
        \\package demo
        \\import kotlinx.coroutines.runBlocking
        \\data class User(val name: String)
        \\interface Repo
        \\enum class KotlinMode { A }
        \\fun loadUser(): User = User("a")
        \\val answer = 42
    );
    try explorer.indexFile("src/Widget.svelte",
        \\<script>
        \\import Thing from './Thing.svelte';
        \\export let title;
        \\function renderTitle() {}
        \\</script>
        \\.card { color: red; }
    );
    try explorer.indexFile("src/View.vue",
        \\<script setup>
        \\import Child from './Child.vue'
        \\const count = 0
        \\function inc() {}
        \\</script>
    );
    try explorer.indexFile("src/Page.astro",
        \\---
        \\import Layout from '../layouts/Layout.astro';
        \\const title = 'Home';
        \\---
    );
    try explorer.indexFile("scripts/build.sh",
        \\source ./env.sh
        \\function build_app() {
        \\}
        \\deploy_app() {
        \\}
        \\BUILD_MODE=release
    );
    try explorer.indexFile("styles/app.css",
        \\:root {
        \\  --brand: red;
        \\}
        \\.button {
        \\  color: var(--brand);
        \\}
        \\@keyframes fade {}
    );
    try explorer.indexFile("styles/app.scss",
        \\$gap: 8px;
        \\@mixin center {}
        \\.panel {}
    );
    try explorer.indexFile("db/schema.sql",
        \\CREATE TABLE users (id integer);
        \\CREATE OR REPLACE FUNCTION do_thing() RETURNS void AS $$ SELECT 1; $$ LANGUAGE sql;
        \\CREATE INDEX idx_users_id ON users(id);
    );
    try explorer.indexFile("api/service.proto",
        \\syntax = "proto3";
        \\import "google/protobuf/timestamp.proto";
        \\message User {}
        \\enum Status { STATUS_OK = 0; }
        \\service UserService {
        \\  rpc GetUser (User) returns (User);
        \\}
    );
    try explorer.indexFile("math/solver.f90",
        \\module solver
        \\use mathlib
        \\type :: Particle
        \\end type
        \\subroutine step()
        \\end subroutine
        \\function energy()
        \\end function
    );
    try explorer.indexFile("ir/module.ll",
        \\%Pair = type { i32, i32 }
        \\@global_value = global i32 0
        \\define i32 @main() {
        \\  ret i32 0
        \\}
    );
    try explorer.indexFile("ir/dialect.mlir",
        \\module @kernel_mod {
        \\  func.func @kernel() {
        \\    return
        \\  }
        \\}
    );
    try explorer.indexFile("llvm/records.td",
        \\include "Base.td"
        \\class Register<string name>;
        \\multiclass Pat<string op>;
        \\def R0 : Register<"r0">;
        \\defm ADD : Pat<"add">;
        \\let Namespace = "Toy";
    );

    const cc_outline = try explorer.getOutline("src/math.cc", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.cpp, cc_outline.language);
    try expectOutlineImport(&cc_outline, "vector");
    try expectOutlineSymbol(&cc_outline, "Calculator", .class_def);
    try expectOutlineSymbol(&cc_outline, "add", .function);
    try expectOutlineSymbol(&cc_outline, "free_add", .function);

    const mm_outline = try explorer.getOutline("src/Bridge.mm", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.cpp, mm_outline.language);
    try expectOutlineImport(&mm_outline, "Bridge.h");
    try expectOutlineSymbol(&mm_outline, "BrowserController", .class_def);
    try expectOutlineSymbol(&mm_outline, "loadPage", .method);
    try expectOutlineSymbol(&mm_outline, "BrowserBridge", .class_def);
    try expectOutlineSymbol(&mm_outline, "bridge_main", .function);

    const java_outline = try explorer.getOutline("src/App.java", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.java, java_outline.language);
    try expectOutlineImport(&java_outline, "java.util.List");
    try expectOutlineSymbol(&java_outline, "Worker", .class_def);
    try expectOutlineSymbol(&java_outline, "run", .method);
    try expectOutlineSymbol(&java_outline, "RunnableThing", .interface_def);
    try expectOutlineSymbol(&java_outline, "Mode", .enum_def);
    try expectOutlineSymbol(&java_outline, "Pair", .class_def);

    const kt_outline = try explorer.getOutline("src/App.kt", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.kotlin, kt_outline.language);
    try expectOutlineImport(&kt_outline, "kotlinx.coroutines.runBlocking");
    try expectOutlineSymbol(&kt_outline, "User", .class_def);
    try expectOutlineSymbol(&kt_outline, "Repo", .interface_def);
    try expectOutlineSymbol(&kt_outline, "KotlinMode", .enum_def);
    try expectOutlineSymbol(&kt_outline, "loadUser", .function);
    try expectOutlineSymbol(&kt_outline, "answer", .constant);

    const svelte_outline = try explorer.getOutline("src/Widget.svelte", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.svelte, svelte_outline.language);
    try expectOutlineImport(&svelte_outline, "./Thing.svelte");
    try expectOutlineSymbol(&svelte_outline, "title", .constant);
    try expectOutlineSymbol(&svelte_outline, "renderTitle", .function);
    try expectOutlineSymbol(&svelte_outline, ".card", .class_def);

    const vue_outline = try explorer.getOutline("src/View.vue", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.vue, vue_outline.language);
    try expectOutlineImport(&vue_outline, "./Child.vue");
    try expectOutlineSymbol(&vue_outline, "count", .constant);
    try expectOutlineSymbol(&vue_outline, "inc", .function);

    const astro_outline = try explorer.getOutline("src/Page.astro", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.astro, astro_outline.language);
    try expectOutlineImport(&astro_outline, "../layouts/Layout.astro");
    try expectOutlineSymbol(&astro_outline, "title", .constant);

    const shell_outline = try explorer.getOutline("scripts/build.sh", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.shell, shell_outline.language);
    try expectOutlineImport(&shell_outline, "./env.sh");
    try expectOutlineSymbol(&shell_outline, "build_app", .function);
    try expectOutlineSymbol(&shell_outline, "deploy_app", .function);
    try expectOutlineSymbol(&shell_outline, "BUILD_MODE", .variable);

    const css_outline = try explorer.getOutline("styles/app.css", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.css, css_outline.language);
    try expectOutlineSymbol(&css_outline, "--brand", .constant);
    try expectOutlineSymbol(&css_outline, ".button", .class_def);
    try expectOutlineSymbol(&css_outline, "fade", .function);

    const scss_outline = try explorer.getOutline("styles/app.scss", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.scss, scss_outline.language);
    try expectOutlineSymbol(&scss_outline, "$gap", .constant);
    try expectOutlineSymbol(&scss_outline, "center", .function);
    try expectOutlineSymbol(&scss_outline, ".panel", .class_def);

    const sql_outline = try explorer.getOutline("db/schema.sql", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.sql, sql_outline.language);
    try expectOutlineSymbol(&sql_outline, "users", .struct_def);
    try expectOutlineSymbol(&sql_outline, "do_thing", .function);
    try expectOutlineSymbol(&sql_outline, "idx_users_id", .constant);

    const proto_outline = try explorer.getOutline("api/service.proto", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.protobuf, proto_outline.language);
    try expectOutlineImport(&proto_outline, "google/protobuf/timestamp.proto");
    try expectOutlineSymbol(&proto_outline, "User", .struct_def);
    try expectOutlineSymbol(&proto_outline, "Status", .enum_def);
    try expectOutlineSymbol(&proto_outline, "UserService", .interface_def);
    try expectOutlineSymbol(&proto_outline, "GetUser", .method);

    const fortran_outline = try explorer.getOutline("math/solver.f90", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.fortran, fortran_outline.language);
    try expectOutlineImport(&fortran_outline, "mathlib");
    try expectOutlineSymbol(&fortran_outline, "solver", .class_def);
    try expectOutlineSymbol(&fortran_outline, "Particle", .struct_def);
    try expectOutlineSymbol(&fortran_outline, "step", .function);
    try expectOutlineSymbol(&fortran_outline, "energy", .function);

    const llvm_outline = try explorer.getOutline("ir/module.ll", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.llvm_ir, llvm_outline.language);
    try expectOutlineSymbol(&llvm_outline, "Pair", .type_alias);
    try expectOutlineSymbol(&llvm_outline, "global_value", .variable);
    try expectOutlineSymbol(&llvm_outline, "main", .function);

    const mlir_outline = try explorer.getOutline("ir/dialect.mlir", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.mlir, mlir_outline.language);
    try expectOutlineSymbol(&mlir_outline, "kernel_mod", .class_def);
    try expectOutlineSymbol(&mlir_outline, "kernel", .function);

    const td_outline = try explorer.getOutline("llvm/records.td", alloc) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Language.tablegen, td_outline.language);
    try expectOutlineImport(&td_outline, "Base.td");
    try expectOutlineSymbol(&td_outline, "Register", .class_def);
    try expectOutlineSymbol(&td_outline, "Pat", .class_def);
    try expectOutlineSymbol(&td_outline, "R0", .constant);
    try expectOutlineSymbol(&td_outline, "ADD", .constant);
    try expectOutlineSymbol(&td_outline, "Namespace", .variable);

    const worker = try explorer.findAllSymbols("Worker", alloc);
    defer alloc.free(worker);
    try testing.expectEqual(@as(usize, 1), worker.len);
    try testing.expectEqual(SymbolKind.class_def, worker[0].symbol.kind);

    const run = try explorer.findAllSymbols("run", alloc);
    defer alloc.free(run);
    try testing.expectEqual(@as(usize, 1), run.len);
    try testing.expectEqual(SymbolKind.method, run[0].symbol.kind);

    const user = try explorer.findAllSymbols("User", alloc);
    defer alloc.free(user);
    try testing.expect(user.len >= 2);

    const load_user = try explorer.findAllSymbols("loadUser", alloc);
    defer alloc.free(load_user);
    try testing.expectEqual(@as(usize, 1), load_user.len);
    try testing.expectEqual(SymbolKind.function, load_user[0].symbol.kind);

    const title = try explorer.findAllSymbols("title", alloc);
    defer alloc.free(title);
    try testing.expect(title.len >= 2);

    const build_app = try explorer.findAllSymbols("build_app", alloc);
    defer alloc.free(build_app);
    try testing.expectEqual(@as(usize, 1), build_app.len);
    try testing.expectEqual(SymbolKind.function, build_app[0].symbol.kind);

    const button = try explorer.findAllSymbols(".button", alloc);
    defer alloc.free(button);
    try testing.expectEqual(@as(usize, 1), button.len);

    const users = try explorer.findAllSymbols("users", alloc);
    defer alloc.free(users);
    try testing.expectEqual(@as(usize, 1), users.len);
    try testing.expectEqual(SymbolKind.struct_def, users[0].symbol.kind);

    const user_service = try explorer.findAllSymbols("UserService", alloc);
    defer alloc.free(user_service);
    try testing.expectEqual(@as(usize, 1), user_service.len);
    try testing.expectEqual(SymbolKind.interface_def, user_service[0].symbol.kind);

    const particle = try explorer.findAllSymbols("Particle", alloc);
    defer alloc.free(particle);
    try testing.expectEqual(@as(usize, 1), particle.len);
    try testing.expectEqual(SymbolKind.struct_def, particle[0].symbol.kind);

    const main_sym = try explorer.findAllSymbols("main", alloc);
    defer alloc.free(main_sym);
    try testing.expectEqual(@as(usize, 1), main_sym.len);
    try testing.expectEqual(SymbolKind.function, main_sym[0].symbol.kind);

    const kernel = try explorer.findAllSymbols("kernel", alloc);
    defer alloc.free(kernel);
    try testing.expectEqual(@as(usize, 1), kernel.len);
    try testing.expectEqual(SymbolKind.function, kernel[0].symbol.kind);

    const r0 = try explorer.findAllSymbols("R0", alloc);
    defer alloc.free(r0);
    try testing.expectEqual(@as(usize, 1), r0.len);
}

test "issue-179: Python inline docstring does not leak symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("mod.py",
        \\def real_func():
        \\    """This docstring contains def fake(): pass"""
        \\    return 1
    );

    const real = try explorer.findAllSymbols("real_func", alloc);
    defer alloc.free(real);
    try testing.expect(real.len == 1);

    const fake = try explorer.findAllSymbols("fake", alloc);
    defer alloc.free(fake);
    try testing.expectEqual(@as(usize, 0), fake.len);
}

test "dep-graph: transitive dependencies (forward BFS)" {
    var graph = DependencyGraph.init(testing.allocator);
    defer graph.deinit();

    // app.zig -> server.zig -> store.zig -> utils.zig
    var deps1: std.ArrayList([]const u8) = .empty;
    try deps1.append(testing.allocator, "server.zig");
    try graph.setDeps("app.zig", deps1);

    var deps2: std.ArrayList([]const u8) = .empty;
    try deps2.append(testing.allocator, "store.zig");
    try graph.setDeps("server.zig", deps2);

    var deps3: std.ArrayList([]const u8) = .empty;
    try deps3.append(testing.allocator, "utils.zig");
    try graph.setDeps("store.zig", deps3);

    // app.zig transitively depends on server.zig, store.zig, utils.zig
    const deps_all = try graph.getTransitiveDependencies("app.zig", testing.allocator, null);
    defer {
        for (deps_all) |p| testing.allocator.free(p);
        testing.allocator.free(deps_all);
    }
    try testing.expectEqual(@as(usize, 3), deps_all.len);

    // Depth=2: app.zig -> server.zig -> store.zig (not utils.zig)
    const deps_shallow = try graph.getTransitiveDependencies("app.zig", testing.allocator, 2);
    defer {
        for (deps_shallow) |p| testing.allocator.free(p);
        testing.allocator.free(deps_shallow);
    }
    try testing.expectEqual(@as(usize, 2), deps_shallow.len);
}

test "dep-graph: Explorer integration — getImportedBy uses reverse index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("store.zig", "pub const Store = struct {};");
    try explorer.indexFile("main.zig", "const store = @import(\"store.zig\");\npub fn main() void {}");
    try explorer.indexFile("server.zig", "const store = @import(\"store.zig\");\npub fn serve() void {}");

    const deps = try explorer.getImportedBy("store.zig", testing.allocator);
    defer {
        for (deps) |d| testing.allocator.free(d);
        testing.allocator.free(deps);
    }
    try testing.expectEqual(@as(usize, 2), deps.len);
}

test "dep-graph: Explorer transitive dependents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("utils.zig", "pub fn helper() void {}");
    try explorer.indexFile("store.zig", "const utils = @import(\"utils.zig\");\npub const Store = struct {};");
    try explorer.indexFile("main.zig", "const store = @import(\"store.zig\");\npub fn main() void {}");

    // Transitive: changing utils.zig affects store.zig and main.zig
    const blast = try explorer.getTransitiveDependents("utils.zig", testing.allocator, null);
    defer {
        for (blast) |b| testing.allocator.free(b);
        testing.allocator.free(blast);
    }
    try testing.expectEqual(@as(usize, 2), blast.len);
}

test "symbol-index: O(1) findSymbol via symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("math.zig", "pub fn add(a: i32, b: i32) i32 { return a + b; }\npub fn subtract(a: i32, b: i32) i32 { return a - b; }\n");
    try explorer.indexFile("utils.zig", "pub fn add(x: f64, y: f64) f64 { return x + y; }\npub fn format() void {}\n");

    // findSymbol should return first match via index
    const result = try explorer.findSymbol("add", testing.allocator);
    try testing.expect(result != null);
    const r = result.?;
    defer {
        testing.allocator.free(r.path);
        testing.allocator.free(r.symbol.name);
        if (r.symbol.detail) |d| testing.allocator.free(d);
        if (r.symbol.return_type) |rt| testing.allocator.free(rt);
        for (r.symbol.param_types) |pt| testing.allocator.free(pt);
        if (r.symbol.param_types.len > 0) testing.allocator.free(r.symbol.param_types);
    }
    try testing.expectEqualStrings("add", r.symbol.name);

    // findAllSymbols should return both
    const all = try explorer.findAllSymbols("add", testing.allocator);
    defer {
        for (all) |s| {
            testing.allocator.free(s.path);
            testing.allocator.free(s.symbol.name);
            if (s.symbol.detail) |d| testing.allocator.free(d);
            if (s.symbol.return_type) |rt| testing.allocator.free(rt);
            for (s.symbol.param_types) |pt| testing.allocator.free(pt);
            if (s.symbol.param_types.len > 0) testing.allocator.free(s.symbol.param_types);
        }
        testing.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "symbol-index: removeFile cleans symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn unique_func() void {}");
    const before = try explorer.findSymbol("unique_func", testing.allocator);
    try testing.expect(before != null);
    testing.allocator.free(before.?.path);
    testing.allocator.free(before.?.symbol.name);
    if (before.?.symbol.detail) |d| testing.allocator.free(d);
    if (before.?.symbol.return_type) |rt| testing.allocator.free(rt);
    for (before.?.symbol.param_types) |pt| testing.allocator.free(pt);
    if (before.?.symbol.param_types.len > 0) testing.allocator.free(before.?.symbol.param_types);

    explorer.removeFile("a.zig");

    const after = try explorer.findSymbol("unique_func", testing.allocator);
    try testing.expect(after == null);
}

test "symbol-index: re-index updates symbol_index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "pub fn old_name() void {}");
    const r1 = try explorer.findSymbol("old_name", testing.allocator);
    try testing.expect(r1 != null);
    testing.allocator.free(r1.?.path);
    testing.allocator.free(r1.?.symbol.name);
    if (r1.?.symbol.detail) |d| testing.allocator.free(d);
    if (r1.?.symbol.return_type) |rt| testing.allocator.free(rt);
    for (r1.?.symbol.param_types) |pt| testing.allocator.free(pt);
    if (r1.?.symbol.param_types.len > 0) testing.allocator.free(r1.?.symbol.param_types);

    // Re-index same file with different content
    try explorer.indexFile("a.zig", "pub fn new_name() void {}");
    const r2 = try explorer.findSymbol("old_name", testing.allocator);
    try testing.expect(r2 == null);

    const r3 = try explorer.findSymbol("new_name", testing.allocator);
    try testing.expect(r3 != null);
    testing.allocator.free(r3.?.path);
    testing.allocator.free(r3.?.symbol.name);
    if (r3.?.symbol.detail) |d| testing.allocator.free(d);
    if (r3.?.symbol.return_type) |rt| testing.allocator.free(rt);
    for (r3.?.symbol.param_types) |pt| testing.allocator.free(pt);
    if (r3.?.symbol.param_types.len > 0) testing.allocator.free(r3.?.symbol.param_types);
}

// ── searchInContent incremental line counting test ─────────

test "word-index: splitIdentifier snake_case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("get_or_put", &out, a);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("get", out.items[0]);
    try testing.expectEqualStrings("or", out.items[1]);
    try testing.expectEqualStrings("put", out.items[2]);
}

test "word-index: splitIdentifier camelCase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("validateToken", &out, a);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("validate", out.items[0]);
    try testing.expectEqualStrings("token", out.items[1]);
}

test "word-index: splitIdentifier acronym (HTTPHandler)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("HTTPHandler", &out, a);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("http", out.items[0]);
    try testing.expectEqualStrings("handler", out.items[1]);
}

test "word-index: splitIdentifier simple word emits itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try splitIdentifier("handler", &out, a);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("handler", out.items[0]);
}

test "word-index: case-insensitive lookup finds exact identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("a.zig", "fn validateToken() void {}");

    // Case-insensitive search for the full identifier
    const r1 = try explorer.searchContent("validatetoken", testing.allocator, 10);
    defer {
        for (r1) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(r1);
    }
    try testing.expectEqual(@as(usize, 1), r1.len);
}

// ── Prefix expansion (Tier 0.5) tests ─────────────────────────────────────

test "integration: Tier 0.5 prefix expansion finds partial identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("util.zig", "pub fn validateRequest(r: Request) bool { return true; }");

    // "validateR" is a prefix of "validaterequest" in the word index
    const results = try explorer.searchContent("validateR", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }

    try testing.expect(results.len >= 1);
}

// ── BM25 frequency scoring tests ──────────────────────────────────────────

test "issue-102: Explorer.content_cache_limit field is retained" {
    // The content_cache_limit field is preserved for API compatibility.
    // With CLOCK eviction (#208) the field no longer gates put() calls —
    // the ContentCache capacity (16384) is the actual bound.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    explorer.content_cache_limit = 2;

    try explorer.indexFile("a.zig", "pub fn a() void {}\n");
    try explorer.indexFile("b.zig", "pub fn b() void {}\n");
    try explorer.indexFile("c.zig", "pub fn c() void {}\n");
    try explorer.indexFile("d.zig", "pub fn d() void {}\n");
    try explorer.indexFile("e.zig", "pub fn e() void {}\n");

    // All 5 outlines are indexed and the cache holds all 5 (CLOCK evicts only
    // when the fixed-capacity slot array is under probe-window pressure).
    try testing.expectEqual(@as(usize, 5), explorer.outlines.count());
    try testing.expectEqual(@as(u32, 5), explorer.contents.count());
}

test "detectLanguage: SSRS extensions" {
    try testing.expect(explore.detectLanguage("Report.rdl") == .ssrs_report);
    try testing.expect(explore.detectLanguage("DataSet.rsd") == .ssrs_dataset);
    try testing.expect(explore.detectLanguage("Autumn.rds") == .ssrs_datasource);
    try testing.expect(explore.detectLanguage("Regulatory.rptproj") == .ssrs_project);
    try testing.expect(explore.detectLanguage("sub Cover (Landscape).rdl") == .ssrs_report);
}

test "SSRS parser: RDL extracts report parameters" {
    const result = ssrs_parser.parseRdlLine("    <ReportParameter Name=\"pvc_UserId\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("pvc_UserId", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_parameter);
}

test "SSRS parser: RDL extracts datasets" {
    const result = ssrs_parser.parseRdlLine("    <DataSet Name=\"GetReportEntity\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("GetReportEntity", result.symbol.name);
    try testing.expect(result.symbol.kind == .dataset);
}

test "SSRS parser: RDL extracts data sources" {
    const result = ssrs_parser.parseRdlLine("    <DataSource Name=\"Autumn\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Autumn", result.symbol.name);
    try testing.expect(result.symbol.kind == .datasource);
}

test "SSRS parser: RDL extracts variables" {
    const result = ssrs_parser.parseRdlLine("    <Variable Name=\"Expense\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Expense", result.symbol.name);
    try testing.expect(result.symbol.kind == .variable);
}

test "SSRS parser: RDL extracts subreports" {
    const result = ssrs_parser.parseRdlLine("                  <Subreport Name=\"PortfolioSummary\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("PortfolioSummary", result.symbol.name);
    try testing.expect(result.symbol.kind == .subreport);
}

test "SSRS parser: RDL extracts shared dataset references as imports" {
    const result = ssrs_parser.parseRdlLine("        <SharedDataSetReference>/Datasets/GetReportEntity</SharedDataSetReference>");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("GetReportEntity", result.import.path);
}

test "SSRS parser: RDL extracts datasource references as imports" {
    const result = ssrs_parser.parseRdlLine("      <DataSourceReference>/Data Sources/Autumn</DataSourceReference>");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("Autumn", result.import.path);
}

test "SSRS parser: RDL extracts command text" {
    const result = ssrs_parser.parseRdlLine("      <CommandText>Reporting.ReportExPost</CommandText>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Reporting.ReportExPost", result.symbol.name);
    try testing.expect(result.symbol.kind == .command_text);
}

test "SSRS parser: RDL extracts subreport refs as imports" {
    const result = ssrs_parser.parseSubreportRef("                    <ReportName>sub SA Tax Information Summary</ReportName>");
    try testing.expect(result != null);
    try testing.expectEqualStrings("sub SA Tax Information Summary", result.?);
}

test "SSRS parser: RSD extracts command text" {
    const result = ssrs_parser.parseRsdLine("      <CommandText>SELECT [Common].[GetReportEntity](@pvc_ReportEntity, @pb_Consolidate) AS ReportEntity</CommandText>");
    try testing.expect(result == .symbol);
    try testing.expect(result.symbol.kind == .command_text);
    try testing.expect(std.mem.startsWith(u8, result.symbol.name, "SELECT"));
}

test "SSRS parser: RSD extracts datasource reference" {
    const result = ssrs_parser.parseRsdLine("      <DataSourceReference>Autumn</DataSourceReference>");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("Autumn", result.import.path);
}

test "SSRS parser: RSD extracts dataset parameters" {
    const result = ssrs_parser.parseRsdLine("        <DataSetParameter Name=\"@pvc_ReportEntity\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("@pvc_ReportEntity", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_parameter);
}

test "SSRS parser: RDS extracts datasource name" {
    const result = ssrs_parser.parseRdsLine("<RptDataSource xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" Name=\"Autumn\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Autumn", result.symbol.name);
    try testing.expect(result.symbol.kind == .datasource);
}

test "SSRS parser: RDS extracts connection string" {
    const result = ssrs_parser.parseRdsLine("    <ConnectString>Data Source=sql-dbc1;Initial Catalog=Autumn</ConnectString>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Data Source=sql-dbc1;Initial Catalog=Autumn", result.symbol.name);
    try testing.expect(result.symbol.kind == .datasource);
}

test "SSRS parser: RPTPROJ extracts report items as imports" {
    const result = ssrs_parser.parseRptprojLine("    <Report Include=\"CGIX Tax Certificates.rdl\" />");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("CGIX Tax Certificates.rdl", result.import.path);
}

test "SSRS parser: RPTPROJ extracts dataset items as imports" {
    const result = ssrs_parser.parseRptprojLine("    <DataSet Include=\"GetDate.rsd\" />");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("GetDate.rsd", result.import.path);
}

test "SSRS parser: RPTPROJ extracts datasource items as imports" {
    const result = ssrs_parser.parseRptprojLine("    <DataSource Include=\"Autumn.rds\" />");
    try testing.expect(result == .import);
    try testing.expectEqualStrings("Autumn.rds", result.import.path);
}

test "SSRS parser: RDL ignores non-matching lines" {
    // <Style> is layout markup, not a semantic element — should not produce a symbol.
    const result = ssrs_parser.parseRdlLine("      <Style><Border><Color>#000000</Color></Border></Style>");
    try testing.expect(result == .none);
}

test "SSRS parser: RDL extractDetail for report_parameter" {
    var buf: [256]u8 = undefined;
    const detail = ssrs_parser.extractDetail("      <DataType>String</DataType>", .report_parameter, &buf);
    try testing.expectEqualStrings("String", detail);
}

test "SSRS parser: integration — index RDL via Explorer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    const rdl_content =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <DataSources>
        \\    <DataSource Name="Autumn">
        \\      <DataSourceReference>/Data Sources/Autumn</DataSourceReference>
        \\    </DataSource>
        \\  </DataSources>
        \\  <DataSets>
        \\    <DataSet Name="GetDate">
        \\      <SharedDataSet>
        \\        <SharedDataSetReference>/Datasets/GetDate</SharedDataSetReference>
        \\      </SharedDataSet>
        \\    </DataSet>
        \\  </DataSets>
        \\  <ReportParameters>
        \\    <ReportParameter Name="pvc_FromDate">
        \\      <DataType>String</DataType>
        \\    </ReportParameter>
        \\  </ReportParameters>
        \\</Report>
    ;

    try explorer.indexFile("TestReport.rdl", rdl_content);
    const outline = explorer.outlines.get("TestReport.rdl").?;

    try testing.expectEqual(explore.Language.ssrs_report, outline.language);

    // Should have symbols: DataSource, DataSet, ReportParameter
    var found_datasource = false;
    var found_dataset = false;
    var found_param = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Autumn") and sym.kind == .variable) found_datasource = true;
        if (std.mem.eql(u8, sym.name, "GetDate") and sym.kind == .variable) found_dataset = true;
        if (std.mem.eql(u8, sym.name, "pvc_FromDate") and sym.kind == .variable) found_param = true;
    }
    try testing.expect(found_datasource);
    try testing.expect(found_dataset);
    try testing.expect(found_param);

    // Should have imports: Autumn, GetDate
    var found_rds_import = false;
    var found_rsd_import = false;
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, "Autumn")) found_rds_import = true;
        if (std.mem.eql(u8, imp, "GetDate")) found_rsd_import = true;
    }
    try testing.expect(found_rds_import);
    try testing.expect(found_rsd_import);
}

test "SSRS parser: integration — index RPTPROJ via Explorer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    const proj_content =
        \\<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
        \\  <ItemGroup>
        \\    <DataSet Include="GetDate.rsd" />
        \\    <DataSet Include="GetReportEntity.rsd" />
        \\  </ItemGroup>
        \\  <ItemGroup>
        \\    <DataSource Include="Autumn.rds" />
        \\  </ItemGroup>
        \\  <ItemGroup>
        \\    <Report Include="ExPostCostAndCharges.rdl" />
        \\    <Report Include="CGIX Tax Pack.rdl" />
        \\  </ItemGroup>
        \\</Project>
    ;

    try explorer.indexFile("Regulatory.rptproj", proj_content);
    const outline = explorer.outlines.get("Regulatory.rptproj").?;

    try testing.expectEqual(explore.Language.ssrs_project, outline.language);

    // All items should be imports
    try testing.expect(outline.imports.items.len == 5);
    var found_report = false;
    var found_dataset = false;
    var found_datasource = false;
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, "ExPostCostAndCharges.rdl")) found_report = true;
        if (std.mem.eql(u8, imp, "GetDate.rsd")) found_dataset = true;
        if (std.mem.eql(u8, imp, "Autumn.rds")) found_datasource = true;
    }
    try testing.expect(found_report);
    try testing.expect(found_dataset);
    try testing.expect(found_datasource);
}

// ── Tier 1: single-line parser additions ───────────────────────────

test "SSRS parser: RDL extracts Author metadata" {
    const result = ssrs_parser.parseRdlLine("      <Author>Credo Capital Plc</Author>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Author", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDL extracts Language metadata" {
    const result = ssrs_parser.parseRdlLine("      <Language>en-GB</Language>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Language", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDL extracts rd:ReportID" {
    const result = ssrs_parser.parseRdlLine("  <rd:ReportID>abc-123-def</rd:ReportID>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("ReportID", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDL extracts rd:ReportServerUrl" {
    const result = ssrs_parser.parseRdlLine("  <rd:ReportServerUrl>http://ssrs-prod/reportserver</rd:ReportServerUrl>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("ReportServerUrl", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDL extracts Description (plain text)" {
    const result = ssrs_parser.parseRdlLine("      <Description>Cash statement for a given period</Description>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Description", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDL extracts Field" {
    const result = ssrs_parser.parseRdlLine("        <Field Name=\"ReportEntity\">");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("ReportEntity", result.symbol.name);
    try testing.expect(result.symbol.kind == .variable);
}

test "SSRS parser: RSD extracts CommandType" {
    const result = ssrs_parser.parseRsdLine("        <CommandType>StoredProcedure</CommandType>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("CommandType", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RDS extracts Extension" {
    const result = ssrs_parser.parseRdsLine("      <Extension>SQL</Extension>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("Extension", result.symbol.name);
    try testing.expect(result.symbol.kind == .report_metadata);
}

test "SSRS parser: RPTPROJ extracts TargetReportFolder" {
    const result = ssrs_parser.parseRptprojLine("    <TargetReportFolder>Pro_Portfolio</TargetReportFolder>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("TargetReportFolder", result.symbol.name);
    try testing.expect(result.symbol.kind == .rptproj_property);
}

test "SSRS parser: RPTPROJ extracts TargetServerURL" {
    const result = ssrs_parser.parseRptprojLine("    <TargetServerURL>http://ssrs-prod/reportserver</TargetServerURL>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("TargetServerURL", result.symbol.name);
    try testing.expect(result.symbol.kind == .rptproj_property);
}

test "SSRS parser: RPTPROJ extracts TargetServerVersion" {
    const result = ssrs_parser.parseRptprojLine("    <TargetServerVersion>SSRS2016</TargetServerVersion>");
    try testing.expect(result == .symbol);
    try testing.expectEqualStrings("TargetServerVersion", result.symbol.name);
    try testing.expect(result.symbol.kind == .rptproj_property);
}

test "SSRS parser: extractDetail for Author metadata" {
    var buf: [256]u8 = undefined;
    const detail = ssrs_parser.extractDetail("      <Author>Credo Capital Plc</Author>", .report_metadata, &buf);
    try testing.expectEqualStrings("Credo Capital Plc", detail);
}

test "SSRS parser: extractDetail for Description (plain text)" {
    var buf: [256]u8 = undefined;
    const detail = ssrs_parser.extractDetail(
        "      <Description>Cash statement for a given period</Description>",
        .report_metadata,
        &buf,
    );
    try testing.expectEqualStrings("Cash statement for a given period", detail);
}

test "SSRS parser: extractDetail for Description (pipe-delimited)" {
    var buf: [512]u8 = undefined;
    const detail = ssrs_parser.extractDetail(
        "      <Description>Section|Pro_Portfolio|Group|Report Packs|Description|Periodic report|Image|chart-line|Orientation|Portrait|</Description>",
        .report_metadata,
        &buf,
    );
    // Should contain parsed keys (lowercased) and known values.
    try testing.expect(std.mem.indexOf(u8, detail, "section=Pro_Portfolio") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "orientation=Portrait") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "description=Periodic report") != null);
}

test "SSRS parser: extractDetail for rptproj_property" {
    var buf: [256]u8 = undefined;
    const detail = ssrs_parser.extractDetail(
        "    <TargetServerVersion>SSRS2016</TargetServerVersion>",
        .rptproj_property,
        &buf,
    );
    try testing.expectEqualStrings("SSRS2016", detail);
}

// ── Tier 2: post-pass enrichment (via parseContentForIndexing) ──────

test "SSRS post-pass: enriches multiline Description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Multiline description (one of the cases the line parser can't fully handle).
    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <Description>Section|Pro_Portfolio|Group|Report Packs|Description|Periodic report for compliance|Image|chart-line|Orientation|Portrait|</Description>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    var found_description = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Description")) {
            found_description = true;
            if (sym.detail) |d| {
                try testing.expect(std.mem.indexOf(u8, d, "section=Pro_Portfolio") != null);
                try testing.expect(std.mem.indexOf(u8, d, "orientation=Portrait") != null);
            } else {
                return error.MissingDetail;
            }
        }
    }
    try testing.expect(found_description);
}

test "SSRS post-pass: AXYS DataSource emits macro symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <DataSources>
        \\    <DataSource Name="dsCashStatement">
        \\      <ConnectionProperties>
        \\        <DataProvider>AXYS</DataProvider>
        \\        <ConnectString>="REPRUN -m_rp_test.mac -q -u " &amp; Chr(34) &amp; Parameters!pvc_FromDate.Value &amp; Chr(34)</ConnectString>
        \\      </ConnectionProperties>
        \\    </DataSource>
        \\  </DataSources>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    // The AXYS macro symbol should be emitted (named after the .mac file).
    var found_macro = false;
    var macro_has_flag = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "rp_test.mac")) {
            found_macro = true;
            try testing.expect(sym.kind == .constant);
            if (sym.detail) |d| {
                // Detail is the flags bag or "axys macro" fallback.
                if (std.mem.indexOf(u8, d, "-q") != null) macro_has_flag = true;
                if (std.mem.indexOf(u8, d, "-u") != null) macro_has_flag = true;
            }
        }
    }
    try testing.expect(found_macro);
    try testing.expect(macro_has_flag);

    // The parent DataSource symbol should have an "AXYS ->" detail.
    var ds_detail_patched = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "dsCashStatement")) {
            if (sym.detail) |d| {
                if (std.mem.indexOf(u8, d, "AXYS ->") != null) ds_detail_patched = true;
            }
        }
    }
    try testing.expect(ds_detail_patched);
}

test "SSRS post-pass: <Code> block emits VB functions with body ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <Code>
        \\    Function FormatDateMMDDYY(dtDate As DateTime) As String
        \\        Return dtDate.ToString("MMddy")
        \\    End Function
        \\
        \\    Function GetTruncatedValue(Value As Decimal, DecimalPoints As Integer) As Decimal
        \\        Return Math.Round(Value, DecimalPoints)
        \\    End Function
        \\  </Code>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    var found_format = false;
    var found_trunc = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "FormatDateMMDDYY")) {
            found_format = true;
            try testing.expect(sym.kind == .function);
            // line_end must be > line_start (the End Function line).
            try testing.expect(sym.line_end > sym.line_start);
        }
        if (std.mem.eql(u8, sym.name, "GetTruncatedValue")) {
            found_trunc = true;
            try testing.expect(sym.kind == .function);
            try testing.expect(sym.line_end > sym.line_start);
        }
    }
    try testing.expect(found_format);
    try testing.expect(found_trunc);
}

test "SSRS post-pass: VB function with Private modifier still matched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <Code>
        \\    Private Function IsDev(srv As String) As Boolean
        \\        Return srv.Contains("dev")
        \\    End Function
        \\  </Code>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    var found = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "IsDev")) {
            found = true;
            try testing.expect(sym.kind == .function);
        }
    }
    try testing.expect(found);
}

test "SSRS post-pass: VB Sub (not Function) matched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <Code>
        \\    Sub LogEvent(msg As String)
        \\        ' side-effect only
        \\    End Sub
        \\  </Code>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    var found = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "LogEvent")) found = true;
    }
    try testing.expect(found);
}

test "SSRS post-pass: ReportParameter enriched with DataType + Hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <ReportParameters>
        \\    <ReportParameter Name="pvc_FromDate">
        \\      <DataType>String</DataType>
        \\      <Hidden>true</Hidden>
        \\      <DefaultValue>
        \\        <Values>
        \\          <Value>=FormatDateMMDDYY(Today())</Value>
        \\        </Values>
        \\      </DefaultValue>
        \\    </ReportParameter>
        \\  </ReportParameters>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    var found = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "pvc_FromDate")) {
            found = true;
            if (sym.detail) |d| {
                try testing.expect(std.mem.indexOf(u8, d, "String") != null);
                try testing.expect(std.mem.indexOf(u8, d, "hidden") != null);
                try testing.expect(std.mem.indexOf(u8, d, "default=") != null);
            } else {
                return error.MissingDetail;
            }
        }
    }
    try testing.expect(found);
}

test "SSRS post-pass: RSD QueryParameter default enriched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rsd =
        \\<DataSet Name="GetDate">
        \\  <Query>
        \\    <DataSourceReference>Autumn</DataSourceReference>
        \\    <QueryParameters>
        \\      <QueryParameter Name="@pvc_FromDate">
        \\        <Value>=Parameters!pvc_FromDate.Value</Value>
        \\      </QueryParameter>
        \\    </QueryParameters>
        \\  </Query>
        \\</DataSet>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rsd", rsd);
    defer parsed.deinit();

    var found = false;
    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "@pvc_FromDate")) {
            found = true;
            if (sym.detail) |d| {
                try testing.expect(std.mem.indexOf(u8, d, "default=") != null);
            }
        }
    }
    try testing.expect(found);
}

test "SSRS post-pass: RDS ConnectString enriched with server/database" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rds =
        \\<RptDataSource xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" Name="Autumn">
        \\  <ConnectionProperties>
        \\    <Extension>SQL</Extension>
        \\    <ConnectString>Data Source=sql-dbc1;Initial Catalog=Autumn</ConnectString>
        \\  </ConnectionProperties>
        \\</RptDataSource>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Autumn.rds", rds);
    defer parsed.deinit();

    // The ConnectString symbol should have a server=/db= detail summary.
    var found_patched = false;
    for (parsed.outline.symbols.items) |sym| {
        if (sym.detail) |d| {
            if (std.mem.indexOf(u8, d, "server=sql-dbc1") != null and
                std.mem.indexOf(u8, d, "db=Autumn") != null)
            {
                found_patched = true;
            }
        }
    }
    try testing.expect(found_patched);
}

test "SSRS post-pass: shared DataSource (no inline ConnectString) leaves no AXYS symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <DataSources>
        \\    <DataSource Name="Autumn">
        \\      <DataSourceReference>/Data Sources/Autumn</DataSourceReference>
        \\    </DataSource>
        \\  </DataSources>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    // No macro should be synthesized for a shared reference.
    for (parsed.outline.symbols.items) |sym| {
        if (sym.kind == .constant) {
            return error.UnexpectedConstantSymbol;
        }
    }
}

test "SSRS post-pass: SQL ConnectString (non-AXYS) leaves no macro symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <DataSources>
        \\    <DataSource Name="SqlDS">
        \\      <ConnectionProperties>
        \\        <DataProvider>SQL</DataProvider>
        \\        <ConnectString>Data Source=sql-prod;Initial Catalog=Reports</ConnectString>
        \\      </ConnectionProperties>
        \\    </DataSource>
        \\  </DataSources>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    for (parsed.outline.symbols.items) |sym| {
        if (sym.kind == .constant) {
            return error.UnexpectedConstantSymbol;
        }
    }
}

test "SSRS post-pass: malformed <Code> block (no End Function) emits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rdl =
        \\<Report xmlns="http://schemas.microsoft.com/sqlserver/reporting/2016/01/reportdefinition">
        \\  <Code>
        \\    Function Orphaned(arg As String) As String
        \\      ' no End Function follows
        \\  </Code>
        \\</Report>
    ;

    var parsed = try Explorer.parseContentForIndexing(alloc, "Test.rdl", rdl);
    defer parsed.deinit();

    for (parsed.outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Orphaned")) {
            return error.UnexpectedEmittedFunction;
        }
    }
}
