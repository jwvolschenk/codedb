# Godot Project Parsing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** codedb parses Godot projects — GDScript symbol outlines, scene/resource dependency edges, project.godot autoloads — and stops indexing Godot sidecar noise.

**Architecture:** A new zero-dependency line-parser module `src/godot_parser.zig` (modeled on `t4_parser.zig` / `tsql_parser.zig`) returning a `ParsedLine` union, dispatched from the per-line language chain in `src/explore/lifecycle.zig`. Four new `Language` enum values. Skip-rule additions in `src/watcher/skip_rules.zig`. No `SymbolKind` enum changes — Godot semantics ride in the `detail` field.

**Tech Stack:** Zig (matching existing codebase, `zig build test` test runner), Python 3 for the E2E MCP script.

**Spec:** `docs/superpowers/specs/2026-07-09-godot-parsing-design.md`

## Global Constraints

- No new dependencies; line-based parsing only (no tree-sitter, no regex engines).
- No new `SymbolKind` enum values (snapshot compatibility).
- Malformed input must degrade to `.none`, never crash: `#` inside strings, unterminated `"""`, escaped quotes in attributes, missing `]` (CLAUDE.md parser guideline).
- No >10% regression in benchmark-critical paths (CLAUDE.md). New code is new else-if branches at the END of the language dispatch chain — do not reorder existing branches.
- Pre-merge (CLAUDE.md): `zig build test` AND `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /mnt/storage/repos/codedb`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Reference Godot project for validation: `~/repos/games/lunch-rush`.

---

### Task 1: Language detection for Godot file types

**Files:**
- Modify: `src/explore/types.zig` (Language enum ~line 86-131, detectLanguage ~line 133-182)
- Test: `src/tests/explorer_core.zig` (existing detectLanguage test, ends ~line 626)

**Interfaces:**
- Produces: `Language.gdscript`, `Language.godot_scene`, `Language.godot_resource`, `Language.godot_project` enum values — Tasks 4 and 5 dispatch on these. `detectLanguage("x.gd") == .gdscript`, `.tscn` → `.godot_scene`, `.tres` → `.godot_resource`, `project.godot` → `.godot_project`.

- [ ] **Step 1: Write the failing test**

In `src/tests/explorer_core.zig`, inside the existing `test` block that contains `explore.detectLanguage("Model.tt") == .t4_template` (~line 622), add before the `Makefile` line:

```zig
    try testing.expect(explore.detectLanguage("Player.gd") == .gdscript);
    try testing.expect(explore.detectLanguage("Main.tscn") == .godot_scene);
    try testing.expect(explore.detectLanguage("CardData.tres") == .godot_resource);
    try testing.expect(explore.detectLanguage("project.godot") == .godot_project);
    try testing.expect(explore.detectLanguage("games/lunch-rush/project.godot") == .godot_project);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `no field named 'gdscript' in enum` (the enum values don't exist yet).

- [ ] **Step 3: Write minimal implementation**

In `src/explore/types.zig`, append to the `Language` enum (after `ssrs_project,`):

```zig
    gdscript,
    godot_scene,
    godot_resource,
    godot_project,
```

In `detectLanguage`, add before `return .unknown;`:

```zig
    if (std.mem.endsWith(u8, path, ".gd")) return .gdscript;
    if (std.mem.endsWith(u8, path, ".tscn")) return .godot_scene;
    if (std.mem.endsWith(u8, path, ".tres")) return .godot_resource;
    if (std.mem.endsWith(u8, path, "project.godot")) return .godot_project;
```

Do NOT touch `isDocLanguage` — the new languages must not be listed there (they are code, not prose; that's the point).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: all tests pass, no failures mentioning detectLanguage.

- [ ] **Step 5: Commit**

```bash
git add src/explore/types.zig src/tests/explorer_core.zig
git commit -m "feat: detect Godot file types (.gd, .tscn, .tres, project.godot)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Skip rules — exclude Godot cache dirs and sidecar files

**Files:**
- Modify: `src/watcher/skip_rules.zig` (`skip_dirs` ~line 69, `skip_extensions` ~line 186)
- Test: `src/watcher/skip_rules_tests.zig`

**Interfaces:**
- Produces: `shouldSkipDir(".godot") == true`, `shouldSkipDir(".import") == true`; `shouldSkipFile` true for `*.uid`, `*.import`, `*.translation`. No signature changes.

- [ ] **Step 1: Write the failing test**

Append to `src/watcher/skip_rules_tests.zig`:

```zig
test "godot: cache dirs and sidecar files are skipped" {
    const skip_rules = @import("skip_rules.zig");
    const testing = @import("std").testing;

    // Godot 4 cache dir and Godot 3 import cache dir
    try testing.expect(skip_rules.shouldSkipDir(".godot"));
    try testing.expect(skip_rules.shouldSkipDir(".import"));
    try testing.expect(skip_rules.shouldSkip("lunch-rush/.godot/imported/icon.png-abc.ctex"));

    // Sidecar files: .uid (Godot 4.4+), .import (per-asset), compiled .translation
    try testing.expect(skip_rules.shouldSkipFile("TowerManager.gd.uid"));
    try testing.expect(skip_rules.shouldSkipFile("icon.svg.import"));
    try testing.expect(skip_rules.shouldSkipFile("locale/en.translation"));

    // Real Godot sources must NOT be skipped
    try testing.expect(!skip_rules.shouldSkipFile("TowerManager.gd"));
    try testing.expect(!skip_rules.shouldSkipFile("Main.tscn"));
    try testing.expect(!skip_rules.shouldSkipFile("CardData.tres"));
    try testing.expect(!skip_rules.shouldSkipFile("project.godot"));
}
```

Note: match the existing import style at the top of `skip_rules_tests.zig` — if it already has `const skip_rules = @import("skip_rules.zig");` and `const testing = std.testing;` at file scope, use those instead of redeclaring inside the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL on the `.godot` shouldSkipDir expectation.

