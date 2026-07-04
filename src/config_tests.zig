// Tests for src/config.zig.
//
// Extracted from src/config.zig to keep the parser file focused on
// implementation. Tests are picked up by the test runner via
// `@import("tests.zig")` which re-imports this file.

const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const Config = config.Config;

test "config: defaults" {
    const cfg = Config.default;
    try testing.expectEqual(@as(usize, 100), cfg.max_versions);
    try testing.expectEqual(@as(u32, 1000), cfg.max_cached);
}

test "config: parse single key" {
    const cfg = try Config.parse("max_versions = 42\n");
    try testing.expectEqual(@as(usize, 42), cfg.max_versions);
    try testing.expectEqual(@as(u32, 1000), cfg.max_cached);
}

test "config: parse both keys with comments and whitespace" {
    const cfg = try Config.parse(
        \\# codedb config
        \\
        \\max_versions = 200
        \\  max_cached   =   2048
        \\# trailing comment
        \\
    );
    try testing.expectEqual(@as(usize, 200), cfg.max_versions);
    try testing.expectEqual(@as(u32, 2048), cfg.max_cached);
}

test "config: unknown keys are ignored" {
    const cfg = try Config.parse("unknown_key = 99\nmax_versions = 5\n");
    try testing.expectEqual(@as(usize, 5), cfg.max_versions);
}

test "config: malformed value rejected" {
    try testing.expectError(error.InvalidMaxVersions, Config.parse("max_versions = not_a_number\n"));
    try testing.expectError(error.InvalidMaxVersions, Config.parse("max_versions = 0\n"));
    try testing.expectError(error.InvalidMaxCached, Config.parse("max_cached = 0\n"));
}

test "config: rerank_trace defaults off and parses true/false" {
    const cfg_default = Config.default;
    try testing.expect(cfg_default.rerank_trace == false);

    const cfg_on = try Config.parse("rerank_trace = true\n");
    try testing.expect(cfg_on.rerank_trace == true);

    const cfg_off = try Config.parse("rerank_trace = false\n");
    try testing.expect(cfg_off.rerank_trace == false);

    try testing.expectError(error.InvalidRerankTrace, Config.parse("rerank_trace = maybe\n"));
}

test "config: index_generated_files defaults off and parses true/false" {
    try testing.expect(Config.default.index_generated_files == false);

    const cfg_on = try Config.parse("index_generated_files = true\n");
    try testing.expect(cfg_on.index_generated_files == true);

    const cfg_off = try Config.parse("index_generated_files = false\n");
    try testing.expect(cfg_off.index_generated_files == false);

    try testing.expectError(error.InvalidBool, Config.parse("index_generated_files = maybe\n"));
}

test "config: require_git_repo defaults on and parses true/false" {
    try testing.expect(Config.default.require_git_repo == true);

    const cfg_off = try Config.parse("require_git_repo = false\n");
    try testing.expect(cfg_off.require_git_repo == false);

    const cfg_on = try Config.parse("require_git_repo = true\n");
    try testing.expect(cfg_on.require_git_repo == true);

    try testing.expectError(error.InvalidBool, Config.parse("require_git_repo = maybe\n"));
}
