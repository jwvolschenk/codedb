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

test "issue-301: Dart / Flutter parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("lib/home_screen.dart",
        \\import 'package:flutter/material.dart';
        \\export 'src/helpers.dart';
        \\part 'home_screen.g.dart';
        \\
        \\typedef ItemBuilder = Widget Function(BuildContext context);
        \\
        \\abstract class HomeScreen extends StatelessWidget {
        \\  @override
        \\  Widget build(BuildContext context) {
        \\    return const Placeholder();
        \\  }
        \\}
        \\
        \\mixin Loader on State<StatefulWidget> {
        \\  Future<void> loadData() async {}
        \\}
        \\
        \\extension ContextX on BuildContext {
        \\  ThemeData get theme => Theme.of(this);
        \\}
        \\
        \\enum LoadState { idle, loading }
        \\
        \\const String appTitle = 'codedb';
    );

    var outline = (try explorer.getOutline("lib/home_screen.dart", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expectEqual(Language.dart, outline.language);
    try testing.expectEqual(@as(usize, 3), outline.imports.items.len);

    var found_typedef = false;
    var found_class = false;
    var found_mixin = false;
    var found_extension = false;
    var found_enum = false;
    var found_build = false;
    var found_load = false;
    var found_const = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .type_alias and std.mem.eql(u8, sym.name, "ItemBuilder")) found_typedef = true;
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "HomeScreen")) found_class = true;
        if (sym.kind == .trait_def and std.mem.eql(u8, sym.name, "Loader")) found_mixin = true;
        if (sym.kind == .impl_block and std.mem.eql(u8, sym.name, "ContextX")) found_extension = true;
        if (sym.kind == .enum_def and std.mem.eql(u8, sym.name, "LoadState")) found_enum = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "build")) found_build = true;
        if (sym.kind == .function and std.mem.eql(u8, sym.name, "loadData")) found_load = true;
        if (sym.kind == .constant and std.mem.eql(u8, sym.name, "appTitle")) found_const = true;
    }
    try testing.expect(found_typedef);
    try testing.expect(found_class);
    try testing.expect(found_mixin);
    try testing.expect(found_extension);
    try testing.expect(found_enum);
    try testing.expect(found_build);
    try testing.expect(found_load);
    try testing.expect(found_const);

    const tree = try explorer.getTree(testing.allocator, false);
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "home_screen.dart  dart") != null);
}

// ── Version tests ───────────────────────────────────────────

test "isCommentOrBlank: dart comments" {
    try testing.expect(isCommentOrBlank("  // dart comment", .dart));
    try testing.expect(isCommentOrBlank("  /* dart block comment */", .dart));
    try testing.expect(!isCommentOrBlank("  class WidgetBuilder {}", .dart));
}

test "issue-151: Ruby class, module, and def" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("app.rb",
        \\require "json"
        \\require_relative "./helpers"
        \\
        \\module Authentication
        \\  class User
        \\    def initialize(name)
        \\      @name = name
        \\    end
        \\
        \\    def greet
        \\      puts "hello"
        \\    end
        \\  end
        \\end
    );

    var outline = (try explorer.getOutline("app.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    var struct_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
        if (sym.kind == .struct_def) struct_count += 1;
    }
    try testing.expect(func_count == 2); // initialize + greet
    try testing.expect(struct_count == 2); // Authentication + User
    try testing.expect(outline.imports.items.len == 2); // json + ./helpers
}

test "issue-151: Ruby =begin/=end comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.rb",
        \\def real_method
        \\  true
        \\end
        \\=begin
        \\def fake_method
        \\  false
        \\end
        \\=end
    );

    var outline = (try explorer.getOutline("commented.rb", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expect(func_count == 1); // only real_method
}

test "issue-301: Dart block comments skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("commented.dart",
        \\class RealWidget {}
        \\/*
        \\class FakeWidget {}
        \\void fakeHelper() {}
        \\*/
    );

    var outline = (try explorer.getOutline("commented.dart", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var class_count: usize = 0;
    var func_count: usize = 0;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def) class_count += 1;
        if (sym.kind == .function) func_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), class_count);
    try testing.expectEqual(@as(usize, 0), func_count);
}

