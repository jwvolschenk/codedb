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

test "csharp parser: outlines modern declarations and member shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/Modern.cs",
        \\extern alias Legacy;
        \\global using System.Net.Http;
        \\global using JsonNode = System.Text.Json.Nodes.JsonNode;
        \\using System;
        \\using Text = System.Text;
        \\using static System.Math;
        \\
        \\namespace Demo.Core;
        \\
        \\[Obsolete] public partial record class Customer<T>(T Value);
        \\public readonly record struct Money(decimal Amount);
        \\public class Widget(string name, int count) { }
        \\public interface IRepository<T> { }
        \\public interface IQualifiedContracts
        \\{
        \\    System.Threading.Tasks.Task<System.Collections.Generic.IReadOnlyList<string>> LoadAllAsync();
        \\    global::System.String? Format(System.Guid id);
        \\}
        \\public interface IExplicitWorker
        \\{
        \\    System.Threading.Tasks.Task ExecuteExplicitAsync();
        \\}
        \\public enum Status { Active }
        \\public delegate Task Handler<T>(T input);
        \\
        \\public class Service : IRepository<string>, IExplicitWorker
        \\{
        \\    private const string Url = "https://example.test/api";
        \\    public event EventHandler? Changed;
        \\    public string Name { get; init; }
        \\    public Task<Result<T>> LoadAsync<T>(string id) => Task.FromResult(default(Result<T>));
        \\    public async Task<Result<T>> SaveAsync<T>(
        \\        string id,
        \\        T value,
        \\        CancellationToken cancellationToken
        \\    )
        \\    {
        \\        return await LoadAsync<T>(id);
        \\    }
        \\    public T Create<T>() where T : new() => new T();
        \\    public Service(string name) { }
        \\    public void DisposeWork() { using var temp = Open(); using (var other = Open()) { } }
        \\    public string this[int index] { get => Name; }
        \\    public static explicit operator int(Service service) => 0;
        \\    System.Threading.Tasks.Task IExplicitWorker.ExecuteExplicitAsync() => LoadAsync<string>("explicit");
        \\}
    );

    var outline = (try explorer.getOutline("src/Modern.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expectEqual(Language.c_sharp, outline.language);
    try testing.expectEqual(@as(usize, 6), outline.imports.items.len);
    try expectOutlineImport(&outline, "Legacy");
    try expectOutlineImport(&outline, "System.Net.Http");
    try expectOutlineImport(&outline, "System.Text.Json.Nodes.JsonNode");
    try expectOutlineImport(&outline, "System");
    try expectOutlineImport(&outline, "System.Text");
    try expectOutlineImport(&outline, "System.Math");
    try expectOutlineSymbol(&outline, "Demo.Core", .type_alias);
    try expectOutlineSymbol(&outline, "Customer", .class_def);
    try expectOutlineSymbol(&outline, "Money", .struct_def);
    try expectOutlineSymbol(&outline, "Widget", .class_def);
    try expectOutlineSymbol(&outline, "IRepository", .interface_def);
    try expectOutlineSymbol(&outline, "IQualifiedContracts", .interface_def);
    try expectOutlineSymbol(&outline, "IExplicitWorker", .interface_def);
    try expectOutlineSymbol(&outline, "LoadAllAsync", .method);
    try expectOutlineSymbol(&outline, "Format", .method);
    try expectOutlineSymbol(&outline, "Status", .enum_def);
    try expectOutlineSymbol(&outline, "Handler", .function);
    try expectOutlineSymbol(&outline, "Service", .class_def);
    try expectOutlineSymbol(&outline, "Url", .constant);
    try expectOutlineSymbol(&outline, "Changed", .variable);
    try expectOutlineSymbol(&outline, "Name", .variable);
    try expectOutlineSymbol(&outline, "LoadAsync", .method);
    try expectOutlineSymbol(&outline, "SaveAsync", .method);
    try expectOutlineSymbol(&outline, "Create", .method);
    try expectOutlineSymbol(&outline, "Service", .method);
    try expectOutlineSymbol(&outline, "DisposeWork", .method);
    try expectOutlineSymbol(&outline, "ExecuteExplicitAsync", .method);
    try expectOutlineSymbol(&outline, "operator int", .method);
    // The indexer `public string this[int index]` surfaces as a member named
    // "this[]" (the conventional indexer display name); the parameter name
    // `index` must never leak as its own symbol.
    try expectOutlineSymbol(&outline, "this[]", .variable);

    var found_service_class = false;
    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "index"));
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Service")) {
            try testing.expect(sym.line_end > sym.line_start);
            found_service_class = true;
        }
        // Indexer: return type extracted from the prefix before `this`, and the
        // `[int index]` parameter list yields a single `int` param type.
        if (std.mem.eql(u8, sym.name, "this[]") and sym.kind == .variable) {
            try testing.expectEqualStrings("string", sym.return_type.?);
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            try testing.expectEqualStrings("int", sym.param_types[0]);
        }
    }
    try testing.expect(found_service_class);

    // Primary constructors: positional params are captured on the type symbol's
    // param_types (record/struct/class forms alike).
    var found_customer_params = false;
    var found_money_params = false;
    var found_widget_params = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Customer")) {
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            try testing.expectEqualStrings("T", sym.param_types[0]);
            found_customer_params = true;
        }
        if (sym.kind == .struct_def and std.mem.eql(u8, sym.name, "Money")) {
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            try testing.expectEqualStrings("decimal", sym.param_types[0]);
            found_money_params = true;
        }
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Widget")) {
            try testing.expectEqual(@as(usize, 2), sym.param_types.len);
            try testing.expectEqualStrings("string", sym.param_types[0]);
            try testing.expectEqualStrings("int", sym.param_types[1]);
            found_widget_params = true;
        }
    }
    try testing.expect(found_customer_params);
    try testing.expect(found_money_params);
    try testing.expect(found_widget_params);
}

