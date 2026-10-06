// Path safety primitives — shared across HTTP server, MCP server, watcher,
// and snapshot writer.
//
// Two distinct concerns:
//   isPathSafe      — rejects path-traversal / absolute paths / null bytes
//                     (security boundary for *user-supplied* paths).
//   isSensitivePath — skips files that may contain secrets (.env, *.pem,
//                     credentials.json, …) so they are never indexed,
//                     searched, or shipped in a snapshot.
//
// Centralising these in one file gives reviewers a single audit surface
// (see AGENTS.md security-sensitive areas).

const std = @import("std");
const root_policy = @import("root_policy.zig");

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    // Drive-qualified, drive-relative, and NTFS alternate-data-stream paths
    // are never relative project keys, even on a non-Windows host.
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    // Block null bytes (path truncation attack)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // Block backslash separators so Windows-style `..\..\x` can't bypass the
    // forward-slash `..` check below.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
        if (@import("builtin").os.tag == .windows and component.len > 0) {
            if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return false;
            const stem = component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len];
            for ([_][]const u8{ "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" }) |device| {
                if (std.ascii.eqlIgnoreCase(stem, device)) return false;
            }
        }
    }
    return true;
}

/// Map a read/edit `path` argument to a project-relative path that is safe to
/// resolve, given the project's absolute `root`. A safe relative path passes
/// through unchanged; an absolute path is accepted only when it lives inside
/// `root` and is rewritten to its relative form. Everything else (out-of-root
/// absolutes, `..` traversal, null bytes, backslashes) returns null.
///
/// Without this, isPathSafe rejects every absolute path as traversal, so agents
/// that pass absolute paths get "path traversal not allowed" and abandon codedb
/// for bash (issue #629).
pub fn projectRelPath(path: []const u8, root: []const u8) ?[]const u8 {
    // Already a safe relative path — pass through.
    if (isPathSafe(path)) return path;
    // Only absolute paths get the in-root rescue; anything else stays rejected.
    if (path.len == 0) return null;
    const windows_absolute = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    if (!windows_absolute and path[0] != '/') return null;
    if (path.len >= 2 and path[0] == '/' and path[1] == '/') return null;
    if (root.len == 0) return null;
    // "/" is never a legitimate project root (root_policy rejects it for
    // indexing) — and accepting it would let `//etc/passwd` pass the child
    // check via its doubled slash.
    if (std.mem.eql(u8, root, "/")) return null;
    if (windows_absolute) {
        if (root.len <= 3 or path.len <= root.len) return null;
        for (root, path[0..root.len]) |a, b| {
            const aa = if (a == '\\') '/' else std.ascii.toLower(a);
            const bb = if (b == '\\') '/' else std.ascii.toLower(b);
            if (aa != bb) return null;
        }
        if (path[root.len] != '/' and path[root.len] != '\\') return null;
    } else if (!root_policy.isExactOrChild(path, root)) return null;
    var rel = path[root.len..];
    while (rel.len > 0 and (rel[0] == '/' or (windows_absolute and rel[0] == '\\'))) rel = rel[1..];
    if (rel.len == 0) return null; // the root directory itself, not a file
    // Re-validate the stripped remainder (blocks `/root/../escape`, nulls, etc).
    if (!isPathSafe(rel)) return null;
    return rel;
}

/// Returns true if a file path looks like it may contain secrets.
/// These files are excluded from indexing, search, and snapshots to
/// prevent accidental exposure.
///
/// Optimized: most source files have extensions like .zig, .ts, .py — none
/// start with '.' or the few letters that begin sensitive names. Skip the
/// full check for those common cases.
pub fn isSensitivePath(path: []const u8) bool {
    // Fold once into a bounded stack buffer, including directory separators.
    // Reject overlong names conservatively instead of truncating the policy key.
    var normalized: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len > normalized.len) return true;
    for (path, normalized[0..path.len]) |ch, *out| out.* = if (ch == '\\') '/' else std.ascii.toLower(ch);
    return isSensitiveNormalized(normalized[0..path.len]);
}

