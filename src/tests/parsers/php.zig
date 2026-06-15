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

test "issue-php-1: PHP class definition herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Models/Candidate.php",
        \\<?php
        \\
        \\namespace App\Models;
        \\
        \\class Candidate
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/Candidate.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Candidate")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-2: PHP methode binnen class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Models/User.php",
        \\<?php
        \\
        \\class User
        \\{
        \\    public function boot()
        \\    {
        \\    }
        \\
        \\    protected function scopeActive($query)
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Models/User.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
}

test "issue-php-3: PHP top-level functie herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("helpers.php",
        \\<?php
        \\
        \\function myHelper($arg)
        \\{
        \\}
        \\
        \\function boot()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("helpers.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var fn_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) fn_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), fn_count);
}

test "issue-php-4: PHP interface herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Contracts/Payable.php",
        \\<?php
        \\
        \\interface Payable
        \\{
        \\    public function charge();
        \\}
    );

    var outline = (try explorer.getOutline("app/Contracts/Payable.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .interface_def and std.mem.eql(u8, sym.name, "Payable")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-5: PHP trait herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Traits/HasSlug.php",
        \\<?php
        \\
        \\trait HasSlug
        \\{
        \\    public function generateSlug()
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Traits/HasSlug.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .trait_def and std.mem.eql(u8, sym.name, "HasSlug")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-6: PHP use-import omgezet naar pad in dep_graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Http/Controllers/CandidateController.php",
        \\<?php
        \\
        \\use App\Models\Candidate;
        \\use Illuminate\Support\Facades\DB;
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/CandidateController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 2), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[0]);
    try testing.expectEqualStrings("illuminate/Support/Facades/DB.php", outline.imports.items[1]);
}

test "issue-php-7: PHP commentaarregels worden overgeslagen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Commented.php",
        \\<?php
        \\
        \\// function fakeFunction()
        \\# function anotherFake()
        \\/* function blockComment() */
        \\
        \\class RealClass
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .class_def);
}

test "issue-php-8: PHP function after class is top-level, not method" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/mixed.php",
        \\<?php
        \\
        \\class Foo
        \\{
        \\    public function bar()
        \\    {
        \\    }
        \\}
        \\
        \\function helper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/mixed.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-9: PHP 8.1 enum herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Enums/Status.php",
        \\<?php
        \\
        \\enum Status: string
        \\{
        \\    public function label(): string
        \\    {
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("app/Enums/Status.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found_enum = false;
    var found_method = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .enum_def and std.mem.eql(u8, sym.name, "Status")) found_enum = true;
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "label")) found_method = true;
    }
    try testing.expect(found_enum);
    try testing.expect(found_method);
}

test "issue-php-10: PHP grouped use-statement parsed into individual imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Http/Controllers/TestController.php",
        \\<?php
        \\
        \\use App\Models\{User, Candidate, Role};
    );

    var outline = (try explorer.getOutline("app/Http/Controllers/TestController.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.symbols.items.len);
    try testing.expect(outline.symbols.items[0].kind == .import);
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Models/Candidate.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Models/Role.php", outline.imports.items[2]);
}

test "issue-php-11: PHP readonly class herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/ValueObjects/Money.php",
        \\<?php
        \\
        \\readonly class Money
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/ValueObjects/Money.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var found = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Money")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "issue-php-12: PHP class and public constants herkend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Config.php",
        \\<?php
        \\
        \\class Config
        \\{
        \\    public const VERSION = '1.0';
        \\    const MAX_RETRIES = 3;
        \\    private const SECRET = 'abc';
        \\}
    );

    var outline = (try explorer.getOutline("app/Config.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var constant_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .constant) constant_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), constant_count);
}

test "issue-php-13: PHP nested braces in methods do not break class tracking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Complex.php",
        \\<?php
        \\
        \\class Complex
        \\{
        \\    public function process()
        \\    {
        \\        if ($x) {
        \\            foreach ($items as $item) {
        \\                echo "}";
        \\            }
        \\        }
        \\    }
        \\
        \\    public function another()
        \\    {
        \\    }
        \\}
        \\
        \\function outsideHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Complex.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-14: PHP multi-line block comments do not produce symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Commented.php",
        \\<?php
        \\
        \\class Real
        \\{
        \\}
        \\
        \\/*
        \\function fake() {
        \\}
        \\class Ghost {
        \\}
        \\*/
        \\
        \\function afterComment()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Commented.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var class_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def) class_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), class_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-15: PHP use-as alias stripped from import path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Controllers/Test.php",
        \\<?php
        \\
        \\use App\Models\User as UserModel;
    );

    var outline = (try explorer.getOutline("app/Controllers/Test.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 1), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
}

test "issue-php-16: PHP escaped quotes do not end string mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Escaped.php",
        \\<?php
        \\
        \\class Formatter
        \\{
        \\    public function render()
        \\    {
        \\        echo "she said \"}\"";
        \\    }
        \\
        \\    public function other()
        \\    {
        \\    }
        \\}
        \\
        \\function freeHelper()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Escaped.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var method_count: usize = 0;
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .method) method_count += 1;
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_count);
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-17: PHP code after block comment terminator is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Services/Inline.php",
        \\<?php
        \\
        \\/*
        \\function fake() {
        \\}
        \\*/ function realFunc()
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("app/Services/Inline.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var function_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) function_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), function_count);
}

test "issue-php-18: PHP use-as alias case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app/Controllers/CaseTest.php",
        \\<?php
        \\
        \\use App\Models\User AS UserModel;
        \\use App\Services\{Cache AS CacheAlias, Logger};
    );

    var outline = (try explorer.getOutline("app/Controllers/CaseTest.php", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);
    try testing.expectEqualStrings("app/Models/User.php", outline.imports.items[0]);
    try testing.expectEqualStrings("app/Services/Cache.php", outline.imports.items[1]);
    try testing.expectEqualStrings("app/Services/Logger.php", outline.imports.items[2]);
}