test "csharp parser: direct line parsing handles raw strings and operator detail" {
    var raw_quotes: usize = 0;
    csharp_parser.updateRawStringState("private const string Raw = \"\"\"", &raw_quotes);
    try testing.expectEqual(@as(usize, 3), raw_quotes);

    csharp_parser.updateRawStringState("public class FakeInRaw {}", &raw_quotes);
    try testing.expectEqual(@as(usize, 3), raw_quotes);

    csharp_parser.updateRawStringState("\"\"\";", &raw_quotes);
    try testing.expectEqual(@as(usize, 0), raw_quotes);

    switch (csharp_parser.parseLine("public static explicit operator int(Service service) => 0;")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
            try testing.expectEqualStrings("operator int", sym.name);
        },
        else => return error.TestUnexpectedResult,
    }

    switch (csharp_parser.parseLine("private const string Url = \"https://example.test/api\"; // comment")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.constant, sym.kind);
            try testing.expectEqualStrings("Url", sym.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "csharp parser: type extraction from method signatures" {
    // Method with generic return type and params
    switch (csharp_parser.parseLine("public async Task<IViewComponentResult> InvokeAsync(ReportRequest request)")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
            try testing.expectEqualStrings("InvokeAsync", sym.name);
            try testing.expect(sym.return_type != null);
            if (sym.return_type) |rt| {
                try testing.expectEqualStrings("Task<IViewComponentResult>", rt);
            }
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            if (sym.param_types.len > 0) {
                try testing.expectEqualStrings("ReportRequest", sym.param_types.buf[0]);
            }
        },
        else => return error.TestUnexpectedResult,
    }

    // Simple method
    switch (csharp_parser.parseLine("public void DoSomething(int id, string name)")) {
        .symbol => |sym| {
            try testing.expectEqualStrings("DoSomething", sym.name);
            try testing.expect(sym.return_type != null);
            if (sym.return_type) |rt| {
                try testing.expectEqualStrings("void", rt);
            }
            try testing.expectEqual(@as(usize, 2), sym.param_types.len);
        },
        else => return error.TestUnexpectedResult,
    }

    // Property with generic type
    switch (csharp_parser.parseLine("public List<string> Names { get; set; }")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.variable, sym.kind);
            try testing.expectEqualStrings("Names", sym.name);
            try testing.expect(sym.return_type != null);
            if (sym.return_type) |rt| {
                try testing.expectEqualStrings("List<string>", rt);
            }
        },
        else => return error.TestUnexpectedResult,
    }

    // Field
    switch (csharp_parser.parseLine("private readonly ILogger _logger;")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.variable, sym.kind);
            try testing.expectEqualStrings("_logger", sym.name);
            try testing.expect(sym.return_type != null);
            if (sym.return_type) |rt| {
                try testing.expectEqualStrings("ILogger", rt);
            }
        },
        else => return error.TestUnexpectedResult,
    }

    // Constructor (no return type)
    switch (csharp_parser.parseLine("public MyClass(int x)")) {
        .symbol => |sym| {
            // Constructor - should still be detected
            try testing.expectEqualStrings("MyClass", sym.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "csharp parser: object instantiation is not misclassified as a method" {
    // `var p = new Probe();` must NOT produce a method symbol named "Probe".
    // Pre-fix, `hasDeclarationPrefix` saw " new" in the prefix "var p = new"
    // and treated it as the C# `new` modifier, so every `new Foo()` call site
    // became a false definition — which then got excluded from codedb_callers
    // and polluted codedb_symbol results.
    switch (csharp_parser.parseLine("        var p = new Probe();")) {
        .none => {},
        .symbol, .import => return error.TestUnexpectedResult,
    }
    // Other instantiation shapes also rejected.
    switch (csharp_parser.parseLine("    var u = new System.Uri(builder);")) {
        .none => {},
        .symbol, .import => return error.TestUnexpectedResult,
    }
    switch (csharp_parser.parseLine("    return new Probe(serial);")) {
        .none => {},
        .symbol, .import => return error.TestUnexpectedResult,
    }
    // The C# `new` modifier (hides a base member) must STILL parse as a method:
    // `public new void Name(` has a return type between `new` and the name.
    switch (csharp_parser.parseLine("public new void Hidden()")) {
        .symbol => |sym| {
            try testing.expectEqualStrings("Hidden", sym.name);
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
        },
        else => return error.TestUnexpectedResult,
    }
    // Sanity: a normal method still parses.
    switch (csharp_parser.parseLine("public Task<Probe> GetProbeAsync(int id)")) {
        .symbol => |sym| {
            try testing.expectEqualStrings("GetProbeAsync", sym.name);
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "csharp parser: tuple-return method signatures" {
    // `(string, int) Parse(string input)` was misparsed before: the return-type
    // `(` was mistaken for the parameter list, yielding a method named "int"
    // with garbage return_type and no params.
    switch (csharp_parser.parseLine("public (string, int) Parse(string input) { }")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
            try testing.expectEqualStrings("Parse", sym.name);
            try testing.expect(sym.return_type != null);
            try testing.expectEqualStrings("(string, int)", sym.return_type.?);
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            try testing.expectEqualStrings("string", sym.param_types.buf[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    // Named tuple elements in the return type.
    switch (csharp_parser.parseLine("public (string Name, int Count) GetMetrics() { }")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
            try testing.expectEqualStrings("GetMetrics", sym.name);
            try testing.expect(sym.return_type != null);
            try testing.expectEqualStrings("(string Name, int Count)", sym.return_type.?);
            try testing.expectEqual(@as(usize, 0), sym.param_types.len);
        },
        else => return error.TestUnexpectedResult,
    }

    // Generic tuple return: `findMatchingParen` ignores `<`/`>`, so the tuple's
    // `)` is found correctly and the real param list is used.
    switch (csharp_parser.parseLine("public (IEnumerable<T> a, int b) Split<T>(List<T> source) { }")) {
        .symbol => |sym| {
            try testing.expectEqual(csharp_parser.Kind.method, sym.kind);
            try testing.expectEqualStrings("Split", sym.name);
            try testing.expect(sym.return_type != null);
            try testing.expectEqualStrings("(IEnumerable<T> a, int b)", sym.return_type.?);
            try testing.expectEqual(@as(usize, 1), sym.param_types.len);
            try testing.expectEqualStrings("List<T>", sym.param_types.buf[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    // A cast `(MyType) foo` must NOT be mistaken for a tuple-return method: the
    // identifier after `)` is not followed by `(`.
    switch (csharp_parser.parseLine("    var x = (int) value;")) {
        .none => {},
        .symbol, .import => return error.TestUnexpectedResult,
    }
}

test "csharp parser: multiline tuple returns and primary constructors are enriched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Signatures.cs",
        \\public class Handler(
        \\    IService service,
        \\    string name)
        \\{
        \\    public (string Name, int Count) Parse(
        \\        string value,
        \\        int count)
        \\    {
        \\        return (value, count);
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("src/Signatures.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_handler = false;
    var found_parse = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Handler")) {
            try testing.expectEqual(@as(usize, 2), sym.param_types.len);
            try testing.expectEqualStrings("IService", sym.param_types[0]);
            try testing.expectEqualStrings("string", sym.param_types[1]);
            found_handler = true;
        }
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Parse")) {
            try testing.expectEqualStrings("(string Name, int Count)", sym.return_type.?);
            try testing.expectEqual(@as(usize, 2), sym.param_types.len);
            try testing.expectEqualStrings("string", sym.param_types[0]);
            try testing.expectEqualStrings("int", sym.param_types[1]);
            found_parse = true;
        }
    }
    try testing.expect(found_handler);
    try testing.expect(found_parse);
}

test "csharp parser: preprocessor directive classification" {
    // Leaf-level classifier (no lifecycle scope state).
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_if, csharp_parser.preprocessorDirective("#if DEBUG").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_if, csharp_parser.preprocessorDirective("  #ifdef LINUX").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_if, csharp_parser.preprocessorDirective("\t# ifndef X").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_endif, csharp_parser.preprocessorDirective("#endif").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_else, csharp_parser.preprocessorDirective("#else").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.conditional_elif, csharp_parser.preprocessorDirective("#elif RELEASE").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.other, csharp_parser.preprocessorDirective("#region Setup").?);
    try testing.expectEqual(csharp_parser.PreprocessorKind.other, csharp_parser.preprocessorDirective("#endregion").?);
    // Word boundary: `#define` is `.other`, not matched by `#if`/`#ifdef`.
    try testing.expectEqual(csharp_parser.PreprocessorKind.other, csharp_parser.preprocessorDirective("#define TRACE").?);
    // Non-directive lines return null.
    try testing.expect(csharp_parser.preprocessorDirective("public class C { }") == null);
    try testing.expect(csharp_parser.preprocessorDirective("") == null);
}

test "csharp parser: preprocessor brace reconciliation keeps scope intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    // Brace-imbalanced conditional: the `{` opens in `#if DEBUG`, its matching
    // `}` is in `#else`. Without reconciliation the brace depth stays elevated
    // for the rest of the file, corrupting scope attribution for `Later`.
    try explorer.indexFile("src/Cond.cs",
        \\public class Cond
        \\{
        \\#if DEBUG
        \\    public string DebugField = "x";
        \\    public void OnlyDebug()
        \\    {
        \\#else
        \\    }
        \\#endif
        \\    public void Later() { }
        \\}
    );

    var outline = (try explorer.getOutline("src/Cond.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    // The conditional body is over-included by design (search benefits), but
    // the class must close correctly and `Later` must still parse as a method.
    var found_class = false;
    var found_later = false;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "Cond")) {
            found_class = true;
            // The class span must end on the final `}`, not run off the file.
            try testing.expect(sym.line_end > sym.line_start);
        }
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Later")) {
            found_later = true;
        }
    }
    try testing.expect(found_class);
    try testing.expect(found_later);
}

test "csharp parser: unconditional inclusion indexes conditional class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    // A type declared inside a conditional region is still indexed (over-include
    // by design — we cannot evaluate `<DefineConstants>`).
    try explorer.indexFile("src/Platform.cs",
        \\#if ANDROID
        \\public class AndroidHandler { }
        \\#else
        \\public class DefaultHandler { }
        \\#endif
        \\public class Shared { }
    );

    var outline = (try explorer.getOutline("src/Platform.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "AndroidHandler", .class_def);
    try expectOutlineSymbol(&outline, "DefaultHandler", .class_def);
    try expectOutlineSymbol(&outline, "Shared", .class_def);
}

test "csharp parser: unterminated #if does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    // File ends inside an open `#if` with no matching `#endif`. Must not crash
    // or hang; the body is indexed as ordinary code.
    try explorer.indexFile("src/Open.cs",
        \\public class Outer
        \\{
        \\#if DEBUG
        \\    public void DebugOnly() { }
        \\    public string Tail;
    );

    var outline = (try explorer.getOutline("src/Open.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "Outer", .class_def);
    try expectOutlineSymbol(&outline, "DebugOnly", .method);
}

test "csharp parser: region directives are no-ops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/Reg.cs",
        \\public class Reg
        \\{
        \\#region Props
        \\    public string Name { get; set; }
        \\#endregion
        \\    public int Count { get; set; }
        \\}
    );

    var outline = (try explorer.getOutline("src/Reg.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "Reg", .class_def);
    try expectOutlineSymbol(&outline, "Name", .variable);
    try expectOutlineSymbol(&outline, "Count", .variable);
}

test "csharp parser: captures attributes on following symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Controllers/HomeController.cs",
        \\public class HomeController {
        \\    [HttpPost]
        \\    [ValidateAntiForgeryToken]
        \\    public IActionResult Save() { return View(); }
        \\    [HttpGet]
        \\    public IActionResult Index() { return View(); }
        \\}
    );

    var outline = (try explorer.getOutline("Controllers/HomeController.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var found_save = false;
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Save")) {
            found_save = true;
            try testing.expectEqual(@as(usize, 2), sym.decorators.len);
            try testing.expectEqualStrings("[HttpPost]", sym.decorators[0]);
            try testing.expectEqualStrings("[ValidateAntiForgeryToken]", sym.decorators[1]);
        }
    }
    try testing.expect(found_save);
}

test "csharp parser: multiline attribute strings do not hide following members" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Generated.cs",
        \\public class Generated
        \\{
        \\    [Display(Description = @"First line
        \\second line", Order = 0)]
        \\    public string @Value { get; set; }
        \\    [Matrix(new[] { 1, 2 })]
        \\    public int After { get; set; }
        \\}
    );

    var outline = (try explorer.getOutline("src/Generated.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try expectOutlineSymbol(&outline, "Value", .variable);
    try expectOutlineSymbol(&outline, "After", .variable);
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Value")) try testing.expectEqualStrings("string", sym.return_type.?);
    }
}

test "csharp parser: ignores comments attributes and declarations inside strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/Comments.cs",
        \\namespace Demo.Comments {
        \\    // public class CommentOnly {}
        \\    [Metadata(
        \\        Name = "public class FakeInAttribute {}",
        \\        Targets = new[] { typeof(object) }
        \\    )]
        \\    public class Real {
        \\        private const string Json = "{ \"class FakeInString\": true } // not a comment";
        \\        private const string Verbatim = @$"https://example.test/{nameof(Real)}";
        \\        private const string Quoted = @"{ ""not a brace"" }";
        \\        private const string Raw = """
        \\public class FakeInRaw {}
        \\{ "raw": true }
        \\""";
        \\        [GeneratedCode("tool", "1.0")]
        \\        public string Path { get; set; }
        \\        public void AfterRaw() { }
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("src/Comments.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "Demo.Comments", .type_alias);
    try expectOutlineSymbol(&outline, "Real", .class_def);
    try expectOutlineSymbol(&outline, "Json", .constant);
    try expectOutlineSymbol(&outline, "Verbatim", .constant);
    try expectOutlineSymbol(&outline, "Quoted", .constant);
    try expectOutlineSymbol(&outline, "Raw", .constant);
    try expectOutlineSymbol(&outline, "Path", .variable);
    try expectOutlineSymbol(&outline, "AfterRaw", .method);

    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "CommentOnly"));
        try testing.expect(!std.mem.eql(u8, sym.name, "FakeInAttribute"));
        try testing.expect(!std.mem.eql(u8, sym.name, "FakeInString"));
        try testing.expect(!std.mem.eql(u8, sym.name, "FakeInRaw"));
    }
}

test "csharp parser: skips minimal API invocation statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("src/Program.cs",
        \\using Microsoft.AspNetCore.Builder;
        \\using Microsoft.Extensions.DependencyInjection;
        \\
        \\var builder = WebApplication.CreateBuilder(args);
        \\builder.Services.AddControllers();
        \\var app = builder.Build();
        \\app.MapGet("/health", () => Health());
        \\await SeedAsync(app.Services);
        \\await app.RunAsync();
        \\if (!string.Equals(app.Environment.EnvironmentName, "Development", StringComparison.OrdinalIgnoreCase)) { }
        \\
        \\static IResult Health() => Results.Ok();
        \\
        \\public sealed class StartupMarker
        \\{
        \\}
    );

    var outline = (try explorer.getOutline("src/Program.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineImport(&outline, "Microsoft.AspNetCore.Builder");
    try expectOutlineImport(&outline, "Microsoft.Extensions.DependencyInjection");
    try expectOutlineSymbol(&outline, "Health", .method);
    try expectOutlineSymbol(&outline, "StartupMarker", .class_def);

    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "CreateBuilder"));
        try testing.expect(!std.mem.eql(u8, sym.name, "AddControllers"));
        try testing.expect(!std.mem.eql(u8, sym.name, "Build"));
        try testing.expect(!std.mem.eql(u8, sym.name, "MapGet"));
        try testing.expect(!std.mem.eql(u8, sym.name, "SeedAsync"));
        try testing.expect(!std.mem.eql(u8, sym.name, "RunAsync"));
        try testing.expect(!std.mem.eql(u8, sym.name, "Equals"));
    }
}

test "razor parser: extracts directives and @code block declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("Pages/Index.razor",
        \\@page "/"
        \\@using Microsoft.AspNetCore.Components
        \\@inject ILogger<Index> Logger
        \\@inherits LayoutComponentBase
        \\@implements IDisposable
        \\@typeparam TItem
        \\@layout MainLayout
        \\@namespace MyApp.Pages
        \\
        \\<h1>Hello</h1>
        \\
        \\@section Scripts {
        \\    <script src="app.js"></script>
        \\}
        \\
        \\@code {
        \\    private int _count;
        \\    public string Name { get; set; }
        \\
        \\    protected override void OnInitialized()
        \\    {
        \\        Logger.LogInformation("init");
        \\    }
        \\
        \\    public void Dispose() { }
        \\}
    );

    const outline = explorer.outlines.get("Pages/Index.razor").?;
    try testing.expectEqual(explore.Language.razor, outline.language);

    // Collect symbol names for easy assertion
    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Directives
    try testing.expect(containsString(sym_names.items, "\"/\""));
    try testing.expect(containsString(sym_names.items, "LayoutComponentBase"));
    try testing.expect(containsString(sym_names.items, "IDisposable"));
    try testing.expect(containsString(sym_names.items, "TItem"));
    try testing.expect(containsString(sym_names.items, "MainLayout"));
    try testing.expect(containsString(sym_names.items, "MyApp.Pages"));
    try testing.expect(containsString(sym_names.items, "@code"));
    try testing.expect(containsString(sym_names.items, "Scripts"));

    // Imports
    var import_names: std.ArrayList([]const u8) = .empty;
    for (outline.imports.items) |imp| {
        try import_names.append(alloc, imp);
    }
    try testing.expect(containsString(import_names.items, "Microsoft.AspNetCore.Components"));
    try testing.expect(containsString(import_names.items, "ILogger<Index>"));

    // C# symbols inside @code block
    try testing.expect(containsString(sym_names.items, "_count"));
    try testing.expect(containsString(sym_names.items, "Name"));
    try testing.expect(containsString(sym_names.items, "OnInitialized"));
    try testing.expect(containsString(sym_names.items, "Dispose"));
}

test "razor parser: @functions block parsed as C# declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("Views/Home.cshtml",
        \\@model MyApp.Models.HomeViewModel
        \\@using MyApp.Services
        \\@inject IWebHostEnvironment Env
        \\
        \\<div>Content</div>
        \\
        \\@functions {
        \\    public class Helper
        \\    {
        \\        public string Format(int value) => value.ToString();
        \\    }
        \\
        \\    private const string DefaultTitle = "Home";
        \\}
    );

    const outline = explorer.outlines.get("Views/Home.cshtml").?;
    try testing.expectEqual(explore.Language.razor, outline.language);

    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Directives
    try testing.expect(containsString(sym_names.items, "MyApp.Models.HomeViewModel"));
    try testing.expect(containsString(sym_names.items, "@functions"));

    // Imports
    var import_names: std.ArrayList([]const u8) = .empty;
    for (outline.imports.items) |imp| {
        try import_names.append(alloc, imp);
    }
    try testing.expect(containsString(import_names.items, "MyApp.Services"));
    try testing.expect(containsString(import_names.items, "IWebHostEnvironment"));

    // C# inside @functions
    try testing.expect(containsString(sym_names.items, "Helper"));
    try testing.expect(containsString(sym_names.items, "Format"));
    try testing.expect(containsString(sym_names.items, "DefaultTitle"));
}

test "razor parser: skips control flow and HTML event handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var explorer = Explorer.init(alloc);

    try explorer.indexFile("Pages/Skip.cshtml",
        \\@page "/skip"
        \\@model string
        \\
        \\@if (true) {
        \\    <p>conditional</p>
        \\}
        \\
        \\@foreach (var item in items) {
        \\    <button @onclick="HandleClick">Click</button>
        \\}
        \\
        \\@{
        \\    var x = 1;
        \\}
    );

    const outline = explorer.outlines.get("Pages/Skip.cshtml").?;
    try testing.expectEqual(explore.Language.razor, outline.language);

    var sym_names: std.ArrayList([]const u8) = .empty;
    for (outline.symbols.items) |sym| {
        try sym_names.append(alloc, sym.name);
    }

    // Should have @page route and @model
    try testing.expect(containsString(sym_names.items, "\"/skip\""));
    try testing.expect(containsString(sym_names.items, "string"));

    // Should NOT have control flow or HTML event handler symbols
    try testing.expect(!containsString(sym_names.items, "item"));
    try testing.expect(!containsString(sym_names.items, "HandleClick"));
    try testing.expect(!containsString(sym_names.items, "items"));
}

