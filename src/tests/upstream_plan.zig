const std = @import("std");
const t = std.testing;
const io = t.io;
const Explorer = @import("../explore.zig").Explorer;
const tools = @import("../mcp/explore_tools.zig");
const deps = @import("../explore/deps.zig");
const Store = @import("../store.zig").Store;
const Walker = @import("../watcher/filtered_walker.zig").FilteredWalker;

test "release: search scopes and pipeline file sets are applied before a one-hit quota" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("other.ts", "const needle = 1;\nneedle();\nneedle();\n");
    try exp.indexFile("wanted.ts", "export function needle() {}\n");
    for ([_]bool{ false, true }) |regex| {
        const rows = if (regex)
            try exp.searchContentRegexFiltered("needle", t.allocator, 1, .{ .path_glob = "wanted.ts" })
        else
            try exp.searchContentFiltered("needle", t.allocator, 1, .{ .file_set = &.{"wanted.ts"} });
        defer {
            for (rows) |r| { t.allocator.free(r.path); t.allocator.free(r.line_text); }
            t.allocator.free(rows);
        }
        try t.expectEqual(@as(usize, 1), rows.len);
        try t.expectEqualStrings("wanted.ts", rows[0].path);
        const scoped = if (regex)
            try exp.searchContentRegexWithScopeFiltered("needle", t.allocator, 1, .{ .file_set = &.{"wanted.ts"} })
        else
            try exp.searchContentWithScopeFiltered("needle", t.allocator, 1, .{ .path_glob = "wanted.ts" });
        defer {
            for (scoped) |r| { t.allocator.free(r.path); t.allocator.free(r.line_text); if (r.scope_name) |n| t.allocator.free(n); }
            t.allocator.free(scoped);
        }
        try t.expectEqual(@as(usize, 1), scoped.len);
        try t.expectEqualStrings("wanted.ts", scoped[0].path);
    }
    const empty = try exp.searchContentFiltered("needle", t.allocator, 1, .{ .file_set = &.{} });
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
}

test "plan: callers apply whole-file lexical filtering before limits and scope" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("a.ts", "/*\nprobe();\n*/\nconst s = `probe()`;\nconst r = /probe()/;\nconst x = 'fake'; probe();\n");
    try exp.indexFile("other.ts", "probe();\n");
    for ([_]usize{1, 50}) |limit| {
        const rows = try tools.collectCallers(&exp, t.allocator, "probe", &.{}, "semantic", limit, "a.ts", false, null);
        defer {
            for (rows) |r| { t.allocator.free(r.path); t.allocator.free(r.line_text); if (r.scope_name) |s| t.allocator.free(s); }
            t.allocator.free(rows);
        }
        try t.expectEqual(@as(usize, 1), rows.len);
        try t.expectEqual(@as(u32, 6), rows[0].line_num);
    }
}

test "plan: FSharp references preserve applications pipelines quotations and generic values" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("uses.fs", "let a = f x\nlet b = x |> f\nlet c = f <| x\nlet d = <@ f x @>\nlet e = M.f<int> x\n(* f x\n f x *)\n");
    const rows = try tools.collectCallers(&exp, t.allocator, "f", &.{}, "references", 50, "**/*.fs", false, null);
    defer {
        for (rows) |r| { t.allocator.free(r.path); t.allocator.free(r.line_text); if (r.scope_name) |s| t.allocator.free(s); }
        t.allocator.free(rows);
    }
    try t.expectEqual(@as(usize, 5), rows.len);
}

test "plan: exact relative imports survive duplicate basenames and deletion" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("consumer.ts", "import { value } from './a/index';\n");
    try exp.indexFile("a/index.ts", "export const value = 1;\n");
    try exp.indexFile("b/index.ts", "export const value = 2;\n");
    for ([_][]const u8{"a/index.ts", "b/index.ts"}, 0..) |path, n| {
        const rows = try exp.getImportedBy(path, t.allocator);
        defer { for (rows) |p| t.allocator.free(p); t.allocator.free(rows); }
        try t.expectEqual(@as(usize, if (n == 0) 1 else 0), rows.len);
    }
    try t.expectEqualStrings("a/index.ts", deps.resolveLocalDependency(&exp, "local:a/index").?);
    exp.removeFile("a/index.ts");
    try t.expect(deps.resolveLocalDependency(&exp, "local:a/index") == null);
}