- [ ] **Step 3: Write minimal implementation**

In `src/watcher/skip_rules.zig`, add to `skip_dirs` (after `"bower_components",`):

```zig
    ".godot", // godot 4 editor cache (imported assets, shader cache)
    ".import", // godot 3 import cache dir
```

Add to `skip_extensions` (extend the last row; keep zig fmt happy):

```zig
    ".uid",     ".import", ".translation",
```

(Exact alignment will be normalized by `zig fmt` — run `zig fmt src/watcher/skip_rules.zig` after editing.)

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/watcher/skip_rules.zig src/watcher/skip_rules_tests.zig
git commit -m "feat: skip Godot cache dirs (.godot, .import) and sidecars (.uid, .import, .translation)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: godot_parser.zig — GDScript line parser

**Files:**
- Create: `src/godot_parser.zig`
- Create: `src/tests/parsers/godot.zig`
- Modify: `src/tests.zig` (register the new test file, ~line 24)

**Interfaces:**
- Produces (consumed by Task 5's dispatch):
  - `pub const Kind = enum { class_name_decl, inner_class, function_def, method_def, signal_decl, variable_decl, constant_decl, enum_decl, node_def, connection, resource_def, input_action, section_header }`
  - `pub const ParsedLine = union(enum) { none, symbol: struct { name: []const u8, kind: Kind }, import: struct { path: []const u8 }, annotation: struct { name: []const u8 } }`
  - `pub const GdState = struct { in_multiline_string: bool = false, inner_class_indent: ?usize = null }`
  - `pub fn parseGdLine(raw_line: []const u8, trimmed: []const u8, state: *GdState) ParsedLine`
  - `pub fn extractResPath(line: []const u8) ?[]const u8` — preload/load references
  - `pub fn stripGdComment(line: []const u8) []const u8` — string-aware `#` comment stripping (dispatch uses it before extractResPath)
  - All returned slices point into the input line; callers must dupe (appendOutlineSymbol/appendImportSymbol already do).

- [ ] **Step 1: Write the failing tests**

Create `src/tests/parsers/godot.zig`:

```zig
// Tests for src/godot_parser.zig — GDScript, scene, resource, project.godot.
const std = @import("std");
const testing = std.testing;
const gp = @import("../../godot_parser.zig");

fn parseGd(line: []const u8, state: *gp.GdState) gp.ParsedLine {
    return gp.parseGdLine(line, std.mem.trim(u8, line, " \t"), state);
}

test "gdscript: class_name declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("class_name TowerManager", &st);
    try testing.expectEqualStrings("TowerManager", r.symbol.name);
    try testing.expectEqual(gp.Kind.class_name_decl, r.symbol.kind);
}

test "gdscript: extends by class name becomes an import" {
    var st: gp.GdState = .{};
    const r = parseGd("extends Node2D", &st);
    try testing.expectEqualStrings("Node2D", r.import.path);
}

test "gdscript: extends by res:// path becomes a project-relative import" {
    var st: gp.GdState = .{};
    const r = parseGd("extends \"res://enemy/base_enemy.gd\"", &st);
    try testing.expectEqualStrings("enemy/base_enemy.gd", r.import.path);
}

test "gdscript: func with params and return type" {
    var st: gp.GdState = .{};
    const r = parseGd("func place_tower(tower_scene: PackedScene, lane_index: int) -> bool:", &st);
    try testing.expectEqualStrings("place_tower", r.symbol.name);
    try testing.expectEqual(gp.Kind.function_def, r.symbol.kind);
}

test "gdscript: static func" {
    var st: gp.GdState = .{};
    const r = parseGd("static func from_dict(d: Dictionary) -> SaveData:", &st);
    try testing.expectEqualStrings("from_dict", r.symbol.name);
    try testing.expectEqual(gp.Kind.function_def, r.symbol.kind);
}

test "gdscript: signal declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("signal tower_placed(tower: Node2D, lane_index: int)", &st);
    try testing.expectEqualStrings("tower_placed", r.symbol.name);
    try testing.expectEqual(gp.Kind.signal_decl, r.symbol.kind);
}

test "gdscript: bare signal without params" {
    var st: gp.GdState = .{};
    const r = parseGd("signal wave_started", &st);
    try testing.expectEqualStrings("wave_started", r.symbol.name);
}

test "gdscript: var, const, enum" {
    var st: gp.GdState = .{};
    const v = parseGd("var lane_count: int = 0", &st);
    try testing.expectEqualStrings("lane_count", v.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, v.symbol.kind);

    const c = parseGd("const MAX_TOWERS = 32", &st);
    try testing.expectEqualStrings("MAX_TOWERS", c.symbol.name);
    try testing.expectEqual(gp.Kind.constant_decl, c.symbol.kind);

    const e = parseGd("enum TowerType { BASIC, SPLASH, SNIPER }", &st);
    try testing.expectEqualStrings("TowerType", e.symbol.name);
    try testing.expectEqual(gp.Kind.enum_decl, e.symbol.kind);
}

test "gdscript: inline annotation still yields the declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("@export var default_tower_scene: PackedScene", &st);
    try testing.expectEqualStrings("default_tower_scene", r.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, r.symbol.kind);

    const r2 = parseGd("@export_range(0, 10) var speed: float = 1.0", &st);
    try testing.expectEqualStrings("speed", r2.symbol.name);
}

test "gdscript: standalone annotation line" {
    var st: gp.GdState = .{};
    const r = parseGd("@rpc(\"any_peer\")", &st);
    try testing.expectEqualStrings("@rpc", r.annotation.name);
    const r2 = parseGd("@tool", &st);
    try testing.expectEqualStrings("@tool", r2.annotation.name);
}

test "gdscript: inner class scope makes funcs methods" {
    var st: gp.GdState = .{};
    const cls = parseGd("class WaveEntry:", &st);
    try testing.expectEqualStrings("WaveEntry", cls.symbol.name);
    try testing.expectEqual(gp.Kind.inner_class, cls.symbol.kind);

    const m = parseGd("\tfunc duration() -> float:", &st);
    try testing.expectEqual(gp.Kind.method_def, m.symbol.kind);

    // Back at top level: plain function again
    const f = parseGd("func start_wave():", &st);
    try testing.expectEqual(gp.Kind.function_def, f.symbol.kind);
}

test "gdscript: hash inside string is not a comment" {
    var st: gp.GdState = .{};
    const r = parseGd("var color_tag = \"#ff0000\"", &st);
    try testing.expectEqualStrings("color_tag", r.symbol.name);
}

test "gdscript: comment lines and commented-out decls yield none" {
    var st: gp.GdState = .{};
    try testing.expect(parseGd("# func not_real():", &st) == .none);
    try testing.expect(parseGd("## docstring comment", &st) == .none);
}

test "gdscript: multiline string swallows fake decls until closed" {
    var st: gp.GdState = .{};
    _ = parseGd("var doc = \"\"\"", &st);
    try testing.expect(st.in_multiline_string);
    try testing.expect(parseGd("func fake_decl_inside_string():", &st) == .none);
    _ = parseGd("\"\"\"", &st);
    try testing.expect(!st.in_multiline_string);
    const r = parseGd("func real_decl():", &st);
    try testing.expectEqualStrings("real_decl", r.symbol.name);
}

test "gdscript: unterminated multiline string does not crash later parsing" {
    var st: gp.GdState = .{};
    _ = parseGd("var s = \"\"\"never closed", &st);
    try testing.expect(parseGd("func swallowed():", &st) == .none); // stays inside; no crash
}

test "gdscript: extractResPath finds preload and load references" {
    try testing.expectEqualStrings(
        "tower/Tower.tscn",
        gp.extractResPath("const TowerScene = preload(\"res://tower/Tower.tscn\")").?,
    );
    try testing.expectEqualStrings(
        "GameState.gd",
        gp.extractResPath("var gs = load(\"res://GameState.gd\")").?,
    );
    try testing.expect(gp.extractResPath("var x = compute(1, 2)") == null);
    try testing.expect(gp.extractResPath("preload(\"user://save.dat\")") == null);
}

test "gdscript: stripGdComment respects strings; commented-out preload yields no path" {
    try testing.expectEqualStrings(
        "var color = \"#ff0000\"",
        gp.stripGdComment("var color = \"#ff0000\" # a hex color"),
    );
    // Callers strip comments before extracting res:// paths (see lifecycle
    // dispatch) so commented-out preloads don't become dependency edges.
    try testing.expect(gp.extractResPath(gp.stripGdComment("# preload(\"res://x.gd\")")) == null);
}
```

Register the file in `src/tests.zig` after the `tests/parsers/tsql.zig` import:

```zig
    _ = @import("tests/parsers/godot.zig");
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: compile error — `src/godot_parser.zig` does not exist.

- [ ] **Step 3: Write the implementation**

Create `src/godot_parser.zig`:

```zig
// codedb — line parsers for Godot projects: GDScript (.gd), scenes (.tscn),
// resources (.tres), and project.godot. Zero-dependency and line-based, in
// the style of t4_parser.zig / tsql_parser.zig. Returned slices point into
// the input line; callers dupe what they keep.
const std = @import("std");

/// Godot-specific symbol kinds, mapped to generic SymbolKind in lifecycle.zig.
pub const Kind = enum {
    class_name_decl, // class_name Foo
    inner_class, // class Foo: (nested in a script)
    function_def, // func foo(): at script top level
    method_def, // func foo(): inside an inner class
    signal_decl, // signal foo(a, b)
    variable_decl, // var x / @export var x
    constant_decl, // const X = 1
    enum_decl, // enum Foo { A, B }
    node_def, // [node name="Main" type="Node2D" ...]
    connection, // [connection signal="pressed" from=... to=... method=...]
    resource_def, // [gd_resource ... script_class="CardData"]
    input_action, // project.godot [input] action key
    section_header, // project.godot [section]
};

pub const ParsedLine = union(enum) {
    none,
    symbol: struct {
        name: []const u8,
        kind: Kind,
    },
    import: struct {
        path: []const u8,
    },
    annotation: struct {
        name: []const u8, // standalone @annotation line, e.g. "@export"
    },
};

/// Per-file parse state for GDScript.
pub const GdState = struct {
    in_multiline_string: bool = false,
    inner_class_indent: ?usize = null,
};

/// project.godot section tracking.
pub const ProjectSection = enum { none, autoload, input, other };

// ── GDScript ───────────────────────────────────────────────────────────────

pub fn parseGdLine(raw_line: []const u8, trimmed: []const u8, state: *GdState) ParsedLine {
    if (trimmed.len == 0) return .none;

    // Multiline ("""/''') string tracking: an odd number of markers on a
    // line toggles the state. Inside one, nothing is a declaration.
    if (state.in_multiline_string) {
        if (countTripleQuotes(trimmed) % 2 == 1) state.in_multiline_string = false;
        return .none;
    }

    const line = stripGdComment(trimmed);
    if (line.len == 0) return .none;
    if (countTripleQuotes(line) % 2 == 1) state.in_multiline_string = true;

    const indent = leadingIndent(raw_line);
    // Any declaration at or below the inner class's own indent leaves its scope.
    if (state.inner_class_indent) |ci| {
        if (indent <= ci) state.inner_class_indent = null;
    }

    if (line[0] == '@') {
        const rest = skipAnnotations(line);
        if (rest.len == 0) return .{ .annotation = .{ .name = firstAnnotationName(line) } };
        return parseGdDecl(rest, indent, state);
    }
    return parseGdDecl(line, indent, state);
}

fn parseGdDecl(line: []const u8, indent: usize, state: *GdState) ParsedLine {
    if (std.mem.startsWith(u8, line, "class_name ")) {
        const name = extractIdent(line["class_name ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .class_name_decl } };
    }
    if (std.mem.startsWith(u8, line, "extends ")) {
        const target = std.mem.trim(u8, line["extends ".len..], " \t");
        if (target.len >= 2 and target[0] == '"') {
            // extends "res://base.gd"
            const inner = target[1..];
            const end = std.mem.indexOfScalar(u8, inner, '"') orelse return .none;
            return .{ .import = .{ .path = stripResPrefix(inner[0..end]) } };
        }
        const name = extractIdent(target) orelse return .none;
        return .{ .import = .{ .path = name } };
    }
    if (std.mem.startsWith(u8, line, "class ")) {
        const name = extractIdent(line["class ".len..]) orelse return .none;
        state.inner_class_indent = indent;
        return .{ .symbol = .{ .name = name, .kind = .inner_class } };
    }
    var rest = line;
    if (std.mem.startsWith(u8, rest, "static ")) rest = rest["static ".len..];
    if (std.mem.startsWith(u8, rest, "func ")) {
        const name = extractIdent(rest["func ".len..]) orelse return .none;
        const kind: Kind = if (state.inner_class_indent) |ci|
            (if (indent > ci) .method_def else .function_def)
        else
            .function_def;
        return .{ .symbol = .{ .name = name, .kind = kind } };
    }
    if (std.mem.startsWith(u8, line, "signal ")) {
        const name = extractIdent(line["signal ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .signal_decl } };
    }
    if (std.mem.startsWith(u8, line, "var ")) {
        const name = extractIdent(line["var ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .variable_decl } };
    }
    if (std.mem.startsWith(u8, line, "const ")) {
        const name = extractIdent(line["const ".len..]) orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .constant_decl } };
    }
    if (std.mem.startsWith(u8, line, "enum ")) {
        const name = extractIdent(line["enum ".len..]) orelse "enum";
        return .{ .symbol = .{ .name = name, .kind = .enum_decl } };
    }
    return .none;
}

/// Find a preload("res://...") or load("res://...") reference on a line.
/// Returns the project-relative path (res:// stripped), or null. Only
/// res:// paths count — user:// and absolute paths are runtime-only.
pub fn extractResPath(line: []const u8) ?[]const u8 {
    const keywords = [_][]const u8{ "preload(\"", "load(\"" };
    for (keywords) |kw| {
        const pos = std.mem.indexOf(u8, line, kw) orelse continue;
        const rest = line[pos + kw.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const path = rest[0..end];
        if (std.mem.startsWith(u8, path, "res://")) return path["res://".len..];
    }
    return null;
}

/// Strip a trailing `#` comment, respecting single/double-quoted strings.
/// Public: the lifecycle dispatch also strips comments before scanning for
/// preload()/load() imports, so commented-out code can't create dep edges.
pub fn stripGdComment(line: []const u8) []const u8 {
    var in_str: u8 = 0; // 0 = outside strings, else the active quote char
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str != 0) {
            if (ch == '\\') {
                i += 1; // skip escaped char
            } else if (ch == in_str) {
                in_str = 0;
            }
        } else if (ch == '"' or ch == '\'') {
            in_str = ch;
        } else if (ch == '#') {
            return std.mem.trimEnd(u8, line[0..i], " \t");
        }
    }
    return line;
}

fn countTripleQuotes(line: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 3 <= line.len) {
        if (std.mem.eql(u8, line[i .. i + 3], "\"\"\"") or
            std.mem.eql(u8, line[i .. i + 3], "'''"))
        {
            count += 1;
            i += 3;
        } else {
            i += 1;
        }
    }
    return count;
}

/// Leading whitespace count. Tabs and spaces each count as one — enough to
/// order nesting levels within one file; mixed indentation degrades but
/// never crashes.
fn leadingIndent(raw_line: []const u8) usize {
    var i: usize = 0;
    while (i < raw_line.len and (raw_line[i] == ' ' or raw_line[i] == '\t')) i += 1;
    return i;
}

/// Skip leading @annotations (with optional (args)); returns the rest, trimmed.
fn skipAnnotations(line: []const u8) []const u8 {
    var rest = line;
    while (rest.len > 0 and rest[0] == '@') {
        var i: usize = 1;
        while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '_')) i += 1;
        if (i < rest.len and rest[i] == '(') {
            var depth: usize = 0;
            while (i < rest.len) : (i += 1) {
                if (rest[i] == '(') depth += 1;
                if (rest[i] == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
        }
        rest = std.mem.trimStart(u8, rest[i..], " \t");
    }
    return rest;
}

/// "@export_range(0, 10) ..." -> "@export_range"
fn firstAnnotationName(line: []const u8) []const u8 {
    var i: usize = 1;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
    return line[0..i];
}

fn extractIdent(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return null;
    var i: usize = 1;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    return text[0..i];
}

/// Strip Godot resource-path prefixes: leading autoload '*' and res://.
fn stripResPrefix(path: []const u8) []const u8 {
    var p = path;
    if (p.len > 0 and p[0] == '*') p = p[1..];
    if (std.mem.startsWith(u8, p, "res://")) return p["res://".len..];
    return p;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (all godot gdscript tests green).

- [ ] **Step 5: Commit**

```bash
git add src/godot_parser.zig src/tests/parsers/godot.zig src/tests.zig
git commit -m "feat: GDScript line parser (funcs, signals, vars, annotations, preload imports)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: godot_parser.zig — scene, resource, and project.godot parsing

**Files:**
- Modify: `src/godot_parser.zig` (append functions)
- Modify: `src/tests/parsers/godot.zig` (append tests)

**Interfaces:**
- Produces (consumed by Task 5's dispatch):
  - `pub fn parseSceneLine(trimmed: []const u8) ParsedLine` — for `.godot_scene` and `.godot_resource`
  - `pub fn parseProjectLine(trimmed: []const u8, section: *ProjectSection) ParsedLine` — for `.godot_project`
  - `pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8` — structured detail for `node_def`/`connection`, `""` otherwise (callers fall back to the trimmed line)

- [ ] **Step 1: Write the failing tests**

Append to `src/tests/parsers/godot.zig`:

```zig
test "scene: ext_resource becomes a project-relative import" {
    const r = gp.parseSceneLine("[ext_resource type=\"Script\" path=\"res://TowerManager.gd\" id=\"ext_12\"]");
    try testing.expectEqualStrings("TowerManager.gd", r.import.path);
}

test "scene: node with type and parent" {
    const r = gp.parseSceneLine("[node name=\"Main\" type=\"Node2D\" id=\"1\"]");
    try testing.expectEqualStrings("Main", r.symbol.name);
    try testing.expectEqual(gp.Kind.node_def, r.symbol.kind);

    var buf: [256]u8 = undefined;
    const detail = gp.extractDetail("[node name=\"HUD\" type=\"CanvasLayer\" parent=\"1\"]", .node_def, &buf);
    try testing.expectEqualStrings("type=CanvasLayer parent=1", detail);
}

test "scene: connection captures signal wiring" {
    const line = "[connection signal=\"pressed\" from=\"StartButton\" to=\".\" method=\"_on_start_pressed\"]";
    const r = gp.parseSceneLine(line);
    try testing.expectEqualStrings("pressed", r.symbol.name);
    try testing.expectEqual(gp.Kind.connection, r.symbol.kind);

    var buf: [256]u8 = undefined;
    const detail = gp.extractDetail(line, .connection, &buf);
    try testing.expectEqualStrings("from=StartButton to=. method=_on_start_pressed", detail);
}

test "scene: gd_resource script_class, sub_resource ignored" {
    const r = gp.parseSceneLine("[gd_resource type=\"Resource\" script_class=\"CardData\" format=3]");
    try testing.expectEqualStrings("CardData", r.symbol.name);
    try testing.expectEqual(gp.Kind.resource_def, r.symbol.kind);

    try testing.expect(gp.parseSceneLine("[sub_resource type=\"RectangleShape2D\" id=\"rect_1\"]") == .none);
    try testing.expect(gp.parseSceneLine("[gd_scene format=3]") == .none);
    try testing.expect(gp.parseSceneLine("position = Vector2(100, 200)") == .none);
}

test "scene: malformed lines degrade to none" {
    try testing.expect(gp.parseSceneLine("[node name=\"Unterminated") == .none);
    try testing.expect(gp.parseSceneLine("[ext_resource type=\"Script\"]") == .none); // no path
    try testing.expect(gp.parseSceneLine("[") == .none);
}

test "scene: escaped quote inside node name" {
    const r = gp.parseSceneLine("[node name=\"He said \\\"hi\\\"\" type=\"Label\"]");
    try testing.expectEqualStrings("He said \\\"hi\\\"", r.symbol.name);
}

test "scene: attribute name is matched on word boundary" {
    // "signal" must not match inside a hypothetical attr ending in ...signal
    const r = gp.parseSceneLine("[connection my_signal=\"nope\" signal=\"hit\" from=\"A\" to=\"B\" method=\"m\"]");
    try testing.expectEqualStrings("hit", r.symbol.name);
}

test "project.godot: autoloads become imports, input actions become symbols" {
    var section: gp.ProjectSection = .none;

    const hdr = gp.parseProjectLine("[autoload]", &section);
    try testing.expectEqualStrings("autoload", hdr.symbol.name);
    try testing.expectEqual(gp.Kind.section_header, hdr.symbol.kind);

    const al = gp.parseProjectLine("GameState=\"*res://GameState.gd\"", &section);
    try testing.expectEqualStrings("GameState.gd", al.import.path);

    _ = gp.parseProjectLine("[input]", &section);
    const act = gp.parseProjectLine("place_tower={", &section);
    try testing.expectEqualStrings("place_tower", act.symbol.name);
    try testing.expectEqual(gp.Kind.input_action, act.symbol.kind);

    // continuation lines inside the action block are not symbols
    try testing.expect(gp.parseProjectLine("\"deadzone\": 0.5,", &section) == .none);

    _ = gp.parseProjectLine("[application]", &section);
    try testing.expect(gp.parseProjectLine("config/name=\"Lunch Rush\"", &section) == .none);
}

test "project.godot: malformed section header degrades to none" {
    var section: gp.ProjectSection = .none;
    try testing.expect(gp.parseProjectLine("[unclosed", &section) == .none);
    try testing.expect(gp.parseProjectLine("[]", &section) == .none);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: compile error — `parseSceneLine` not defined.

- [ ] **Step 3: Write the implementation**

Append to `src/godot_parser.zig`:

```zig
// ── Scenes (.tscn) and resources (.tres) ───────────────────────────────────
// Godot's text formats are INI-like: [section key="value" ...] headers
// followed by key = value property lines. Only headers carry cross-file
// signal; property lines are ignored.

pub fn parseSceneLine(trimmed: []const u8) ParsedLine {
    if (trimmed.len == 0 or trimmed[0] != '[') return .none;
    if (std.mem.startsWith(u8, trimmed, "[ext_resource")) {
        const path = extractQuotedAttr(trimmed, "path") orelse return .none;
        return .{ .import = .{ .path = stripResPrefix(path) } };
    }
    if (std.mem.startsWith(u8, trimmed, "[node ")) {
        const name = extractQuotedAttr(trimmed, "name") orelse return .none;
        return .{ .symbol = .{ .name = name, .kind = .node_def } };
    }
    if (std.mem.startsWith(u8, trimmed, "[connection ")) {
        const sig = extractQuotedAttr(trimmed, "signal") orelse return .none;
        return .{ .symbol = .{ .name = sig, .kind = .connection } };
    }
    if (std.mem.startsWith(u8, trimmed, "[gd_resource")) {
        const cls = extractQuotedAttr(trimmed, "script_class") orelse return .none;
        return .{ .symbol = .{ .name = cls, .kind = .resource_def } };
    }
    return .none; // [gd_scene], [sub_resource], [resource], [editable ...]
}

// ── project.godot ──────────────────────────────────────────────────────────

pub fn parseProjectLine(trimmed: []const u8, section: *ProjectSection) ParsedLine {
    if (trimmed.len == 0) return .none;
    if (trimmed[0] == '[') {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return .none;
        const name = trimmed[1..end];
        if (name.len == 0) return .none;
        section.* = if (std.mem.eql(u8, name, "autoload"))
            .autoload
        else if (std.mem.eql(u8, name, "input"))
            .input
        else
            .other;
        return .{ .symbol = .{ .name = name, .kind = .section_header } };
    }
    switch (section.*) {
        .autoload => {
            // GameState="*res://GameState.gd" — the '*' marks an autoload node
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return .none;
            const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
            if (value.len < 2 or value[0] != '"') return .none;
            const inner = value[1..];
            const close = std.mem.indexOfScalar(u8, inner, '"') orelse return .none;
            return .{ .import = .{ .path = stripResPrefix(inner[0..close]) } };
        },
        .input => {
            // place_tower={ "deadzone": 0.5, ... } — only the key line matters
            const brace = std.mem.indexOf(u8, trimmed, "={") orelse return .none;
            const key = std.mem.trim(u8, trimmed[0..brace], " \t");
            const name = extractIdent(key) orelse return .none;
            if (name.len != key.len) return .none; // reject e.g. quoted keys
            return .{ .symbol = .{ .name = name, .kind = .input_action } };
        },
        .none, .other => return .none,
    }
}

// ── Detail extraction ──────────────────────────────────────────────────────

/// Structured detail for scene symbols. Returns "" for kinds whose detail is
/// just the source line (callers fall back to the trimmed line).
pub fn extractDetail(line: []const u8, kind: Kind, buf: []u8) []const u8 {
    switch (kind) {
        .node_def => {
            var len: usize = 0;
            len = appendAttrDetail(line, "type", "type=", buf, len);
            len = appendAttrDetail(line, "parent", if (len == 0) "parent=" else " parent=", buf, len);
            return buf[0..len];
        },
        .connection => {
            var len: usize = 0;
            len = appendAttrDetail(line, "from", "from=", buf, len);
            len = appendAttrDetail(line, "to", if (len == 0) "to=" else " to=", buf, len);
            len = appendAttrDetail(line, "method", if (len == 0) "method=" else " method=", buf, len);
            return buf[0..len];
        },
        else => return "",
    }
}

fn appendAttrDetail(line: []const u8, attr: []const u8, prefix: []const u8, buf: []u8, len_in: usize) usize {
    var len = len_in;
    const val = extractQuotedAttr(line, attr) orelse return len;
    if (len + prefix.len + val.len > buf.len) return len;
    @memcpy(buf[len .. len + prefix.len], prefix);
    len += prefix.len;
    @memcpy(buf[len .. len + val.len], val);
    len += val.len;
    return len;
}

/// Extract attr="value" from a section header, respecting escaped quotes and
/// requiring a word boundary before the attribute name (so `signal=` does not
/// match inside `my_signal=`). Returns null on missing or unterminated value.
fn extractQuotedAttr(line: []const u8, attr: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (attr.len + 2 > needle_buf.len) return null;
    @memcpy(needle_buf[0..attr.len], attr);
    needle_buf[attr.len] = '=';
    needle_buf[attr.len + 1] = '"';
    const needle = needle_buf[0 .. attr.len + 2];

    var search_from: usize = 0;
    const start = blk: while (std.mem.indexOfPos(u8, line, search_from, needle)) |pos| {
        if (pos == 0 or line[pos - 1] == ' ' or line[pos - 1] == '[') break :blk pos;
        search_from = pos + 1;
    } else return null;

    const vstart = start + needle.len;
    var i = vstart;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // skip escaped char
        } else if (line[i] == '"') {
            return line[vstart..i];
        }
    }
    return null; // unterminated value
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/godot_parser.zig src/tests/parsers/godot.zig
git commit -m "feat: Godot scene/resource/project.godot parsing (nodes, connections, autoloads)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Wire Godot languages into the outline dispatch

**Files:**
- Modify: `src/explore/lifecycle.zig` (imports ~line 17, state vars in `parseOutlineWithParser` ~line 382-404, dispatch chain end ~line 671-712)
- Test: `src/tests/parsers/godot.zig` (append end-to-end tests)

**Interfaces:**
- Consumes: everything Tasks 1, 3, 4 produced.
- Produces: `Explorer.indexFile("X.gd", src)` yields a `FileOutline` with `language == .gdscript`, symbols, and imports; likewise for `.tscn`/`.tres`/`project.godot`. This is what MCP outline/symbol/deps tools read.

- [ ] **Step 1: Write the failing end-to-end tests**

Append to `src/tests/parsers/godot.zig`:

```zig
const Explorer = @import("../../explore.zig").Explorer;
const explore = @import("../../explore.zig");
const SymbolKind = explore.SymbolKind;

fn findSymbol(outline: anytype, name: []const u8) ?explore.Symbol {
    for (outline.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym;
    }
    return null;
}

fn hasImport(outline: anytype, path: []const u8) bool {
    for (outline.imports.items) |imp| {
        if (std.mem.eql(u8, imp, path)) return true;
    }
    return false;
}

test "e2e: .gd file yields outline symbols and imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("TowerManager.gd",
        \\extends Node
        \\## TowerManager — autoload singleton.
        \\
        \\const TowerScene = preload("res://tower/Tower.tscn")
        \\
        \\@export var default_tower_scene: PackedScene
        \\var lane_count: int = 0
        \\
        \\signal tower_placed(tower: Node2D, lane_index: int)
        \\
        \\func place_tower(scene: PackedScene, lane_index: int) -> bool:
        \\	return true
        \\
        \\static func reset() -> void:
        \\	pass
    );

    const outline = explorer.outlines.get("TowerManager.gd").?;
    try testing.expectEqual(explore.Language.gdscript, outline.language);

    try testing.expectEqual(SymbolKind.function, findSymbol(outline, "place_tower").?.kind);
    try testing.expectEqual(SymbolKind.function, findSymbol(outline, "reset").?.kind);
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "tower_placed").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSymbol(outline, "default_tower_scene").?.kind);
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "TowerScene").?.kind);

    // signal detail carries the full signature (falls back to trimmed line)
    const sig = findSymbol(outline, "tower_placed").?;
    try testing.expect(std.mem.startsWith(u8, sig.detail.?, "signal tower_placed"));

    try testing.expect(hasImport(outline, "Node")); // extends
    try testing.expect(hasImport(outline, "tower/Tower.tscn")); // preload
}