test "csharp: multi-field declaration emits a symbol per field" {
    var buf: [csharp_parser.max_field_names][]const u8 = undefined;
    const n = csharp_parser.extractFieldNames("private int a, b, c;", &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("a", buf[0]);
    try testing.expectEqualStrings("b", buf[1]);
    try testing.expectEqualStrings("c", buf[2]);
}

test "csharp parser: enum context and nested calls do not pollute definitions" {
    switch (csharp_parser.parseLineWithOptions("lower_case = 1,", .{ .allow_enum_member = true })) {
        .symbol => |sym| try testing.expectEqualStrings("lower_case", sym.name),
        else => return error.TestUnexpectedResult,
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Noisy.cs",
        \\public enum wire_state
        \\{
        \\    lower_case = 1,
        \\    Ready,
        \\}
        \\public class Noisy
        \\{
        \\    public Noisy([FromServices] ILogger logger, string name = "default") { }
        \\    public Noisy(
        \\        IService service,
        \\        [FromKeyedServices("primary")] IRepository repository,
        \\        CancellationToken cancellationToken
        \\    ) { }
        \\    public required List<string> Names { get; init; }
        \\    public void Run()
        \\    {
        \\        if (!roles.ContainsKey(Constants.Admin)) { }
        \\        foreach (var item in rows.DistinctBy(x => x.Id)) { }
        \\        vm.SetProperties("", ToolbarConfiguration.GetToolbar(user));
        \\        var values = new HashSet<string> { "one", "two" };
        \\        var dto = new Request { OrderUploadId = id, Items = new List<Item> { item } };
        \\        var result = (await service.LoadAsync(id)).ToList();
        \\        bool isValid = !((Math.Abs(value) / Math.Round(value, 4)) > 0.1);
        \\        const int localLimit = 1000;
        \\        async Task<Item> LocalAsync(Item item) => await Task.FromResult(item);
        \\        stream.Read(bytes, 0, (int)length);
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("src/Noisy.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "lower_case", .constant);
    try expectOutlineSymbol(&outline, "Ready", .constant);
    try expectOutlineSymbol(&outline, "Noisy", .class_def);
    try expectOutlineSymbol(&outline, "Names", .variable);
    try expectOutlineSymbol(&outline, "Run", .method);

    var found_constructor = false;
    var found_multiline_constructor = false;
    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "ContainsKey"));
        try testing.expect(!std.mem.eql(u8, sym.name, "DistinctBy"));
        try testing.expect(!std.mem.eql(u8, sym.name, "GetToolbar"));
        try testing.expect(!std.mem.eql(u8, sym.name, "string"));
        try testing.expect(!std.mem.eql(u8, sym.name, "OrderUploadId"));
        try testing.expect(!std.mem.eql(u8, sym.name, "Items"));
        try testing.expect(!std.mem.eql(u8, sym.name, "result"));
        try testing.expect(!std.mem.eql(u8, sym.name, "isValid"));
        try testing.expect(!std.mem.eql(u8, sym.name, "localLimit"));
        try testing.expect(!std.mem.eql(u8, sym.name, "0"));
        if (sym.kind == .method and std.mem.eql(u8, sym.name, "Noisy")) {
            try testing.expect(sym.return_type == null);
            if (sym.param_types.len == 2) {
                found_constructor = true;
                try testing.expectEqualStrings("ILogger", sym.param_types[0]);
                try testing.expectEqualStrings("string", sym.param_types[1]);
            } else if (sym.param_types.len == 3) {
                found_multiline_constructor = true;
                try testing.expectEqualStrings("IService", sym.param_types[0]);
                try testing.expectEqualStrings("IRepository", sym.param_types[1]);
                try testing.expectEqualStrings("CancellationToken", sym.param_types[2]);
            }
        }
    }
    try testing.expect(found_constructor);
    try testing.expect(found_multiline_constructor);
    try expectOutlineSymbol(&outline, "LocalAsync", .method);
}

test "csharp parser: initialized properties and multiline fields remain visible without switch-arm noise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Model.cs",
        \\public class Model
        \\{
        \\    private static List<string> Values = new List<string>()
        \\    {
        \\        "one",
        \\    };
        \\    public Collection<string> Roles { get; private set; } = new Collection<string>();
        \\    public string @event { get; set; }
        \\    public string Color(string value)
        \\    {
        \\        return value switch
        \\        {
        \\            "Ready" or "Active" => "green",
        \\            _ => "gray",
        \\        };
        \\    }
        \\}
    );

    var outline = (try explorer.getOutline("src/Model.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try expectOutlineSymbol(&outline, "Values", .variable);
    try expectOutlineSymbol(&outline, "Roles", .variable);
    try expectOutlineSymbol(&outline, "event", .variable);
    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "Active"));
        try testing.expect(!std.mem.eql(u8, sym.name, "Ready"));
        if (std.mem.eql(u8, sym.name, "Roles")) {
            try testing.expectEqualStrings("Collection<string>", sym.return_type.?);
        }
        if (std.mem.eql(u8, sym.name, "event")) {
            try testing.expectEqualStrings("string", sym.return_type.?);
        }
    }
}

