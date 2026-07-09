// Tests for src/watcher/skip_rules.zig — generated-code detection (#6).
//
// Wired into the test runner via the comptime import block in
// src/tests/misc.zig (same pattern as config_tests.zig).

const std = @import("std");
const testing = std.testing;
const skip_rules = @import("skip_rules.zig");

test "isGeneratedPath: WinForms / EF designer files" {
    try testing.expect(skip_rules.isGeneratedPath("src/Forms/MainForm.Designer.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Forms/mainform.designer.cs")); // case-insensitive
    try testing.expect(skip_rules.isGeneratedPath("App/Properties/Resources.Designer.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Forms/MainForm.Designer.vb"));
}

test "isGeneratedPath: source-generator / auto-generated markers" {
    try testing.expect(skip_rules.isGeneratedPath("obj/Debug/net8.0/App.g.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.g.vb"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.g.ts"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.generated.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.generated.vb"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.generated.ts"));
    try testing.expect(skip_rules.isGeneratedPath("src/Gen/Foo.generated.java"));
}

test "isGeneratedPath: EF Core Migrations directory" {
    try testing.expect(skip_rules.isGeneratedPath("src/Data/Migrations/20240101120000_InitialCreate.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Data/Migrations/20240101120000_InitialCreate.Designer.cs"));
    try testing.expect(skip_rules.isGeneratedPath("src/Data/Migrations/AddColumn.vb"));
    // Nested migration path still matched.
    try testing.expect(skip_rules.isGeneratedPath("backend/src/Project/Infrastructure/Migrations/Init.cs"));
}

test "isGeneratedPath: hand-written source NOT flagged" {
    try testing.expect(!skip_rules.isGeneratedPath("src/Controllers/ProbeController.cs"));
    try testing.expect(!skip_rules.isGeneratedPath("src/Program.cs"));
    try testing.expect(!skip_rules.isGeneratedPath("src/Services/ProbeRepository.cs"));
    try testing.expect(!skip_rules.isGeneratedPath("README.md"));
    try testing.expect(!skip_rules.isGeneratedPath("src/app.ts"));
    // Single-letter-named or tricky source that must not match the .g.* suffixes.
    try testing.expect(!skip_rules.isGeneratedPath("src/diag.cs"));
    try testing.expect(!skip_rules.isGeneratedPath("src/flag.cs"));
    try testing.expect(!skip_rules.isGeneratedPath("src/g.cs"));
    // A Migrations directory containing non-code isn't matched.
    try testing.expect(!skip_rules.isGeneratedPath("docs/Migrations/notes.md"));
    // Substring-without-segment must not match Migrations.
    try testing.expect(!skip_rules.isGeneratedPath("src/MyMigrationsHelper.cs"));
}

test "shouldSkipFile: skips generated code by default" {
    const prev = skip_rules.shouldIncludeGenerated();
    defer skip_rules.setIncludeGenerated(prev);
    skip_rules.setIncludeGenerated(false);

    try testing.expect(skip_rules.shouldSkipFile("src/Forms/MainForm.Designer.cs"));
    try testing.expect(skip_rules.shouldSkipFile("src/Data/Migrations/2024_Init.cs"));
    // Hand-written code is still indexed.
    try testing.expect(!skip_rules.shouldSkipFile("src/Controllers/HomeController.cs"));
    try testing.expect(!skip_rules.shouldSkipFile("src/Program.cs"));
}

test "shouldSkipFile: include_generated=true keeps generated source but still skips binaries" {
    const prev = skip_rules.shouldIncludeGenerated();
    defer skip_rules.setIncludeGenerated(prev);
    skip_rules.setIncludeGenerated(true);

    try testing.expect(!skip_rules.shouldSkipFile("src/Forms/MainForm.Designer.cs"));
    try testing.expect(!skip_rules.shouldSkipFile("src/Data/Migrations/2024_Init.cs"));
    // Binary/sensitive skips apply regardless of the generated flag.
    try testing.expect(skip_rules.shouldSkipFile("assets/logo.png"));
}

test "setIncludeGenerated / shouldIncludeGenerated round-trip" {
    const prev = skip_rules.shouldIncludeGenerated();
    defer skip_rules.setIncludeGenerated(prev);
    skip_rules.setIncludeGenerated(true);
    try testing.expect(skip_rules.shouldIncludeGenerated());
    skip_rules.setIncludeGenerated(false);
    try testing.expect(!skip_rules.shouldIncludeGenerated());
}

test "generatedSkipEvents increments only on generated paths" {
    const prev = skip_rules.shouldIncludeGenerated();
    defer skip_rules.setIncludeGenerated(prev);
    skip_rules.setIncludeGenerated(false);

    const before = skip_rules.generatedSkipEvents();
    _ = skip_rules.shouldSkipFile("src/Forms/MainForm.Designer.cs"); // generated → increments
    _ = skip_rules.shouldSkipFile("src/Program.cs"); // not generated → no change
    const after = skip_rules.generatedSkipEvents();
    try testing.expect(after > before);
}

test "godot: cache dirs and sidecar files are skipped" {
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
