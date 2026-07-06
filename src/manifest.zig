// Package-manifest parsers (#591 Task 12) — the data source behind the
// codedb_manifest MCP tool. Answers "what does this project depend on, at
// what version" from local manifest files, parsed on demand at call time
// (manifests are small; no index or snapshot changes, always current).
//
// Parsers are deliberately small and dumb, with documented limits:
//   * package.json      — std.json; dependencies/devDependencies/peerDependencies
//   * go.mod            — line parser; require blocks + inline requires;
//                         `// indirect` → group .build
//   * Cargo.toml        — naive section/line parser; `name = "1.2"` and
//                         `name = { version = "…" }` forms; exotic TOML
//                         (multi-line arrays, dotted keys, target tables)
//                         is unsupported
//   * requirements.txt  — name + specifier per line; skips comments and
//                         option lines (-r includes, --flags)
//   * build.zig.zon     — naive `.dependencies` scan; url= or path= as spec
//
// NOT here (v1): lockfiles, transitive resolution. Malformed input must
// degrade gracefully (partial result or error.ParseFailed), never crash —
// CLAUDE.md review requirement.

const std = @import("std");

pub const ManifestKind = enum {
    package_json,
    go_mod,
    cargo_toml,
    requirements_txt,
    build_zig_zon,

    pub fn label(self: ManifestKind) []const u8 {
        return switch (self) {
            .package_json => "package.json (npm)",
            .go_mod => "go.mod (go)",
            .cargo_toml => "Cargo.toml (cargo)",
            .requirements_txt => "requirements.txt (pip)",
            .build_zig_zon => "build.zig.zon (zig)",
        };
    }
};

pub const DepGroup = enum {
    runtime,
    dev,
    peer,
    build,

    pub fn label(self: DepGroup) []const u8 {
        return @tagName(self);
    }
};

pub const Dependency = struct {
    name: []const u8,
    spec: []const u8,
    group: DepGroup,
};

pub const ParseError = error{ ParseFailed, OutOfMemory };

/// Map a manifest basename to its kind; null for everything else (including
/// lockfiles — package-lock.json etc. are deliberately not manifests here).
pub fn detectManifestKind(basename: []const u8) ?ManifestKind {
    if (std.mem.eql(u8, basename, "package.json")) return .package_json;
    if (std.mem.eql(u8, basename, "go.mod")) return .go_mod;
    if (std.mem.eql(u8, basename, "Cargo.toml")) return .cargo_toml;
    if (std.mem.eql(u8, basename, "requirements.txt")) return .requirements_txt;
    if (std.mem.eql(u8, basename, "build.zig.zon")) return .build_zig_zon;
    return null;
}

/// Pure parse over file content; caller owns the result (free with
/// `freeDependencies`, or hand an arena).
pub fn parseManifest(kind: ManifestKind, content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    return switch (kind) {
        .package_json => parsePackageJson(content, alloc),
        .go_mod => parseGoMod(content, alloc),
        .cargo_toml => parseCargoToml(content, alloc),
        .requirements_txt => parseRequirementsTxt(content, alloc),
        .build_zig_zon => parseBuildZigZon(content, alloc),
    };
}

pub fn freeDependencies(deps: []Dependency, alloc: std.mem.Allocator) void {
    for (deps) |d| {
        alloc.free(d.name);
        alloc.free(d.spec);
    }
    alloc.free(deps);
}

const DepList = std.ArrayList(Dependency);

fn appendDep(list: *DepList, alloc: std.mem.Allocator, name: []const u8, spec: []const u8, group: DepGroup) ParseError!void {
    const n = try alloc.dupe(u8, name);
    errdefer alloc.free(n);
    const s = try alloc.dupe(u8, spec);
    errdefer alloc.free(s);
    try list.append(alloc, .{ .name = n, .spec = s, .group = group });
}

// ── package.json ─────────────────────────────────────────────────────