fn isSensitiveNormalized(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    if (basename.len == 0) return false;
    const first = basename[0];
    // Only check sensitive names if basename starts with '.', 'c', 's', 'i'
    // (the first letters of `.env`, `credentials`, `secrets`, `id_rsa`).
    if (first != '.' and first != 'c' and first != 's' and first != 'i') {
        // Still need to check extensions and directory patterns.
        if (std.mem.endsWith(u8, basename, ".env") or
            std.mem.endsWith(u8, basename, ".pem") or
            std.mem.endsWith(u8, basename, ".key") or
            std.mem.endsWith(u8, basename, ".p12") or
            std.mem.endsWith(u8, basename, ".pfx") or
            std.mem.endsWith(u8, basename, ".jks")) return true;
        if (std.mem.indexOf(u8, path, ".ssh/") != null or
            std.mem.indexOf(u8, path, ".gnupg/") != null or
            std.mem.indexOf(u8, path, ".aws/") != null) return true;
        return false;
    }
    // .env, .env.<token>; do NOT match .envoy, .envrc, .environment, etc.
    if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env") and
        (basename.len == 4 or basename[4] == '.' or basename[4] == '-' or basename[4] == '_')) return true;
    // Exact matches
    const sensitive_names = [_][]const u8{
        ".env.local",       ".env.production",      ".env.development", ".env.staging",
        ".env.test",        ".dev.vars",            ".npmrc",           ".pypirc",
        ".netrc",           "credentials.json",     "service-account.json", "secrets.json",
        "secrets.yaml",     "secrets.yml",          "id_rsa",           "id_ed25519",
        ".git-credentials", "id_ecdsa",             "id_dsa",           "id_ecdsa_sk",
        "id_ed25519_sk",
    };
    for (sensitive_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (std.mem.endsWith(u8, basename, ".env") or
        std.mem.endsWith(u8, basename, ".pem") or
        std.mem.endsWith(u8, basename, ".key") or
        std.mem.endsWith(u8, basename, ".p12") or
        std.mem.endsWith(u8, basename, ".pfx") or
        std.mem.endsWith(u8, basename, ".jks")) return true;
    if (std.mem.indexOf(u8, path, ".ssh/") != null or
        std.mem.indexOf(u8, path, ".gnupg/") != null or
        std.mem.indexOf(u8, path, ".aws/") != null) return true;
    return false;
}

/// Public file arguments may use native Windows separators; stored index keys
/// always use '/'. Keep the borrowed-slice helper strict for existing callers.
pub fn normalizedProjectPath(allocator: std.mem.Allocator, path: []const u8, root: []const u8) !?[]u8 {
    const normalized = try allocator.dupe(u8, path);
    defer allocator.free(normalized);
    if (@import("builtin").os.tag == .windows) {
        for (normalized) |*ch| if (ch.* == '\\') { ch.* = '/'; };
    }
    const rel = projectRelPath(normalized, root) orelse return null;
    return try allocator.dupe(u8, rel);
}

test "security: Windows drive and stream paths are never relative keys" {
    for ([_][]const u8{ "C:/outside.txt", "c:outside.txt", "file.txt:secret", "//host/share/x", "\\\\?\\C:\\x", "../x" }) |path| {
        try std.testing.expect(!isPathSafe(path));
    }
    try std.testing.expect(projectRelPath("C:/outside.txt", "C:/project") == null);
    try std.testing.expectEqualStrings("source file.zig", projectRelPath("c:/PROJECT/source file.zig", "C:/project").?);
}

test "security: secret names and directory separators are case insensitive" {
    for ([_][]const u8{ ".ENV", "upper/.ENV.local", "private.PEM", "private.KEY", "Credentials.JSON", "a\\.AWS\\config", "a/.SSH/config" }) |path| {
        try std.testing.expect(isSensitivePath(path));
    }
    try std.testing.expect(!isSensitivePath("src/environment.zig"));
}