test "e2e: .tscn yields node tree symbols and script/scene imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Main.tscn",
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://main.gd" id="ext_1"]
        \\[ext_resource type="PackedScene" path="res://HUD.tscn" id="ext_4"]
        \\
        \\[node name="Main" type="Node2D" id="1"]
        \\script = ExtResource("ext_1")
        \\
        \\[node name="TowerManager" type="Node" id="3" parent="1"]
        \\
        \\[connection signal="pressed" from="StartButton" to="." method="_on_start_pressed"]
    );

    const outline = explorer.outlines.get("Main.tscn").?;
    try testing.expectEqual(explore.Language.godot_scene, outline.language);

    try testing.expect(hasImport(outline, "main.gd"));
    try testing.expect(hasImport(outline, "HUD.tscn"));

    try testing.expectEqual(SymbolKind.class_def, findSymbol(outline, "Main").?.kind);
    const tm = findSymbol(outline, "TowerManager").?;
    try testing.expectEqualStrings("type=Node parent=1", tm.detail.?);

    const conn = findSymbol(outline, "pressed").?;
    try testing.expectEqual(SymbolKind.variable, conn.kind);
    try testing.expectEqualStrings("from=StartButton to=. method=_on_start_pressed", conn.detail.?);
}

test "e2e: project.godot yields autoload imports and input actions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("project.godot",
        \\config_version=5
        \\
        \\[application]
        \\config/name="Lunch Rush"
        \\
        \\[autoload]
        \\GameState="*res://GameState.gd"
        \\TowerManager="*res://TowerManager.gd"
        \\
        \\[input]
        \\place_tower={
        \\"deadzone": 0.5,
        \\"events": []
        \\}
    );

    const outline = explorer.outlines.get("project.godot").?;
    try testing.expectEqual(explore.Language.godot_project, outline.language);

    try testing.expect(hasImport(outline, "GameState.gd"));
    try testing.expect(hasImport(outline, "TowerManager.gd"));
    try testing.expectEqual(SymbolKind.constant, findSymbol(outline, "place_tower").?.kind);
    try testing.expectEqual(SymbolKind.type_alias, findSymbol(outline, "autoload").?.kind);
}