test "plan: FSharp dependencies prefer sibling sources and reject unrelated files and ambiguity" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("app/Consumer.fs", "module Consumer\nopen Domain\nopen Metadata\nopen FSharp.Data\n");
    try exp.indexFile("other/Domain.fs", "module Domain\nlet other = 1\n");
    try exp.indexFile("tools/Domain.fsx", "module Domain\nlet tool = 1\n");
    try exp.indexFile("lib/FSharp.Data.xml", "<doc />\n");
    try exp.indexFile("shared/Metadata.fs", "module Metadata\nlet value = 1\n");
    try exp.indexFile("lib/Metadata.xml", "<doc />\n");
    try t.expect(deps.resolveDependency(&exp, "app/Consumer.fs", "Domain") == null);
    try exp.indexFile("app/Domain.fs", "module Domain\nlet value = 1\n");

    const args = try std.json.parseFromSlice(std.json.Value, t.allocator,
        "{\"path\":\"app/Consumer.fs\",\"direction\":\"depends_on\",\"output_format\":\"json\"}", .{});
    defer args.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    tools.handleDeps(t.allocator, &args.value.object, &out, &exp);
    const response = try std.json.parseFromSlice(std.json.Value, t.allocator, out.items, .{});
    defer response.deinit();
    const hits = response.value.object.get("hits").?.array.items;
    try t.expectEqual(@as(usize, 3), hits.len);
    for ([_][]const u8{ "app/Domain.fs", "shared/Metadata.fs", "FSharp.Data" }, hits) |expected, hit| {
        try t.expectEqualStrings(expected, hit.object.get("path").?.string);
    }
    const transitive = try exp.getTransitiveDependencies("app/Consumer.fs", t.allocator, null);
    defer { for (transitive) |p| t.allocator.free(p); t.allocator.free(transitive); }
    try t.expectEqual(@as(usize, 3), transitive.len);
    for ([_][]const u8{ "app/Domain.fs", "shared/Metadata.fs", "FSharp.Data" }, transitive) |expected, actual| {
        try t.expectEqualStrings(expected, actual);
    }

    // Same-directory ambiguity must not fall through to a global candidate.
    try exp.indexFile("app/Domain.fsx", "module Domain\nlet ambiguous = 1\n");
    try t.expect(deps.resolveDependency(&exp, "app/Consumer.fs", "Domain") == null);
    exp.removeFile("app/Domain.fsx");
    try t.expectEqualStrings("app/Domain.fs", deps.resolveDependency(&exp, "app/Consumer.fs", "Domain").?);
    exp.removeFile("app/Domain.fs");
    try t.expect(deps.resolveDependency(&exp, "app/Consumer.fs", "Domain") == null);
}

test "plan: nested ignore negation security and explicit rebuild agree" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.skip.ts\n!keep.skip.ts\n*.[Pp]ublish.xml\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/.gitignore", .data = "/hidden.ts\n" });
    for ([_][]const u8{"keep.skip.ts", "drop.skip.ts", "nested/hidden.ts", "nested/open.ts", ".ENV", "nested/Debug.publish.xml"}) |p| {
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "export const probe = 1;\n" });
    }
    var walker = try Walker.init(io, tmp.dir, t.allocator);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next()) |entry| {
        try t.expect(!std.mem.eql(u8, entry.path, "drop.skip.ts"));
        try t.expect(!std.mem.eql(u8, entry.path, "nested/hidden.ts"));
        try t.expect(!std.mem.eql(u8, entry.path, ".ENV"));
        try t.expect(!std.mem.eql(u8, entry.path, "nested/Debug.publish.xml"));
        if (std.mem.endsWith(u8, entry.path, ".ts")) found += 1;
    }
    try t.expectEqual(@as(usize, 2), found);
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("nested/hidden.ts", "export const stale = 1;");
    var store = Store.init(t.allocator);
    defer store.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(root);
    try @import("../watcher/reconcile.zig").reconcileAll(io, &exp, &store, root, t.allocator);
    try t.expect(!exp.outlines.contains("nested/hidden.ts"));
    try t.expect(exp.outlines.contains("keep.skip.ts"));
    try t.expect(exp.outlines.contains("nested/open.ts"));
}

test "plan: bounded tsconfig aliases and package imports stay distinct" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\":{\"baseUrl\":\".\",\"paths\":{\"@app/*\":[\"src/*\"]}}}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(root);
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    exp.setRoot(io, root);
    try exp.indexFile("consumer.ts", "import { x } from '@app/model';\nimport React from 'react';\n");
    try exp.indexFile("src/model.ts", "export const x = 1;\n");
    try exp.indexFile("react.ts", "export const fake = 1;\n");
    const rows = try exp.getImportedBy("src/model.ts", t.allocator);
    defer { for (rows) |p| t.allocator.free(p); t.allocator.free(rows); }
    try t.expectEqual(@as(usize, 1), rows.len);
    const external = try exp.getImportedBy("react.ts", t.allocator);
    defer { for (external) |p| t.allocator.free(p); t.allocator.free(external); }
    try t.expectEqual(@as(usize, 0), external.len);
}

test "plan: dotnet project facts preserve compile order and ignore tasks and comments" {
    const m = @import("../manifest.zig");
    const rows = try m.parseManifest(.dotnet_project,
        "<Project><!-- <Compile Include=\"fake.fs\"/> --><ItemGroup><Compile Include=\"First.fs\"/><Compile Include=\"Second.fs\"/><ProjectReference Include=\"../Other/Other.fsproj\"/></ItemGroup><Target><Exec Command=\"never execute\"/></Target></Project>", t.allocator);
    defer m.freeDependencies(rows, t.allocator);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("First.fs", rows[0].name);
    try t.expectEqualStrings("Second.fs", rows[1].name);
    try t.expectEqualStrings("ProjectReference", rows[2].spec);
}

test "plan: qualified CSharp names distinguish same-name declarations" {
    var exp = Explorer.init(t.allocator);
    defer exp.deinit();
    try exp.indexFile("a.cs", "namespace Alpha;\npublic class Probe {}\n");
    try exp.indexFile("b.cs", "namespace Beta;\npublic class Probe {}\n");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const rows = try exp.findAllSymbols("Alpha.Probe", arena.allocator());
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings("a.cs", rows[0].path);
}
