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

test "fsharp parser: outlines modules imports types functions and members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Domain.fs",
        \\namespace Demo.Core
        \\
        \\open System
        \\open System.Collections.Generic
        \\
        \\[<CLIMutable>]
        \\type Person<'T> = {
        \\    Name: string
        \\    Value: 'T
        \\}
        \\
        \\type Greeter(name: string) =
        \\    member _.Greet(target: string) = $"Hello {target}"
        \\    static member Create name = Greeter(name)
        \\
        \\module Helpers =
        \\    let private normalize input = input |> string
        \\    let rec factorial n = if n <= 1 then 1 else n * factorial (n - 1)
    );

    var outline = (try explorer.getOutline("src/Domain.fs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("System", outline.imports.items[0]);
    try testing.expectEqualStrings("System.Collections.Generic", outline.imports.items[1]);

    var found_namespace = false;
    var found_person = false;
    var found_greeter = false;
    var found_greet = false;
    var found_create = false;
    var found_helpers = false;
    var found_normalize = false;
    var found_factorial = false;

    for (outline.symbols.items) |sym| {
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Demo.Core")) found_namespace = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Person")) found_person = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Greeter")) found_greeter = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Greet")) found_greet = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Create")) found_create = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Helpers")) found_helpers = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "normalize")) found_normalize = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "factorial")) found_factorial = true;
    }

    try testing.expect(found_namespace);
    try testing.expect(found_person);
    try testing.expect(found_greeter);
    try testing.expect(found_greet);
    try testing.expect(found_create);
    try testing.expect(found_helpers);
    try testing.expect(found_normalize);
    try testing.expect(found_factorial);
}

test "fsharp parser: skips comments attributes and parses abstract members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Contracts.fsi",
        \\module Demo.Contracts
        \\
        \\// type Fake = class end
        \\(*
        \\type AlsoFake = class end
        \\let fakeFunction x = x
        \\*)
        \\
        \\[<Interface>]
        \\type IService =
        \\    abstract Run : unit -> unit
        \\    abstract member Stop : unit -> unit
        \\
        \\and Result =
        \\    | Success
        \\    | Failure of string
    );

    var outline = (try explorer.getOutline("src/Contracts.fsi", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_module = false;
    var found_service = false;
    var found_run = false;
    var found_stop = false;
    var found_result = false;
    var found_fake = false;

    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Fake") or std.mem.eql(u8, sym.name, "AlsoFake") or std.mem.eql(u8, sym.name, "fakeFunction")) found_fake = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Demo.Contracts")) found_module = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "IService")) found_service = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Run")) found_run = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Stop")) found_stop = true;
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "Result")) found_result = true;
    }

    try testing.expect(!found_fake);
    try testing.expect(found_module);
    try testing.expect(found_service);
    try testing.expect(found_run);
    try testing.expect(found_stop);
    try testing.expect(found_result);
}

test "fsharp parser: handles complex state (nested comments, triple quotes, verbatim strings)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Complex.fs",
        \\module ``Complex Module``
        \\
        \\(* Nested comment
        \\   (* inner *)
        \\   let hidden = 1
        \\*)
        \\
        \\let tripleQuote = """This is a "triple-quoted" string"""
        \\let verbatim = @"Verbatim ""quote"" here"
        \\
        \\[<
        \\  Attribute(
        \\    "multiline"
        \\  )
        \\>]
        \\let decoratedFunction x = x
        \\
        \\let ``Backticked Name`` y = y
    );

    var outline = (try explorer.getOutline("src/Complex.fs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_module = false;
    var found_triple = false;
    var found_verbatim = false;
    var found_decorated = false;
    var found_backticked = false;
    var found_hidden = false;

    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "``Complex Module``")) found_module = true;
        if (std.mem.eql(u8, sym.name, "tripleQuote")) found_triple = true;
        if (std.mem.eql(u8, sym.name, "verbatim")) found_verbatim = true;
        if (std.mem.eql(u8, sym.name, "decoratedFunction")) found_decorated = true;
        if (std.mem.eql(u8, sym.name, "``Backticked Name``")) found_backticked = true;
        if (std.mem.eql(u8, sym.name, "hidden")) found_hidden = true;
    }

    try testing.expect(found_module);
    try testing.expect(found_triple);
    try testing.expect(found_verbatim);
    try testing.expect(found_decorated);
    try testing.expect(found_backticked);
    try testing.expect(!found_hidden);
}

test "fsharp parser: handles mutually recursive functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Recursive.fs",
        \\let rec odd n =
        \\    if n = 0 then false
        \\    else even (n - 1)
        \\and even n =
        \\    if n = 0 then true
        \\    else odd (n - 1)
    );

    var outline = (try explorer.getOutline("src/Recursive.fs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_odd = false;
    var found_even = false;

    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "odd")) found_odd = true;
        if (std.mem.eql(u8, sym.name, "even")) found_even = true;
    }

    try testing.expect(found_odd);
    try testing.expect(found_even);
}

test "fsharp parser: handles leading block comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Comments.fs",
        \\(* leading *) let x = 1
        \\(* multiline
        \\   block *) let y = 2
    );

    var outline = (try explorer.getOutline("src/Comments.fs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_x = false;
    var found_y = false;

    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "x")) found_x = true;
        if (std.mem.eql(u8, sym.name, "y")) found_y = true;
    }

    try testing.expect(found_x);
    try testing.expect(found_y);
}
