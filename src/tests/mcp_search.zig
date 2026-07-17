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
const mcp_tools = @import("../mcp/explore_tools.zig");

test "callers: semantic match keeps real invocations and drops strings/comments" {
    try testing.expect(mcp_tools.callerLineMatches("    service.Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("    Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("    Probe<string>(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    logger.LogInformation(\"Probe(request)\");", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    // Probe(request);", "Probe", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    var x = nameof(Probe);", "Probe", .c_sharp, "semantic"));
}

test "callers: text match mode preserves whole-word behavior" {
    try testing.expect(mcp_tools.callerLineMatches("    logger.LogInformation(\"Probe\");", "Probe", .c_sharp, "text"));
    try testing.expect(!mcp_tools.callerLineMatches("    ProbeRepository.Do();", "Probe", .c_sharp, "text"));
}

test "callers: references mode finds type usages without invocation suffix" {
    // The gap this closes: for a class/type, semantic mode requires a '('
    // invocation suffix and so returns 0 for ordinary type usages.
    // references mode must catch whole-word type usages while still
    // excluding strings and comments.
    try testing.expect(mcp_tools.callerLineMatches("    public List<Probe> Probes { get; set; }", "Probe", .c_sharp, "references"));
    try testing.expect(mcp_tools.callerLineMatches("    public Probe? Probe { get; set; }", "Probe", .c_sharp, "references"));
    try testing.expect(mcp_tools.callerLineMatches("    public class EfProbeRepository : EfBaseEntityRepository<Probe>", "Probe", .c_sharp, "references"));
    try testing.expect(mcp_tools.callerLineMatches("    public Probe GetProbe() => null;", "Probe", .c_sharp, "references"));
    try testing.expect(mcp_tools.callerLineMatches("    var x = new Probe(serial);", "Probe", .c_sharp, "references"));
    // Constructor calls are still references (superset of semantic).
    try testing.expect(mcp_tools.callerLineMatches("    Probe(request);", "Probe", .c_sharp, "references"));
    // Strings and comments are excluded (unlike raw text mode).
    try testing.expect(!mcp_tools.callerLineMatches("    logger.LogInformation(\"Probe\");", "Probe", .c_sharp, "references"));
    try testing.expect(!mcp_tools.callerLineMatches("    // Probe is a device", "Probe", .c_sharp, "references"));
    // Substring inside a longer identifier is NOT a reference.
    try testing.expect(!mcp_tools.callerLineMatches("    var x = new ProbeRepository();", "Probe", .c_sharp, "references"));
}

test "effectiveMatchMode auto-broadens to references for type definitions" {
    const SR = explore.SymbolResult;
    // No explicit mode + a class definition -> references. Mutate the kind
    // in-place: assigning the standalone class_sym would NOT update the copy
    // already stored in the array.
    var class_defs = [_]SR{.{
        .path = "a.cs",
        .symbol = .{ .name = "Probe", .kind = .class_def, .line_start = 1, .line_end = 1 },
    }};
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &class_defs), "references"));
    // enum/struct/interface/trait/type_alias also qualify.
    class_defs[0].symbol.kind = .enum_def;
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &class_defs), "references"));
    class_defs[0].symbol.kind = .struct_def;
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &class_defs), "references"));
    class_defs[0].symbol.kind = .interface_def;
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &class_defs), "references"));
    // A function/method with no explicit mode -> stays semantic.
    class_defs[0].symbol.kind = .function;
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &class_defs), "semantic"));
    // Explicit mode is always respected, even for types.
    class_defs[0].symbol.kind = .class_def;
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode("semantic", &class_defs), "semantic"));
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode("text", &class_defs), "text"));
    // Empty defs + no mode -> semantic (safe fallback).
    const empty = [_]SR{};
    try testing.expect(std.mem.eql(u8, mcp_tools.effectiveMatchMode(null, &empty), "semantic"));
}
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