test "e2e: standalone annotation attaches as decorator to next symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var explorer = Explorer.init(arena.allocator());

    try explorer.indexFile("Net.gd",
        \\extends Node
        \\
        \\@rpc("any_peer")
        \\func fire_projectile(lane: int) -> void:
        \\	pass
    );

    const outline = explorer.outlines.get("Net.gd").?;
    const f = findSymbol(outline, "fire_projectile").?;
    try testing.expectEqual(@as(usize, 1), f.decorators.len);
    try testing.expectEqualStrings("@rpc", f.decorators[0]);
}
```

Note: if `Explorer`, `explore`, or `SymbolKind` are already imported at the top of the file from Task 3, don't redeclare — Task 3's header only imported `std`, `testing`, and `gp`, so add these three imports at file scope (top of file), not mid-file. Zig allows the declarations anywhere at file scope, but keep them at the top for readability.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — outlines exist but have `language == .gdscript` with zero symbols (detection works from Task 1, dispatch doesn't exist yet), so `findSymbol(...).?` panics with `attempt to use null value` or the expectEqual on kind fails.

- [ ] **Step 3: Write the dispatch**

In `src/explore/lifecycle.zig`:

3a. Add the import after `const ssrs_parser = ...` (line 17):

```zig
const godot_parser = @import("../godot_parser.zig");
```

3b. In `parseOutlineWithParser`, add state variables after `var razor_brace_depth: u32 = 0;` (~line 404):

```zig
    var gd_state: godot_parser.GdState = .{};
    var godot_project_section: godot_parser.ProjectSection = .none;
    var gd_pending_decorators: std.ArrayList([]const u8) = .empty;
    defer {
        clearDecoratorList(parser.allocator, &gd_pending_decorators);
        gd_pending_decorators.deinit(parser.allocator);
    }
