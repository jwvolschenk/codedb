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
    if (path.len == 0 or path[0] != '/') return null;
    if (root.len == 0) return null;
    if (!root_policy.isExactOrChild(path, root)) return null;
    var rel = path[root.len..];
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
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