test "codedb_callers: auto-discovers type references for a class definition" {
    // The core P1 fix: querying callers for a class with NO explicit
    // match_mode must auto-broaden to whole-word references (mirroring
    // LSP findReferences). Pre-fix this returned 0 results because the
    // default 'semantic' mode requires a '(' invocation suffix.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile(
        "src/Probe.cs",
        \\namespace App;
        \\public class Probe : BaseEntity
        \\{
        \\    public string Serial { get; set; }
        \\}
    );
    try explorer.indexFile(
        "src/Concentrator.cs",
        \\namespace App;
        \\public class Concentrator
        \\{
        \\    public List<Probe> Probes { get; set; }
        \\    public Probe? ActiveProbe { get; set; }
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // No match_mode specified — must auto-select 'references' for the class.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Header should reflect the auto-selected mode.
    try testing.expect(std.mem.indexOf(u8, out.items, "references for 'Probe'") != null);
    // Both type usages must be discovered.
    try testing.expect(std.mem.indexOf(u8, out.items, "List<Probe>") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "ActiveProbe") != null);
    // The class definition line itself must NOT appear as a reference.
    try testing.expect(std.mem.indexOf(u8, out.items, "public class Probe") == null);
}

test "codedb_callers: explicit semantic mode still respected for types" {
    // An explicit match_mode must override the type-auto-broadening so
    // callers can still ask for invocation-only sites when they want to.
    // We assert the contrast against the default: same class, same usages,
    // but semantic mode must NOT surface the type usages that references
    // mode would. (We avoid `new Probe()` here because the C# parser
    // currently misclassifies a standalone `new Probe();` line as a method
    // declaration named Probe — a separate parser issue.)
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile(
        "src/Probe.cs",
        \\namespace App;
        \\public class Probe { }
    );
    try explorer.indexFile(
        "src/Concentrator.cs",
        \\namespace App;
        \\public class Concentrator
        \\{
        \\    public List<Probe> Probes { get; set; }
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\",\"match_mode\":\"semantic\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // Semantic mode header (not references), and the type usage must be absent.
    try testing.expect(std.mem.indexOf(u8, out.items, "call sites for 'Probe'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "List<Probe>") == null);
}

// ── P3: codedb_relations omits empty sections ─────────────────────────────

test "codedb_relations omits empty sections, keeps populated ones" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    // Probe has a base (BaseEntity) but no derived types and no importers.
    try explorer.indexFile("src/BaseEntity.cs", "public class BaseEntity { }\n");
    try explorer.indexFile("src/Probe.cs", "public class Probe : BaseEntity { }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_relations, &parsed.value.object, &out, &store, &explorer, &agents);

    // Populated sections present.
    try testing.expect(std.mem.indexOf(u8, out.items, "definitions:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "bases:") != null);
    // Empty sections omitted (no header, no "(none)").
    try testing.expect(std.mem.indexOf(u8, out.items, "derived/implementations:") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "(none)") == null);
}

test "codedb_relations prints a fallback when no relations exist" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Foo.cs", "public class Foo { }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // A name with no definition and no content matches → every section empty.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"DoesNotExist\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_relations, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "(no relations found)") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "(none)") == null);
}

// ── P2: codedb_symbol kind filter + type-definition ranking ───────────────

test "codedb_symbol ranks type definitions above same-named constants" {
    // The classic noise case: an entity class "Probe" plus a same-named
    // cache-tag constant. The class must surface first so an agent doesn't
    // pick the constant as "the" definition.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Probe.cs", "public class Probe { }\n");
    try explorer.indexFile("src/Cache.cs", "public const string Probe = \"probe\";\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    const class_pos = std.mem.indexOf(u8, out.items, "class_def") orelse return error.TestUnexpectedResult;
    const const_pos = std.mem.indexOf(u8, out.items, "constant") orelse return error.TestUnexpectedResult;
    try testing.expect(class_pos < const_pos);
}

test "codedb_symbol kind filter restricts to one kind" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Probe.cs", "public class Probe { }\n");
    try explorer.indexFile("src/Cache.cs", "public const string Probe = \"probe\";\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // kind=class_def → only the class, not the constant.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\",\"kind\":\"class_def\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "1 results for 'Probe'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "class_def") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "constant") == null);
}

test "codedb_symbol rejects unknown kind with the valid list" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Probe.cs", "public class Probe { }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\",\"kind\":\"not_a_kind\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "unknown 'kind'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "class_def") != null);
}

// ── Callers recall: structural type references (not capped by content search) ──

