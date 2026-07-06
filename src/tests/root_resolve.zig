// Tests for src/root_resolve.zig — the canonical root-resolution funnel.
//
// Picked up by the test runner via tests.zig, which re-imports this file.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;
const root_resolve = @import("../root_resolve.zig");

// ── pathFromFileUri: pure URI parser (no I/O) ───────────────────────

test "uri: file:///a/b -> /a/b" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///a/b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a/b", out);
}

test "uri: file://localhost/a/b -> /a/b (localhost authority stripped)" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file://localhost/a/b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a/b", out);
}

test "uri: percent-decode %20 -> space" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///Users/a%20b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/Users/a b", out);
}

test "uri: percent-decode %2F -> slash" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///path/a%2Fb");
    defer testing.allocator.free(out);
    // The encoded slash becomes a literal slash — the caller (canonicalizeRoot)
    // is the one that resolves/realpaths, so we preserve it verbatim.
    try testing.expectEqualStrings("/path/a/b", out);
}

test "uri: trailing slash preserved by pathFromFileUri (canonicalizeRoot strips)" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///home/u/repos/app/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/home/u/repos/app/", out);
}

test "uri: Windows drive form file:///C:/Users/x -> C:/Users/x" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///C:/Users/x");
    defer testing.allocator.free(out);
    // Parser is target-independent; the leading slash before a drive letter is
    // dropped so internal paths stay forward-slash + drive-letter form.
    try testing.expectEqualStrings("C:/Users/x", out);
}

test "uri: Windows UNC file://server/share -> //server/share" {
    // On POSIX a non-localhost authority is InvalidUri; on Windows it becomes a
    // UNC path. The parser decision is made by builtin.os.tag, so on this Linux
    // box we assert the POSIX rejection. (A Windows CI run exercises the UNC arm.)
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "file://server/share"),
    );
}

test "uri: non-file scheme rejected" {
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "https://example.com/x"),
    );
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "http://example.com"),
    );
}

test "uri: file: with empty path rejected" {
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "file://"),
    );
}

test "uri: bare path (no scheme) passed through unchanged" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "/already/a/path");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/already/a/path", out);
}

test "uri: malformed percent escape %G1 rejected" {
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "file:///a/%G1"),
    );
}

test "uri: trailing percent rejected" {
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "file:///a/ab%"),
    );
}

test "uri: lone percent in middle rejected" {
    try testing.expectError(
        error.InvalidUri,
        root_resolve.pathFromFileUri(testing.allocator, "file:///a/b%/c"),
    );
}

test "uri: percent-decode lowercase hex %2f" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///a%2fb");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a/b", out);
}

test "uri: percent-decode upper+lower hex mix %2D (dash)" {
    const out = try root_resolve.pathFromFileUri(testing.allocator, "file:///a%2Db");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a-b", out);
}

// ── cacheKey + foldForKey: platform-aware hashing ───────────────────

test "foldForKey: ASCII uppercase folds to lowercase" {
    try testing.expectEqual(@as(u8, 'a'), root_resolve.foldForKey('A'));
    try testing.expectEqual(@as(u8, 'z'), root_resolve.foldForKey('Z'));
}

test "foldForKey: lowercase and non-alpha unchanged" {
    try testing.expectEqual(@as(u8, 'a'), root_resolve.foldForKey('a'));
    try testing.expectEqual(@as(u8, '/'), root_resolve.foldForKey('/'));
    try testing.expectEqual(@as(u8, '0'), root_resolve.foldForKey('0'));
    try testing.expectEqual(@as(u8, '_'), root_resolve.foldForKey('_'));
}

test "cacheKey: stable for identical input" {
    const a = root_resolve.cacheKey("/home/u/repos/app");
    const b = root_resolve.cacheKey("/home/u/repos/app");
    try testing.expectEqual(a, b);
}

test "cacheKey: different paths differ" {
    const a = root_resolve.cacheKey("/home/u/repos/app");
    const b = root_resolve.cacheKey("/home/u/repos/other");
    try testing.expect(a != b);
}

// On case-insensitive OSes (macOS/Windows) the same path in two casings must
// hash equal; on Linux they are distinct filesystem paths so they must differ.
// foldForKey is exercised unconditionally above so the fold logic is covered on
// every platform; here we just pin the Linux contract.
test "cacheKey: Linux contract — case-sensitive" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const lower = root_resolve.cacheKey("/home/u/repos/app");
    const upper = root_resolve.cacheKey("/Home/U/Repos/App");
    try testing.expect(lower != upper);
}

// ── canonicalizeRoot: the funnel (realpath + trim) ──────────────────

test "canonicalizeRoot: trailing slash stripped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPathFile(io, ".", &buf);
    const tmp_path = buf[0..tmp_len];

    // Build the path with a trailing slash and ask canonicalizeRoot to fold it.
    const with_slash = try std.fmt.allocPrint(testing.allocator, "{s}/", .{tmp_path});
    defer testing.allocator.free(with_slash);

    const canonical = try root_resolve.canonicalizeRoot(io, testing.allocator, with_slash);
    defer testing.allocator.free(canonical);
    try testing.expectEqualStrings(tmp_path, canonical);
}

test "canonicalizeRoot: realpath resolves symlinks and relative input" {
    // "." should resolve to the test runner cwd; canonicalizeRoot must return
    // an absolute, realpath'd string with no trailing separator.
    const canonical = try root_resolve.canonicalizeRoot(io, testing.allocator, ".");
    defer testing.allocator.free(canonical);
    try testing.expect(canonical.len > 0);
    try testing.expect(canonical[0] == '/');
    try testing.expect(canonical[canonical.len - 1] != '/');
}

test "canonicalizeRoot: file:// URI accepted and decoded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPathFile(io, ".", &buf);
    const tmp_path = buf[0..tmp_len];

    const uri = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{tmp_path});
    defer testing.allocator.free(uri);

    const canonical = try root_resolve.canonicalizeRoot(io, testing.allocator, uri);
    defer testing.allocator.free(canonical);
    try testing.expectEqualStrings(tmp_path, canonical);
}

test "canonicalizeRoot: root slash stays root slash" {
    // The one path whose trailing slash we must NOT strip. "/" is denied by
    // root_policy but canonicalizeRoot itself should leave it intact.
    const canonical = try root_resolve.canonicalizeRoot(io, testing.allocator, "/");
    defer testing.allocator.free(canonical);
    try testing.expectEqualStrings("/", canonical);
}
