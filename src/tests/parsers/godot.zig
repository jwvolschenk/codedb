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