test "findTypeReferences discovers structural type references across categories" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Probe.cs", "public class Probe { }\n");
    try explorer.indexFile(
        "src/Repo.cs",
        \\public class Repo
        \\{
        \\    public List<Probe> Probes { get; set; }
        \\    public Probe? GetProbe() => null;
        \\    public void Do(Probe p) { }
        \\}
        \\public class ProbeRepo : EfBaseEntityRepository<Probe> { }
    );

    const refs = try explorer.findTypeReferences("Probe", testing.allocator);
    defer {
        for (refs) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(refs);
    }
    // 4 structural refs: property, method-return, method-param, base-clause.
    // The Probe class definition is NOT a self-reference.
    try testing.expectEqual(@as(usize, 4), refs.len);
    var saw_property = false;
    var saw_return = false;
    var saw_param = false;
    var saw_base = false;
    for (refs) |r| {
        if (std.mem.indexOf(u8, r.line_text, "List<Probe>") != null) saw_property = true;
        if (std.mem.indexOf(u8, r.line_text, "GetProbe()") != null) saw_return = true;
        if (std.mem.indexOf(u8, r.line_text, "Do(Probe") != null) saw_param = true;
        if (std.mem.indexOf(u8, r.line_text, "EfBaseEntityRepository<Probe>") != null) saw_base = true;
    }
    try testing.expect(saw_property);
    try testing.expect(saw_return);
    try testing.expect(saw_param);
    try testing.expect(saw_base);
}

test "codedb_callers references mode surfaces structural refs (base clause) end-to-end" {
    // The recall fix: a type referenced via a base clause
    // (`class ProbeRepo : EfBaseEntityRepository<Probe>`) must appear in
    // callers results even though it's a structural reference the content
    // search may not prioritize. Pre-fix this category could be missed for
    // common tokens due to content-search ranking/capping.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/Probe.cs", "public class Probe { }\n");
    try explorer.indexFile(
        "src/Repo.cs",
        \\public class ProbeRepo : EfBaseEntityRepository<Probe> { }
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"name\":\"Probe\"}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // The base-clause structural reference must be present.
    try testing.expect(std.mem.indexOf(u8, out.items, "EfBaseEntityRepository<Probe>") != null);
}

// ── P0: C# property-collapse data-loss regression ──────────────────────────
//
// collapseConsecutiveProperties previously mutated the STORED outline for
// runs of 5+ consecutive `.variable` symbols, keeping only the first
// property's name and dropping every property's return_type. That broke
// symbol lookup, type-usage dependency edges, the type index, and scope
// attribution. Collapsing is now display-only, so these tests pin the four
// downstream behaviours against regressing back to the data-layer collapse.

fn indexP0Fixture(explorer: *Explorer) !void {
    // 6 consecutive properties (>= 5 → would have collapsed pre-fix).
    try explorer.indexFile(
        "src/Concentrator.cs",
        \\using System.Collections.Generic;
        \\public class Concentrator
        \\{
        \\    public int SiteId { get; set; }
        \\    public string Name { get; set; }
        \\    public string Description { get; set; }
        \\    public string Imei { get; set; }
        \\    public List<Probe> Probes { get; set; }
        \\    public bool Active { get; set; }
        \\}
    );
    try explorer.indexFile(
        "src/Probe.cs",
        \\public class Probe { }
    );
}

test "P0: every C# property stays individually indexed with its type" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try indexP0Fixture(&explorer);

    var outline = (try explorer.getOutline("src/Concentrator.cs", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    // Pre-fix: only "SiteId" (the first) survived; "Probes"/"Active" were
    // invisible to symbol lookup.
    var found_probes = false;
    var found_active = false;
    var probes_type: ?[]const u8 = null;
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, "Probes")) {
            found_probes = true;
            probes_type = sym.return_type;
        }
        if (std.mem.eql(u8, sym.name, "Active")) found_active = true;
    }
    try testing.expect(found_probes);
    try testing.expect(found_active);
    // Pre-fix: the collapsed symbol had return_type = null.
    try testing.expect(probes_type != null);
    try testing.expect(std.mem.indexOf(u8, probes_type.?, "Probe") != null);
}

