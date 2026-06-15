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

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    // Block null bytes (path truncation attack)
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // Block backslash separators so Windows-style `..\..\x` can't bypass the
    // forward-slash `..` check below.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// Returns true if a file path looks like it may contain secrets.
/// These files are excluded from indexing, search, and snapshots to
/// prevent accidental exposure.
///
/// Optimized: most source files have extensions like .zig, .ts, .py — none
/// start with '.' or the few letters that begin sensitive names. Skip the
/// full check for those common cases.
pub fn isSensitivePath(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    if (basename.len == 0) return false;
    const first = basename[0];
    // Only check sensitive names if basename starts with '.', 'c', 's', 'i'
    // (the first letters of `.env`, `credentials`, `secrets`, `id_rsa`).
    if (first != '.' and first != 'c' and first != 's' and first != 'i') {
        // Still need to check extensions and directory patterns.
        if (std.mem.endsWith(u8, basename, ".pem") or
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
        (basename.len == 4 or basename[4] == '.')) return true;
    // Exact matches
    const sensitive_names = [_][]const u8{
        ".env.local",       ".env.production",      ".env.development", ".env.staging",
        ".env.test",        ".dev.vars",            ".npmrc",           ".pypirc",
        ".netrc",           "credentials.json",     "service-account.json", "secrets.json",
        "secrets.yaml",     "secrets.yml",          "id_rsa",           "id_ed25519",
    };
    for (sensitive_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (std.mem.endsWith(u8, basename, ".pem") or
        std.mem.endsWith(u8, basename, ".key") or
        std.mem.endsWith(u8, basename, ".p12") or
        std.mem.endsWith(u8, basename, ".pfx") or
        std.mem.endsWith(u8, basename, ".jks")) return true;
    if (std.mem.indexOf(u8, path, ".ssh/") != null or
        std.mem.indexOf(u8, path, ".gnupg/") != null or
        std.mem.indexOf(u8, path, ".aws/") != null) return true;
    return false;
}
