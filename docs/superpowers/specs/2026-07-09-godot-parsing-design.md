# Godot Project Parsing Support — Design

**Date:** 2026-07-09
**Status:** Approved
**Scope:** Full — GDScript symbols + scene/resource wiring + index hygiene

## Problem

codedb indexes Godot files (`.gd`, `.tscn`, `.tres`, `project.godot`) as plain
text only. They are classified as `Language.unknown`, which means:

1. **No symbol outlines** — `func`, `signal`, `class_name`, `@export var`,
   `extends` never become symbols; symbol search and file outlines return
   nothing for an entire Godot codebase.
2. **Actively deprioritized in content search** — `isDocLanguage()` treats
   `unknown` as prose, ranking GDScript below real code.
3. **No dependency graph** — `.tscn` `ext_resource` references, node script
   attachments, signal connections, and `project.godot` autoloads produce no
   import edges.
4. **Index noise** — `.uid` and `.import` sidecar files are indexed as
   content, and the `.godot/` cache directory is not in `skip_dirs`.

Reference project: `~/repos/games/lunch-rush` (Godot 4.4+; 55 `.gd`,
36 `.tscn`, 30 `.tres`, 55 `.uid` sidecars).

## Approach

Native line-based parsers following the existing codedb pattern: a dedicated
`src/godot_parser.zig` module (modeled on `tsql_parser.zig` /
`ssrs_parser.zig`) exposing a `ParsedLine` union, dispatched from
`src/explore/lifecycle.zig`. Zero new dependencies.

**Rejected alternatives:**
- *Tree-sitter GDScript grammar* — breaks the zero-dependency Zig
  architecture for one language.
- *Alias `.gd` to the Python parser* — misses `signal`, `@export`,
  `extends`, `class_name`, `preload()`, and does nothing for scenes.

## Design

### 1. Language detection (`src/explore/types.zig`)

Four new `Language` enum values, appended (enum is `enum(u8)`, kinds
serialize by `@tagName`, so appending is safe):

| Language | Extension / filename |
|---|---|
| `gdscript` | `.gd` |
| `godot_scene` | `.tscn` |
| `godot_resource` | `.tres` |
| `godot_project` | `project.godot` (match via `endsWith(".godot")` on the filename `project.godot`) |

All four are real code languages — they are **not** added to
`isDocLanguage()`, so they escape doc-tier search deprioritization
automatically.

`.gdshader` is explicitly deferred (none in the reference project; easy
follow-up).

### 2. GDScript parser (`src/godot_parser.zig`, new module)

Line-based extraction. **No `SymbolKind` enum changes** — Godot-specific
semantics go in the symbol `detail` field, avoiding snapshot-compat risk.

| Source construct | Symbol kind | Detail / notes |
|---|---|---|
| `class_name Foo` | `class_def` | |
| `class Inner:` (inner class) | `class_def` | |
| `func foo(a: int) -> T:` | `function`; `method` inside an inner class | params + return type captured into `param_types` / `return_type` |
| `static func foo():` | `function` | `static` noted in detail |
| `signal tower_placed(tower, lane)` | `constant` | detail = `signal tower_placed(tower, lane)` |
| `var x: T = v` | `variable` | |
| `const X = v` | `constant` | |
| `enum E { ... }` | `enum_def` | |
| `@export`, `@onready`, `@rpc`, `@tool`, etc. | decorators | attached via existing `Symbol.decorators` (same pattern as C# attribute collection in `lifecycle.zig`) |
| `extends Node` / `extends "res://base.gd"` | `import` | class-name extends recorded as import edge by name; path extends stripped of `res://` |
| `preload("res://x.tscn")` / `load("res://x.gd")` | `import` | `res://` prefix stripped → project-relative path so the dependency graph's exact-path reverse lookup resolves |

Indentation determines scope (tabs or spaces): top-level `func` = function,
`func` under an inner `class` = method.

**Malformed-input requirements** (per CLAUDE.md review guidelines):
- `#` inside string literals must not be treated as a comment
- unterminated `"""` / `'''` multiline strings must not corrupt subsequent
  parsing
- mixed tabs/spaces indentation must not crash scope tracking
- lines longer than detail buffers are truncated, never overflowed

### 3. Scene / resource / project parser (same module)

INI-style section-header driven. Applies to `godot_scene`,
`godot_resource`, and `godot_project`.

| Source construct | Output | Notes |
|---|---|---|
| `[ext_resource type="Script" path="res://x.gd" id=…]` | `import` | `res://` stripped. This powers "which scenes use `TowerManager.gd`?" |
| `[node name="Main" type="Node2D" parent=…]` | `class_def` symbol | name = node name; detail = `type=Node2D parent=…` → scene-tree outline |
| `[connection signal="pressed" from="Btn" to="." method="_on_pressed"]` | `variable` symbol | name = signal name; detail = full from/to/method wiring |
| `[sub_resource type=… id=…]` | ignored | internal-only, no cross-file signal |
| `project.godot` `[autoload]` entries (`Name="*res://X.gd"`) | `import` | autoload singletons become dependency-graph edges; leading `*` stripped |
| `project.godot` `[input]` action keys | `constant` symbols | input actions discoverable by symbol search |
| `project.godot` other section headers | `type_alias` symbols | lightweight config outline |

**Malformed-input requirements:**
- quotes inside quoted attribute values (escaped `\"`) must not break
  attribute extraction
- section headers spanning odd whitespace or missing closing `]` degrade to
  `.none`, never crash
- attribute order must not matter (`path` before or after `type`)

### 4. Dispatch (`src/explore/lifecycle.zig`)

New branches following the `tsql_parser` / `ssrs_parser` pattern: call
`godot_parser.parseGdLine` / `parseSceneLine` / `parseProjectLine` per
language, map the returned `ParsedLine` union to `appendOutlineSymbol` /
`appendImportSymbol`.

### 5. Index hygiene (`src/watcher/skip_rules.zig`)

- `skip_dirs` += `.godot` (Godot 4 cache), `.import` (Godot 3 cache dir)
- `skip_extensions` += `.uid`, `.import`, `.translation`

### 6. Testing

- **Unit tests** in `src/godot_parser.zig`: every construct in the tables
  above, plus the malformed-input cases.
- **Adversarial tests**: quotes in node names, `#` in strings, unterminated
  strings, malformed section headers (add to `adversarial_tests.zig` if
  that's where cross-parser cases live, else in-module).
- **Skip-rule tests** in `skip_rules_tests.zig`: `.uid` / `.import` /
  `.godot/` exclusion.
- **Pre-merge** (per CLAUDE.md): `zig build test` and
  `python3 scripts/e2e_mcp_test.py --binary zig-out/bin/codedb --project …`.
- **Real-world validation**: rescan `~/repos/games/lunch-rush`; verify
  `TowerManager.gd` outline shows funcs/signals/exports, `Main.tscn` shows
  node tree + 14 ext_resource import edges, reverse-deps for
  `TowerManager.gd` include `Main.tscn` and `project.godot` autoloads, and
  `.uid` files are absent from the index.

## Non-goals

- `.gdshader` parsing (deferred)
- C#-in-Godot specifics (`.cs` already parsed by the existing C# parser)
- Binary `.scn` / `.res` / imported-asset parsing
- New `SymbolKind` enum values

## Success criteria

An agent pointed at a Godot project via codedb MCP can: get symbol outlines
for `.gd` files (functions, signals, exported vars), trace which scenes
reference a script and vice versa, see autoload singletons as dependencies,
find signal connections, and no longer sees `.uid`/`.godot` noise — with no
regression in existing parser benchmarks (>10% threshold per CLAUDE.md).