test "P0: property type usages flow into the dependency graph" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try indexP0Fixture(&explorer);

    // Type-usage edges are resolved against a complete symbol_index, so the
    // production initial-scan runs a post-scan rebuildTypeUsageDeps() to fix
    // ordering (A can reference B before B is indexed). Mirror that here.
    explorer.rebuildTypeUsageDeps();

    // Pre-fix: the `List<Probe> Probes` property type was collapsed away,
    // so Concentrator.cs never appeared as an importer of Probe.cs (the
    // single biggest source of missing entity-relationship edges).
    const imported_by = try explorer.getImportedBy("src/Probe.cs", testing.allocator);
    defer {
        for (imported_by) |p| testing.allocator.free(p);
        testing.allocator.free(imported_by);
    }
    var found = false;
    for (imported_by) |p| {
        if (std.mem.eql(u8, p, "src/Concentrator.cs")) found = true;
    }
    try testing.expect(found);
}

test "P0: scope attribution for a property-line hit resolves to the class" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try indexP0Fixture(&explorer);

    // A hit on the `List<Probe> Probes` line must attribute scope to the
    // enclosing class, not to a collapsed pseudo-symbol. Pre-fix this
    // reported "[in SiteId (variable, L3-L8)]".
    const results = try explorer.searchContentWithScope("Probe", testing.allocator, 50);
    defer {
        for (results) |r| {
            testing.allocator.free(r.line_text);
            testing.allocator.free(r.path);
            if (r.scope_name) |n| testing.allocator.free(n);
        }
        testing.allocator.free(results);
    }
    var concentrator_scope = false;
    for (results) |r| {
        if (std.mem.indexOf(u8, r.line_text, "List<Probe>") != null) {
            if (r.scope_name) |sn| {
                if (std.mem.eql(u8, sn, "Concentrator")) concentrator_scope = true;
            }
        }
    }
    try testing.expect(concentrator_scope);
}

test "P0: codedb_outline text still collapses for display, JSON does not" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try indexP0Fixture(&explorer);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Text outline: display collapse preserved (token-bounding for generated
    // ViewModels stays intact).
    const text_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/Concentrator.cs\"}", .{});
    defer text_parsed.deinit();
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &text_parsed.value.object, &text_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, text_out.items, "// props:") != null);

    // JSON outline: complete data — each property present as its own entry.
    const json_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src/Concentrator.cs\",\"output_format\":\"json\"}", .{});
    defer json_parsed.deinit();
    var json_out: std.ArrayList(u8) = .empty;
    defer json_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &json_parsed.value.object, &json_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, json_out.items, "// props:") == null);
    try testing.expect(std.mem.indexOf(u8, json_out.items, "\"name\":\"Probes\"") != null);
}

test "issue-290: codedb_search guidance does not warn on plain hyphen" {
    const args_json = "{\"query\":\"test-case\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    mcp_mod.mcpGenerateGuidance(testing.allocator, "codedb_search", &parsed.value.object, "", false, &buf);
    try testing.expect(std.mem.indexOf(u8, buf.items, "regex=true") == null);
}

// ── Issue #207: serve-first scan state ─────────────────────────────────────

test "issue-356-1: codedb_query returns partial results when a step fails" {
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

    // Pipeline: step 0 (find) succeeds, step 1 (search) is missing 'query'.
    // Pre-fix: bails on step 1, dropping step 0's output entirely.
    // Post-fix: returns step 0's matched files + a "--- partial ---" tail
    // naming the failing step.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"search"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Step 0's output (file matches) must survive even though step 1 failed.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    // The partial-results tail must name the failing step so callers can
    // recover instead of guessing what went wrong.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- partial ---") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "failed_at: 1") != null);
}