fn parsePackageJson(content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseFailed,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const root = parsed.value.object;

    var out: DepList = .empty;
    errdefer {
        for (out.items) |d| {
            alloc.free(d.name);
            alloc.free(d.spec);
        }
        out.deinit(alloc);
    }

    const sections = [_]struct { key: []const u8, group: DepGroup }{
        .{ .key = "dependencies", .group = .runtime },
        .{ .key = "devDependencies", .group = .dev },
        .{ .key = "peerDependencies", .group = .peer },
    };
    for (sections) |section| {
        const val = root.get(section.key) orelse continue;
        if (val != .object) continue;
        var it = val.object.iterator();
        while (it.next()) |entry| {
            const spec = if (entry.value_ptr.* == .string) entry.value_ptr.string else "";
            try appendDep(&out, alloc, entry.key_ptr.*, spec, section.group);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ── go.mod ───────────────────────────────────────────────────────────

fn parseGoMod(content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    var out: DepList = .empty;
    errdefer {
        for (out.items) |d| {
            alloc.free(d.name);
            alloc.free(d.spec);
        }
        out.deinit(alloc);
    }

    var in_require_block = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        if (in_require_block) {
            if (std.mem.eql(u8, line, ")")) {
                in_require_block = false;
                continue;
            }
            try parseGoRequireLine(&out, alloc, line);
            continue;
        }
        if (std.mem.eql(u8, line, "require (")) {
            in_require_block = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "require ")) {
            try parseGoRequireLine(&out, alloc, line["require ".len..]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// One `module/path v1.2.3 [// indirect]` entry. `// indirect` marks a
/// transitive pin, not a direct dependency — grouped as .build to keep it
/// visible but distinct.
fn parseGoRequireLine(out: *DepList, alloc: std.mem.Allocator, entry: []const u8) ParseError!void {
    const indirect = std.mem.indexOf(u8, entry, "// indirect") != null;
    const code = if (std.mem.indexOf(u8, entry, "//")) |c| entry[0..c] else entry;
    var tok = std.mem.tokenizeAny(u8, code, " \t");
    const name = tok.next() orelse return;
    const version = tok.next() orelse "";
    if (name.len == 0) return;
    try appendDep(out, alloc, name, version, if (indirect) .build else .runtime);
}

// ── Cargo.toml ───────────────────────────────────────────────────────

fn parseCargoToml(content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    var out: DepList = .empty;
    errdefer {
        for (out.items) |d| {
            alloc.free(d.name);
            alloc.free(d.spec);
        }
        out.deinit(alloc);
    }

    var group: ?DepGroup = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            group = if (std.mem.eql(u8, line, "[dependencies]"))
                .runtime
            else if (std.mem.eql(u8, line, "[dev-dependencies]"))
                .dev
            else if (std.mem.eql(u8, line, "[build-dependencies]"))
                .build
            else
                null;
            continue;
        }
        const g = group orelse continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t\"");
        if (name.len == 0) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const spec = cargoValueSpec(value);
        try appendDep(&out, alloc, name, spec, g);
    }
    return out.toOwnedSlice(alloc);
}

/// `"1.2"` → 1.2; `{ version = "1.2", … }` → 1.2; anything else → "".
/// Only looks inside the first quoted string after `version =` — braces or
/// anything else inside string values can't derail the line-based scan.
fn cargoValueSpec(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, value, 1, '"')) |end| return value[1..end];
        return "";
    }
    if (value.len > 0 and value[0] == '{') {
        if (std.mem.indexOf(u8, value, "version")) |vpos| {
            const rest = value[vpos..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                if (std.mem.indexOfScalarPos(u8, rest, q1 + 1, '"')) |q2| {
                    return rest[q1 + 1 .. q2];
                }
            }
        }
    }
    return "";
}

// ── requirements.txt ─────────────────────────────────────────────────

