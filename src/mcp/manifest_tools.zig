// codedb_manifest MCP tool (#591 Task 12) — local package-dependency facts.
//
// Answers three agent questions without shipping lockfiles or hitting the
// network:
//   (no args)          which manifests exist here, with dependency counts
//   path=<manifest>    full grouped dependency list for one manifest
//   name=<pkg>         which manifests declare a package, and at what spec
//
// Parse-on-demand: manifests are discovered by filename over the indexed
// outline keys (FilteredWalker already indexes them, nested workspace
// manifests included), then read fresh from disk at call time — so the
// answer is always current with zero index/snapshot changes.

const std = @import("std");
const cio = @import("../cio.zig");
const Explorer = @import("../explore.zig").Explorer;
const manifest_mod = @import("../manifest.zig");
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;

const max_manifest_bytes: usize = 1024 * 1024;

fn getStr(args: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return mcpj.getStr(args, key);
}

pub fn handleManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    project_root: []const u8,
) void {
    // Discover manifest paths from the index under a short shared lock; dupe
    // so file reads below happen unlocked. Discovery via the index (not a
    // fresh walk) keeps this within the project scope the walker already
    // vetted — no path traversal surface.
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        var it = explorer.outlines.keyIterator();
        while (it.next()) |key| {
            const p = key.*;
            const basename = if (std.mem.lastIndexOfScalar(u8, p, '/')) |sep| p[sep + 1 ..] else p;
            if (manifest_mod.detectManifestKind(basename) == null) continue;
            const duped = alloc.dupe(u8, p) catch continue;
            paths.append(alloc, duped) catch {
                alloc.free(duped);
                continue;
            };
        }
    }
    std.sort.block([]u8, paths.items, {}, struct {
        pub fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const w = cio.listWriter(out, alloc);

    if (paths.items.len == 0) {
        out.appendSlice(alloc, "no package manifests found (looked for package.json, go.mod, Cargo.toml, requirements.txt, build.zig.zon among indexed files)") catch {};
        return;
    }

    if (getStr(args, "path")) |req_path| {
        // Only paths the discovery produced are readable — the tool must not
        // become an arbitrary-file-read primitive (CLAUDE.md security rule).
        const known = blk: {
            for (paths.items) |p| {
                if (std.mem.eql(u8, p, req_path)) break :blk true;
            }
            break :blk false;
        };
        if (!known) {
            out.appendSlice(alloc, "error: not a known manifest path: ") catch {};
            out.appendSlice(alloc, req_path) catch {};
            out.appendSlice(alloc, "\nknown manifests:\n") catch {};
            for (paths.items) |p| {
                w.print("  {s}\n", .{p}) catch {};
            }
            return;
        }
        printManifestDeps(io, alloc, out, project_root, req_path);
        return;
    }

    if (getStr(args, "name")) |pkg_name| {
        var found: usize = 0;
        for (paths.items) |p| {
            const parsed = readAndParse(io, alloc, project_root, p) orelse continue;
            defer manifest_mod.freeDependencies(parsed.deps, alloc);
            for (parsed.deps) |d| {
                if (!std.mem.eql(u8, d.name, pkg_name)) continue;
                found += 1;
                if (d.spec.len > 0) {
                    w.print("{s}: {s} {s} ({s})\n", .{ p, d.name, d.spec, d.group.label() }) catch {};
                } else {
                    w.print("{s}: {s} ({s})\n", .{ p, d.name, d.group.label() }) catch {};
                }
            }
        }
        if (found == 0) {
            w.print("'{s}' is not declared in any manifest ({d} checked)", .{ pkg_name, paths.items.len }) catch {};
        }
        return;
    }

    // No args: list manifests with dependency counts.
    w.print("{d} manifest(s) found:\n", .{paths.items.len}) catch {};
    for (paths.items) |p| {
        if (readAndParse(io, alloc, project_root, p)) |parsed| {
            defer manifest_mod.freeDependencies(parsed.deps, alloc);
            w.print("  {s} — {s}, {d} dependencies\n", .{ p, parsed.kind.label(), parsed.deps.len }) catch {};
        } else {
            w.print("  {s} — unreadable or malformed\n", .{p}) catch {};
        }
    }
    out.appendSlice(alloc, "use path= for the full dependency list, name= to look up one package") catch {};
}

const ParsedManifest = struct {
    kind: manifest_mod.ManifestKind,
    deps: []manifest_mod.Dependency,
};

fn readAndParse(io: std.Io, alloc: std.mem.Allocator, project_root: []const u8, rel_path: []const u8) ?ParsedManifest {
    const basename = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sep| rel_path[sep + 1 ..] else rel_path;
    const kind = manifest_mod.detectManifestKind(basename) orelse return null;

    const dir = std.Io.Dir.cwd().openDir(io, project_root, .{}) catch return null;
    defer dir.close(io);
    const content = dir.readFileAlloc(io, rel_path, alloc, .limited(max_manifest_bytes)) catch return null;
    defer alloc.free(content);

    const deps = manifest_mod.parseManifest(kind, content, alloc) catch return null;
    return .{ .kind = kind, .deps = deps };
}

fn printManifestDeps(io: std.Io, alloc: std.mem.Allocator, out: *std.ArrayList(u8), project_root: []const u8, rel_path: []const u8) void {
    const w = cio.listWriter(out, alloc);
    const parsed = readAndParse(io, alloc, project_root, rel_path) orelse {
        out.appendSlice(alloc, "error: could not read or parse manifest: ") catch {};
        out.appendSlice(alloc, rel_path) catch {};
        return;
    };
    defer manifest_mod.freeDependencies(parsed.deps, alloc);

    w.print("{s} — {s}, {d} dependencies\n", .{ rel_path, parsed.kind.label(), parsed.deps.len }) catch {};
    const groups = [_]manifest_mod.DepGroup{ .runtime, .dev, .peer, .build };
    for (groups) |group| {
        var first = true;
        for (parsed.deps) |d| {
            if (d.group != group) continue;
            if (first) {
                w.print("[{s}]\n", .{group.label()}) catch {};
                first = false;
            }
            if (d.spec.len > 0) {
                w.print("  {s} {s}\n", .{ d.name, d.spec }) catch {};
            } else {
                w.print("  {s}\n", .{d.name}) catch {};
            }
        }
    }
}