test "issue-356-3: codedb_query surfaces received keys on missing-arg errors" {
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

    // Single-step pipeline: search step missing 'query' but provided 'q'
    // (common typo). The error should name the keys actually received so
    // the caller can self-diagnose, mirroring the #357 bundle diagnostic.
    const pipe_json =
        \\{"pipeline":[{"op":"search","q":"main"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // The legitimate missing-arg error must still appear.
    try testing.expect(std.mem.indexOf(u8, out.items, "search needs 'query'") != null);
    // And the diagnostic must surface what the step actually contained.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "q") != null);
}

test "issue-356-p2: codedb_search missing query surfaces received keys" {
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
        \\{"q":"main"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'query'") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
}

test "issue-356-p3: codedb_query emits per-stage summary tail on success" {
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

    // Two-step pipeline that succeeds. Phase 3 emits a summary tail so
    // callers can see which step did what without re-parsing the
    // unstructured per-step output above it.
    const pipe_json =
        \\{"pipeline":[
        \\  {"op":"find","query":"main"},
        \\  {"op":"sort","by":"path"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pipe_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_query, &parsed.value.object, &out, &store, &explorer, &agents);

    // Stage summary appears at the end of a successful pipeline.
    try testing.expect(std.mem.indexOf(u8, out.items, "--- stages ---") != null);
    // Lists each step with op and outgoing file count.
    try testing.expect(std.mem.indexOf(u8, out.items, "0: find") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1: sort") != null);
}

test "issue-356-p3: codedb_outline includes actionable hint when parser fails" {
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

    // Outline a path that's NOT indexed (no setRoot, so disk read won't
    // help either). The "file not indexed" error already gets fuzzy
    // suggestions from phase 1. This test pins that the hint format is
    // actionable — specifically that a 'try codedb_index' suggestion
    // appears so users know how to recover from a stale index.
    const args_json =
        \\{"path":"src/notindexed.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "file not indexed") != null);
    // Phase 3 adds a 'codedb_index' hint so callers know how to recover
    // from a stale index in addition to the 'did you mean' suggestions.
    try testing.expect(std.mem.indexOf(u8, out.items, "codedb_index") != null);
}

test "issue-recall: codedb_search supports path_glob filter" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "received keys foo\n");
    try explorer.indexFile("CHANGELOG.md", "received keys diagnostic\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"received keys","path_glob":"*.zig"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "CHANGELOG.md") == null);
}

test "issue-bug7: codedb_search rejects empty query" {
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
        \\{"query":""}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "empty") != null);
}

test "issue-bug7: codedb_search rejects negative max_results" {
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
        \\{"query":"foo","max_results":-3}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "max_results") != null);
}

test "issue-390: codedb_search scope=true caps matches per file" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();

    // Build a "dominant" file with 20 matches plus several files with 1 match
    // each. Without a per-file cap on the scope=true path, the dominant file
    // alone drowns the response. The plain/regex branches already enforce
    // max_per_file=5 (mcp.zig:1141, 1198), but the scope=true branch does not.
    var dominant_buf: std.ArrayList(u8) = .empty;
    defer dominant_buf.deinit(testing.allocator);
    try dominant_buf.appendSlice(testing.allocator, "pub fn dominant() void {\n");
    for (0..20) |_| try dominant_buf.appendSlice(testing.allocator, "    // FROBNICATE token\n");
    try dominant_buf.appendSlice(testing.allocator, "}\n");
    try explorer.indexFile("src/dominant.zig", dominant_buf.items);
    try explorer.indexFile("src/a.zig", "// FROBNICATE here\npub fn a() void {}\n");
    try explorer.indexFile("src/b.zig", "// FROBNICATE here\npub fn b() void {}\n");
    try explorer.indexFile("src/c.zig", "// FROBNICATE here\npub fn c() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"FROBNICATE","scope":true,"max_results":100}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    // Count "src/dominant.zig:" occurrences (one per emitted match line).
    var dominant_lines: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, i, "src/dominant.zig:")) |pos| {
        dominant_lines += 1;
        i = pos + 1;
    }
    // The plain-search per-file cap is 5; scope=true should match. Without
    // any cap, all 20 matches surface and starve the smaller files.
    try testing.expect(dominant_lines <= 5);
    // The other files still surface — the cap shouldn't tank recall, just
    // bound the dominant file's share.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/a.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/b.zig:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/c.zig:") != null);
}

test "codedb_ls ranked annotates and sorts by hotspot score" {
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

    try explorer.indexFile("src/core.ts", "export function core() {}\nexport function helper() {}\n");
    try explorer.indexFile("src/leaf.ts", "export function leaf() {}\n");
    try explorer.indexFile("src/consumerA.ts", "import { core } from './core'\ncore();\n");
    try explorer.indexFile("src/consumerB.ts", "import { core } from './core'\ncore();\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"src\",\"ranked\":true}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &parsed.value.object, &out, &store, &explorer, &agents);

    const core_pos = std.mem.indexOf(u8, out.items, "core.ts") orelse return error.TestUnexpectedResult;
    const leaf_pos = std.mem.indexOf(u8, out.items, "leaf.ts") orelse return error.TestUnexpectedResult;
    try testing.expect(core_pos < leaf_pos);
    try testing.expect(std.mem.indexOf(u8, out.items, "2 deps") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "score") != null);
}

test "issue-591: codedb_search marks global-cap truncation" {
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    // 6 matching lines; max_results=3 caps the result set.
    try explorer.indexFile("src/a.zig", "const capMe = 1;\nconst capMe2 = 2;\nconst capMe3 = 3;\n");
    try explorer.indexFile("src/b.zig", "const capMe4 = 4;\nconst capMe5 = 5;\nconst capMe6 = 6;\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    // Capped: marker present.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"query":"capMe","max_results":3}
        , .{});
        defer parsed.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);
        try testing.expect(std.mem.indexOf(u8, out.items, "+more matches exist") != null);
    }
    // Under cap: no marker.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"query":"capMe","max_results":50}
        , .{});
        defer parsed.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);
        try testing.expect(std.mem.indexOf(u8, out.items, "+more matches exist") == null);
    }
    // JSON mode: summary.truncated is true when capped.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"query":"capMe","max_results":3,"output_format":"json"}
        , .{});
        defer parsed.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);
        try testing.expect(std.mem.indexOf(u8, out.items, "\"truncated\":true") != null);
    }
}

