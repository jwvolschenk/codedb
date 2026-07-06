// Tests for src/manifest.zig (#591 Task 12) — package-manifest parsers behind
// the codedb_manifest tool. Small and dumb by design; malformed input must
// parse gracefully (CLAUDE.md requirement), never crash.
//
// Picked up by the test runner via tests.zig, which re-imports this file.

const std = @import("std");
const testing = std.testing;
const manifest = @import("../manifest.zig");

fn freeDeps(deps: []manifest.Dependency) void {
    manifest.freeDependencies(deps, testing.allocator);
}

fn findDep(deps: []const manifest.Dependency, name: []const u8) ?manifest.Dependency {
    for (deps) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

// ── detectManifestKind ───────────────────────────────────────────────

test "manifest: detectManifestKind maps known basenames" {
    try testing.expectEqual(manifest.ManifestKind.package_json, manifest.detectManifestKind("package.json").?);
    try testing.expectEqual(manifest.ManifestKind.go_mod, manifest.detectManifestKind("go.mod").?);
    try testing.expectEqual(manifest.ManifestKind.cargo_toml, manifest.detectManifestKind("Cargo.toml").?);
    try testing.expectEqual(manifest.ManifestKind.requirements_txt, manifest.detectManifestKind("requirements.txt").?);
    try testing.expectEqual(manifest.ManifestKind.build_zig_zon, manifest.detectManifestKind("build.zig.zon").?);
    try testing.expect(manifest.detectManifestKind("main.zig") == null);
    try testing.expect(manifest.detectManifestKind("package-lock.json") == null);
}

// ── package.json ─────────────────────────────────────────────────────

test "manifest: package.json dependencies/devDependencies/peerDependencies" {
    const deps = try manifest.parseManifest(.package_json,
        \\{
        \\  "name": "app",
        \\  "dependencies": { "react": "^18.2.0", "lodash": "4.17.21" },
        \\  "devDependencies": { "vitest": "^1.0.0" },
        \\  "peerDependencies": { "react-dom": ">=18" }
        \\}
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 4), deps.len);
    const react = findDep(deps, "react").?;
    try testing.expectEqualStrings("^18.2.0", react.spec);
    try testing.expectEqual(manifest.DepGroup.runtime, react.group);
    try testing.expectEqual(manifest.DepGroup.dev, findDep(deps, "vitest").?.group);
    try testing.expectEqual(manifest.DepGroup.peer, findDep(deps, "react-dom").?.group);
}