```

3c. At the END of the language dispatch chain — after the closing brace of the `ssrs_*` branch and before the chain's final `}` — add three branches:

```zig
        } else if (outline.language == .gdscript) {
            // preload()/load() references become dependency edges even when
            // they appear on a declaration line (const X = preload(...)).
            // Comments are stripped first so commented-out code adds no edges.
            if (!gd_state.in_multiline_string) {
                if (godot_parser.extractResPath(godot_parser.stripGdComment(trimmed))) |res_path| {
                    try appendImportSymbol(parser.allocator, &outline, res_path, line_num, trimmed);
                }
            }
            const result = godot_parser.parseGdLine(line, trimmed, &gd_state);
            switch (result) {
                .none => {},
                .annotation => |ann| {
                    const copy = try parser.allocator.dupe(u8, ann.name);
                    errdefer parser.allocator.free(copy);
                    try gd_pending_decorators.append(parser.allocator, copy);
                },
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .class_name_decl, .inner_class => .class_def,
                        .function_def => .function,
                        .method_def => .method,
                        .signal_decl => .constant,
                        .variable_decl => .variable,
                        .constant_decl => .constant,
                        .enum_decl => .enum_def,
                        else => unreachable, // scene/project kinds never come from parseGdLine
                    };
                    const before_count = outline.symbols.items.len;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, trimmed);
                    if (gd_pending_decorators.items.len > 0) {
                        try attachDecoratorsToSymbols(parser.allocator, &outline, before_count, gd_pending_decorators.items);
                        clearDecoratorList(parser.allocator, &gd_pending_decorators);
                    }
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        } else if (outline.language == .godot_scene or outline.language == .godot_resource) {
            const result = godot_parser.parseSceneLine(trimmed);
            switch (result) {
                .none => {},
                .annotation => unreachable, // gdscript-only
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .node_def, .resource_def => .class_def,
                        .connection => .variable,
                        else => unreachable,
                    };
                    var detail_buf: [256]u8 = undefined;
                    const structured = godot_parser.extractDetail(trimmed, sym.kind, &detail_buf);
                    const detail = if (structured.len > 0) structured else trimmed;
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, detail);
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        } else if (outline.language == .godot_project) {
            const result = godot_parser.parseProjectLine(trimmed, &godot_project_section);
            switch (result) {
                .none => {},
                .annotation => unreachable, // gdscript-only
                .symbol => |sym| {
                    const sk: SymbolKind = switch (sym.kind) {
                        .section_header => .type_alias,
                        .input_action => .constant,
                        else => unreachable,
                    };
                    try appendOutlineSymbol(parser.allocator, &outline, sym.name, sk, line_num, trimmed);
                },
                .import => |imp| {
                    try appendImportSymbol(parser.allocator, &outline, imp.path, line_num, trimmed);
                },
            }
        }