test "csharp parser: preprocessor branches restore full member scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Branches.cs",
        \\public class Branches
        \\{
        \\#if FIRST
        \\}
        \\#else
        \\    {
        \\#endif
        \\    public void Run()
        \\    {
        \\        return value switch
        \\        {
        \\            "Wrong" => "noise",
        \\            _ => "ok",
        \\        };
        \\    }
        \\    public List<string> After { get; } = new List<string>();
        \\}
    );

    var outline = (try explorer.getOutline("src/Branches.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try expectOutlineSymbol(&outline, "Run", .method);
    try expectOutlineSymbol(&outline, "After", .variable);
    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "Wrong"));
    }
}

test "csharp parser: malformed input and braces in strings remain bounded" {
    const counts = csharp_parser.countStructuralBraces(
        \\public string Json { get; } = "{ not structure }"; // }
    );
    try testing.expectEqual(@as(usize, 1), counts.opens);
    try testing.expectEqual(@as(usize, 1), counts.closes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());
    try explorer.indexFile("src/Broken.cs",
        \\public class Broken
        \\{
        \\    public void StillVisible()
        \\    {
        \\        const int localOnly = 1;
        \\        var text = "/* not a comment {";
        \\        public int InvalidButParsedAsFixture; /* unterminated comment
        \\        public class Fake { }
    );
    var outline = (try explorer.getOutline("src/Broken.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();
    try expectOutlineSymbol(&outline, "Broken", .class_def);
    try expectOutlineSymbol(&outline, "StillVisible", .method);
    for (outline.symbols.items) |sym| {
        try testing.expect(!std.mem.eql(u8, sym.name, "localOnly"));
        try testing.expect(!std.mem.eql(u8, sym.name, "Fake"));
    }
}

test "csharp parser: multiline base list is rejoined into the declaration detail" {
    // A base list spread across lines used to truncate the type symbol's detail
    // to the first line, so `IAuthorizeFilter` / `IDisposable` dropped out of
    // the type graph. The detail must now carry the full base list.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("src/Dashboard.cs",
        \\public class DashboardController : BaseController,
        \\    IAuthorizeFilter,
        \\    IDisposable
        \\{
        \\    public void Render() { }
        \\}
        \\
        \\public class SingleLine : Base { }
    );

    var outline = (try explorer.getOutline("src/Dashboard.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    var dashboard_detail: ?[]const u8 = null;
    var singleline_detail: ?[]const u8 = null;
    for (outline.symbols.items) |sym| {
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "DashboardController")) {
            dashboard_detail = sym.detail;
        }
        if (sym.kind == .class_def and std.mem.eql(u8, sym.name, "SingleLine")) {
            singleline_detail = sym.detail;
        }
    }

    const dd = dashboard_detail orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, dd, "BaseController") != null);
    try testing.expect(std.mem.indexOf(u8, dd, "IAuthorizeFilter") != null);
    try testing.expect(std.mem.indexOf(u8, dd, "IDisposable") != null);
    // The body brace terminates the declaration and must be present too.
    try testing.expect(std.mem.indexOfScalar(u8, dd, '{') != null);

    // Single-line declarations keep their brace, so the enrichment must be a
    // no-op for them (no double-processing, no truncation).
    const sd = singleline_detail orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, sd, "Base") != null);
    try testing.expect(std.mem.indexOfScalar(u8, sd, '{') != null);

    // The type graph (populated during indexing) must reflect every base name.
    const bases = explorer.type_graph.getBases("DashboardController");
    var found_base_controller = false;
    var found_authorize = false;
    var found_disposable = false;
    for (bases) |base| {
        if (std.mem.eql(u8, base, "BaseController")) found_base_controller = true;
        if (std.mem.eql(u8, base, "IAuthorizeFilter")) found_authorize = true;
        if (std.mem.eql(u8, base, "IDisposable")) found_disposable = true;
    }
    try testing.expect(found_base_controller);
    try testing.expect(found_authorize);
    try testing.expect(found_disposable);
}