fn parseRequirementsTxt(content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    var out: DepList = .empty;
    errdefer {
        for (out.items) |d| {
            alloc.free(d.name);
            alloc.free(d.spec);
        }
        out.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '-') continue;
        // Name ends at the first specifier/extras/marker character.
        var name_end: usize = line.len;
        for (line, 0..) |c, i| {
            switch (c) {
                '=', '<', '>', '!', '~', '[', ';', ' ' => {
                    name_end = i;
                    break;
                },
                else => {},
            }
        }
        const name = line[0..name_end];
        if (name.len == 0) continue;
        // Spec: the version constraint part, skipping extras like [standard].
        var spec_start = name_end;
        if (spec_start < line.len and line[spec_start] == '[') {
            spec_start = (std.mem.indexOfScalarPos(u8, line, spec_start, ']') orelse line.len);
            if (spec_start < line.len) spec_start += 1;
        }
        var spec = std.mem.trim(u8, line[@min(spec_start, line.len)..], " \t");
        if (std.mem.indexOfScalar(u8, spec, ';')) |m| spec = std.mem.trim(u8, spec[0..m], " \t");
        if (std.mem.indexOfScalar(u8, spec, '#')) |m| spec = std.mem.trim(u8, spec[0..m], " \t");
        try appendDep(&out, alloc, name, spec, .runtime);
    }
    return out.toOwnedSlice(alloc);
}

// ── build.zig.zon ────────────────────────────────────────────────────

fn parseBuildZigZon(content: []const u8, alloc: std.mem.Allocator) ParseError![]Dependency {
    var out: DepList = .empty;
    errdefer {
        for (out.items) |d| {
            alloc.free(d.name);
            alloc.free(d.spec);
        }
        out.deinit(alloc);
    }

    const deps_pos = std.mem.indexOf(u8, content, ".dependencies") orelse
        return out.toOwnedSlice(alloc);
    const open = std.mem.indexOfScalarPos(u8, content, deps_pos, '{') orelse
        return out.toOwnedSlice(alloc);

    // Walk the dependencies struct: at depth 1, `.name = .{` entries; inside
    // each entry (depth 2) capture the first `.url = "…"` or `.path = "…"`.
    // Quoted strings are skipped atomically so braces in URLs can't derail
    // the depth tracking; running off the end just returns what parsed.
    var i: usize = open + 1;
    var depth: usize = 1;
    var current_name: ?[]const u8 = null;
    var current_spec: []const u8 = "";
    while (i < content.len and depth > 0) {
        const c = content[i];
        if (c == '"') {
            const str = readZonString(content, i) orelse break;
            if (depth == 2 and current_name != null and current_spec.len == 0) {
                const before = std.mem.trimEnd(u8, content[open..i], " \t\r\n=\"");
                if (std.mem.endsWith(u8, before, ".url") or std.mem.endsWith(u8, before, ".path")) {
                    current_spec = str.value;
                }
            }
            i = str.end;
            continue;
        }
        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            if (depth == 2) {
                if (current_name) |n| {
                    try appendDep(&out, alloc, n, current_spec, .runtime);
                }
                current_name = null;
                current_spec = "";
            }
            depth -= 1;
            i += 1;
            continue;
        }
        if (depth == 1 and c == '.') {
            // `.ident = .{` — capture the entry name.
            const name_start = i + 1;
            var j = name_start;
            while (j < content.len and (std.ascii.isAlphanumeric(content[j]) or content[j] == '_')) j += 1;
            if (j > name_start) {
                const rest = std.mem.trimStart(u8, content[j..], " \t\r\n");
                if (std.mem.startsWith(u8, rest, "= .{") or std.mem.startsWith(u8, rest, "=.{")) {
                    current_name = content[name_start..j];
                    current_spec = "";
                }
            }
            i = j;
            continue;
        }
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const ZonString = struct { value: []const u8, end: usize };

/// Read the quoted string starting at `start` (content[start] == '"');
/// returns the unquoted slice and the index one past the closing quote.
/// Handles backslash escapes; null when unterminated.
fn readZonString(content: []const u8, start: usize) ?ZonString {
    var i = start + 1;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\') {
            i += 1;
            continue;
        }
        if (content[i] == '"') {
            return .{ .value = content[start + 1 .. i], .end = i + 1 };
        }
    }
    return null;
}