test "manifest: truncated package.json parses gracefully (error, no crash)" {
    const result = manifest.parseManifest(.package_json,
        \\{ "dependencies": { "react": "^18
    , testing.allocator);
    try testing.expectError(error.ParseFailed, result);
}

test "manifest: package.json without dependency keys yields empty" {
    const deps = try manifest.parseManifest(.package_json,
        \\{ "name": "app", "version": "1.0.0" }
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

// ── go.mod ───────────────────────────────────────────────────────────

test "manifest: go.mod block and inline requires, indirect grouped as build" {
    const deps = try manifest.parseManifest(.go_mod,
        \\module example.com/app
        \\
        \\go 1.22
        \\
        \\require (
        \\    github.com/gin-gonic/gin v1.9.1
        \\    golang.org/x/sync v0.6.0 // indirect
        \\)
        \\
        \\require github.com/stretchr/testify v1.8.4
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 3), deps.len);
    const gin = findDep(deps, "github.com/gin-gonic/gin").?;
    try testing.expectEqualStrings("v1.9.1", gin.spec);
    try testing.expectEqual(manifest.DepGroup.runtime, gin.group);
    try testing.expectEqual(manifest.DepGroup.build, findDep(deps, "golang.org/x/sync").?.group);
    try testing.expectEqual(manifest.DepGroup.runtime, findDep(deps, "github.com/stretchr/testify").?.group);
}

test "manifest: go.mod with unterminated require block parses what it can" {
    const deps = try manifest.parseManifest(.go_mod,
        \\module m
        \\require (
        \\    github.com/a/b v1.0.0
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 1), deps.len);
}

// ── Cargo.toml ───────────────────────────────────────────────────────

test "manifest: Cargo.toml sections and both value forms" {
    const deps = try manifest.parseManifest(.cargo_toml,
        \\[package]
        \\name = "app"
        \\
        \\[dependencies]
        \\serde = "1.0"
        \\tokio = { version = "1.35", features = ["full"] }
        \\
        \\[dev-dependencies]
        \\criterion = "0.5"
        \\
        \\[build-dependencies]
        \\cc = "1.0"
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 4), deps.len);
    try testing.expectEqualStrings("1.0", findDep(deps, "serde").?.spec);
    try testing.expectEqualStrings("1.35", findDep(deps, "tokio").?.spec);
    try testing.expectEqual(manifest.DepGroup.dev, findDep(deps, "criterion").?.group);
    try testing.expectEqual(manifest.DepGroup.build, findDep(deps, "cc").?.group);
}

test "manifest: Cargo.toml empty dependencies section yields nothing" {
    const deps = try manifest.parseManifest(.cargo_toml,
        \\[dependencies]
        \\
        \\[package]
        \\name = "x"
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "manifest: Cargo.toml braces inside strings don't break the parser" {
    const deps = try manifest.parseManifest(.cargo_toml,
        \\[dependencies]
        \\weird = { version = "1.0", note = "contains { braces } here" }
        \\after = "2.0"
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expect(findDep(deps, "after") != null);
}

// ── requirements.txt ─────────────────────────────────────────────────

test "manifest: requirements.txt names, specifiers, comments, includes" {
    const deps = try manifest.parseManifest(.requirements_txt,
        \\# comment line
        \\requests==2.31.0
        \\flask>=2.0,<3.0
        \\numpy
        \\-r other-requirements.txt
        \\--index-url https://example.com
        \\uvicorn[standard]~=0.27
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 4), deps.len);
    try testing.expectEqualStrings("==2.31.0", findDep(deps, "requests").?.spec);
    try testing.expectEqualStrings(">=2.0,<3.0", findDep(deps, "flask").?.spec);
    try testing.expectEqualStrings("", findDep(deps, "numpy").?.spec);
    try testing.expect(findDep(deps, "uvicorn") != null);
}

// ── build.zig.zon ────────────────────────────────────────────────────

test "manifest: build.zig.zon dependencies with url and path forms" {
    const deps = try manifest.parseManifest(.build_zig_zon,
        \\.{
        \\    .name = "app",
        \\    .version = "0.1.0",
        \\    .dependencies = .{
        \\        .mcp_zig = .{
        \\            .url = "https://example.com/mcp-0.2.0.tar.gz",
        \\            .hash = "1220abcd",
        \\        },
        \\        .local_lib = .{
        \\            .path = "../local_lib",
        \\        },
        \\    },
        \\    .paths = .{ "src" },
        \\}
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("https://example.com/mcp-0.2.0.tar.gz", findDep(deps, "mcp_zig").?.spec);
    try testing.expectEqualStrings("../local_lib", findDep(deps, "local_lib").?.spec);
}

test "manifest: build.zig.zon without dependencies yields empty" {
    const deps = try manifest.parseManifest(.build_zig_zon,
        \\.{ .name = "app", .version = "0.1.0" }
    , testing.allocator);
    defer freeDeps(deps);
    try testing.expectEqual(@as(usize, 0), deps.len);
}

test "manifest: build.zig.zon unbalanced braces parse gracefully" {
    const deps = try manifest.parseManifest(.build_zig_zon,
        \\.{ .dependencies = .{ .broken = .{ .url = "https://x
    , testing.allocator);
    defer freeDeps(deps);
    // Whatever partial result comes back, it must not crash or leak.
}