```

Placement notes:
- The chain lives in the `while (lines.next()) |line|` loop; `trimmed` is the whitespace-trimmed line, `line` the raw one (needed for indent).
- Do NOT add the Godot languages to the C-style block-comment preamble list (~line 457-465) — GDScript uses `#` comments, handled inside the parser.
- `clearDecoratorList` and `attachDecoratorsToSymbols` are existing file-local helpers used by the C# path; reuse them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS, including all four e2e tests.

- [ ] **Step 5: Run the full unit suite once more and commit**

Run: `zig build test 2>&1 | tail -5` (full suite green — confirms no other language's parsing regressed)

```bash
git add src/explore/lifecycle.zig src/tests/parsers/godot.zig
git commit -m "feat: wire Godot languages into outline dispatch

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Pre-merge verification and real-world validation against lunch-rush

**Files:**
- No source changes expected (fix-forward if validation exposes bugs, with a test per fix).

**Interfaces:**
- Consumes: the built `zig-out/bin/codedb` with Tasks 1-5 merged.

- [ ] **Step 1: Build the binary**

Run: `zig build 2>&1 | tail -3`
Expected: clean build, `zig-out/bin/codedb` exists.

- [ ] **Step 2: Run the E2E MCP suite (CLAUDE.md pre-merge requirement)**

Run: `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project /mnt/storage/repos/codedb`
Expected: all three scenarios pass (issue-346 regression, normal mode, no-roots client).

- [ ] **Step 3: Validate GDScript outlines on the real project**

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush outline TowerManager.gd`
Expected: symbols listed include `place_tower` (function), `tower_placed` / `tower_removed` / `lane_cleared` (signal details visible), `default_tower_scene` (variable), and an import for `Node`.

- [ ] **Step 4: Validate scene parsing and search ranking**

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush outline Main.tscn`
Expected: node symbols (`Main`, `LaneManager`, `TowerManager`, `WaveManager`, `InputManager`, ...) with `type=`/`parent=` details, and 14 imports (`main.gd`, `lane/Lane.tscn`, ..., `InputManager.gd`).

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush search place_tower`
Expected: `.gd` file hits ranked as code (not below markdown files); no hits from `.uid` files.

- [ ] **Step 5: Validate the dependency direction agents care about**

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush find tower_placed`
Expected: the signal declaration in `TowerManager.gd` is found.

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush word TowerManager`
Expected: hits in `Main.tscn` (ext_resource) and `project.godot` (autoload) — confirming both edge sources are indexed. (If the `deps`-style inspection is exposed via a different subcommand in the CLI shell, use `zig-out/bin/codedb ~/repos/games/lunch-rush` interactively and run `outline`/`find` there; the snapshot in Step 6 is the authoritative check.)

- [ ] **Step 6: Snapshot inspection — imports resolved, noise gone**

Run: `zig-out/bin/codedb ~/repos/games/lunch-rush snapshot && python3 -c "
import json,sys
snap=json.load(open('$HOME/repos/games/lunch-rush/codedb.snapshot'))
files=snap.get('files',snap)
txt=json.dumps(snap)
assert '.gd.uid' not in txt, 'uid sidecars leaked into snapshot'
assert 'TowerManager.gd' in txt
print('snapshot OK')
"`
Expected: `snapshot OK`. (If the snapshot filename/shape differs, inspect `ls ~/repos/games/lunch-rush/codedb.snapshot*` and adapt the assertion — the two invariants are: no `.uid` entries, and `TowerManager.gd` present with symbols.)

- [ ] **Step 7: Benchmark guard (CLAUDE.md: >10% regression is merge-blocking)**

Run: `zig build bench 2>&1 | tail -20` (if a bench step exists in build.zig; otherwise `zig build -Doptimize=ReleaseFast && time zig-out/bin/codedb /mnt/storage/repos/codedb snapshot` twice, comparing against a `git stash`-ed baseline run if there's any doubt).
Expected: parse/index times within noise of main — the change adds only trailing else-if branches for previously-`unknown` languages.

- [ ] **Step 8: Final commit (only if fixes were needed) and wrap-up**

If validation exposed bugs: fix with a failing test first, then re-run Steps 1-7.

```bash
git status   # confirm clean tree, all work committed
```

Then use superpowers:finishing-a-development-branch to decide merge/PR.