test "callers: semantic match finds calls in expression-bodied and single-line members" {
    // A call site on the same line as its enclosing member declaration
    // (`=> expr;` expression bodies, single-line `{ ... }` bodies) is still a
    // call site. The declaration-prefix veto must only suppress the declared
    // member's own header, not everything to the right of `=>` or `{`.
    try testing.expect(mcp_tools.callerLineMatches("    public Task<int> Fast(UserController u) => u.UpdateUserDetails(null);", "UpdateUserDetails", .c_sharp, "semantic"));
    try testing.expect(mcp_tools.callerLineMatches("    public void Go(UserController u) { u.UpdateUserDetails(null); }", "UpdateUserDetails", .c_sharp, "semantic"));
    // The declared member's own header name is still not a call site.
    try testing.expect(!mcp_tools.callerLineMatches("    public async Task<StorageResponse> WriteBytesAsync(string path, string fileName)", "WriteBytesAsync", .c_sharp, "semantic"));
    try testing.expect(!mcp_tools.callerLineMatches("    public Task<int> Fast(UserController u) => u.Update(null);", "Fast", .c_sharp, "semantic"));
}

test "callers: definition line with an extra same-name occurrence stays in references" {
    // `public MyCredoProUser.UserEntityPermission UserEntityPermission { get; set; }`
    // defines a property named like the type AND references the type. Excluding
    // the whole line as "a definition" hides a genuine usage — renaming the
    // type with that blast radius misses the property's type token.
    var explorer = Explorer.init(testing.allocator);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    try explorer.indexFile("Models/Entities.cs",
        \\namespace M {
        \\    public partial class UserEntityPermission
        \\    {
        \\        public int Id { get; set; }
        \\    }
        \\}
        \\
    );
    try explorer.indexFile("Models/ViewModels.cs",
        \\namespace M {
        \\    public class UserSettingsViewModel
        \\    {
        \\        public MyCredoProUser.UserEntityPermission UserEntityPermission { get; set; }
        \\    }
        \\}
        \\
    );

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".");
    defer bench_ctx.deinit();

    const args_json =
        \\{"name":"UserEntityPermission"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_callers, &parsed.value.object, &out, &store, &explorer, &agents);

    // The property line is BOTH a definition (of the property) and a reference
    // (to the type) — it must be reported.
    try testing.expect(std.mem.indexOf(u8, out.items, "Models/ViewModels.cs:4") != null);
    // The class definition line itself has only the defining occurrence — excluded.
    try testing.expect(std.mem.indexOf(u8, out.items, "Models/Entities.cs:2") == null);
}
