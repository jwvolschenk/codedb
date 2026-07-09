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
