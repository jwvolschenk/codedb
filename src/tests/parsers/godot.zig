// Tests for src/godot_parser.zig — GDScript, scene, resource, project.godot.
const std = @import("std");
const testing = std.testing;
const gp = @import("../../godot_parser.zig");
const Explorer = @import("../../explore.zig").Explorer;
const explore = @import("../../explore.zig");
const SymbolKind = explore.SymbolKind;

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

test "gdscript: static var is still a variable declaration" {
    var st: gp.GdState = .{};
    const r = parseGd("static var counter: int = 0", &st);
    try testing.expectEqualStrings("counter", r.symbol.name);
    try testing.expectEqual(gp.Kind.variable_decl, r.symbol.kind);
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
        \\    return true
        \\
        \\static func reset() -> void:
        \\    pass
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
        \\    pass
    );

    const outline = explorer.outlines.get("Net.gd").?;
    const f = findSymbol(outline, "fire_projectile").?;
    try testing.expectEqual(@as(usize, 1), f.decorators.len);
    try testing.expectEqualStrings("@rpc", f.decorators[0]);
}