test "issue-108: HCL resource block parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\resource "aws_instance" "web" {
        \\  ami = "abc-123"
        \\}
    );
    const results = try explorer.findAllSymbols("web", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
    try testing.expectEqual(SymbolKind.struct_def, results[0].symbol.kind);
}

test "issue-108: HCL variable and output parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("vars.tf",
        \\variable "region" {
        \\  default = "us-east-1"
        \\}
        \\output "ip" {
        \\  value = aws_instance.web.public_ip
        \\}
    );
    const vars = try explorer.findAllSymbols("region", alloc);
    defer alloc.free(vars);
    try testing.expect(vars.len == 1);
    try testing.expectEqual(SymbolKind.variable, vars[0].symbol.kind);
    const outs = try explorer.findAllSymbols("ip", alloc);
    defer alloc.free(outs);
    try testing.expect(outs.len == 1);
    try testing.expectEqual(SymbolKind.constant, outs[0].symbol.kind);
}

test "issue-108: HCL module and provider parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\provider "aws" {
        \\  region = "us-east-1"
        \\}
        \\module "vpc" {
        \\  source = "./modules/vpc"
        \\}
    );
    const providers = try explorer.findAllSymbols("aws", alloc);
    defer alloc.free(providers);
    try testing.expect(providers.len == 1);
    const mods = try explorer.findAllSymbols("vpc", alloc);
    defer alloc.free(mods);
    try testing.expect(mods.len == 1);
}

test "issue-108: HCL comment lines skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);
    try explorer.indexFile("main.tf",
        \\# This is a comment
        \\// Another comment
        \\variable "name" {}
    );
    const results = try explorer.findAllSymbols("name", alloc);
    defer alloc.free(results);
    try testing.expect(results.len == 1);
}

test "issue-392: Swift parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Sources/App/Greeter.swift",
        \\import Foundation
        \\import UIKit
        \\
        \\public struct Greeter {
        \\    let name: String
        \\
        \\    public func greet() -> String {
        \\        return "Hello, \(name)"
        \\    }
        \\}
        \\
        \\public class HomeViewController: UIViewController {
        \\    public override func viewDidLoad() {
        \\        super.viewDidLoad()
        \\    }
        \\}
        \\
        \\public protocol Reloadable {
        \\    func reload()
        \\}
        \\
        \\public enum LoadState {
        \\    case idle
        \\    case loading
        \\}
        \\
        \\public func topLevel() -> Int { return 42 }
    );

    var outline = (try explorer.getOutline("Sources/App/Greeter.swift", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    // Detected language must surface as "swift" — main has no Language.swift,
    // so the file falls into .unknown and no parser runs.
    try testing.expectEqualStrings("swift", @tagName(outline.language));

    var found_struct = false;
    var found_class = false;
    var found_protocol = false;
    var found_enum = false;
    var found_top_fn = false;
    var found_method = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Greeter")) found_struct = true;
        if (std.mem.eql(u8, sym.name, "HomeViewController")) found_class = true;
        if (std.mem.eql(u8, sym.name, "Reloadable")) found_protocol = true;
        if (std.mem.eql(u8, sym.name, "LoadState")) found_enum = true;
        if (std.mem.eql(u8, sym.name, "topLevel")) found_top_fn = true;
        if (std.mem.eql(u8, sym.name, "greet")) found_method = true;
    }
    try testing.expect(found_struct);
    try testing.expect(found_class);
    try testing.expect(found_protocol);
    try testing.expect(found_enum);
    try testing.expect(found_top_fn);
    try testing.expect(found_method);
}
