const std = @import("std");

// ── Generated-code filtering ───────────────────────────────────────────────
// EF migrations, WinForms/EF designers, and source-generator outputs pollute
// the word/symbol indexes and rarely carry signal an agent wants. By default
// these are skipped at index time (see isGeneratedPath). The behaviour is
// toggleable process-wide via setIncludeGenerated (driven by the
// `index_generated_files` config key) so users who need them can opt back in.
var include_generated: std.atomic.Value(bool) = .{ .raw = false };

/// Cumulative count of files filtered as generated since process start.
/// Counts each skip event (a single file scanned twice counts twice) — use as
/// a "filter is active" health signal, not an exact file count.
var generated_skip_events: std.atomic.Value(u64) = .{ .raw = 0 };

pub fn setIncludeGenerated(v: bool) void {
    include_generated.store(v, .release);
}

pub fn shouldIncludeGenerated() bool {
    return include_generated.load(.acquire);
}

pub fn generatedSkipEvents() u64 {
    return generated_skip_events.load(.acquire);
}

/// Does `path` look like generated code? Path-based only — never reads file
/// contents — so it stays cheap enough for the hot walk/index path.
pub fn isGeneratedPath(path: []const u8) bool {
    // EF / EF Core migrations live under a Migrations/ directory by convention.
    if (containsPathSegment(path, "Migrations")) {
        if (endsWithIgnoreCase(path, ".cs") or endsWithIgnoreCase(path, ".vb")) return true;
    }
    // WinForms / EF / dataset designer files.
    if (endsWithIgnoreCase(path, ".designer.cs")) return true;
    if (endsWithIgnoreCase(path, ".designer.vb")) return true;
    // Source-generator and explicit auto-generated markers.
    if (endsWithIgnoreCase(path, ".g.cs")) return true;
    if (endsWithIgnoreCase(path, ".g.vb")) return true;
    if (endsWithIgnoreCase(path, ".g.ts")) return true;
    if (endsWithIgnoreCase(path, ".generated.cs")) return true;
    if (endsWithIgnoreCase(path, ".generated.vb")) return true;
    if (endsWithIgnoreCase(path, ".generated.ts")) return true;
    if (endsWithIgnoreCase(path, ".generated.java")) return true;
    return false;
}

fn containsPathSegment(path: []const u8, segment: []const u8) bool {
    var rest = path;
    while (true) {
        const sep = std.mem.indexOfScalar(u8, rest, '/');
        const seg = if (sep) |s| rest[0..s] else rest;
        if (eqlAsciiIgnoreCase(seg, segment)) return true;
        if (sep) |s| {
            rest = rest[s + 1 ..];
        } else break;
    }
    return false;
}

/// #635: max file size codedb will read + index (outline/symbol/word). Files up
/// to 64KB also get trigram coverage; 64KB..this cap get outline+word but skip
/// trigram (see effective_skip_trigram in incremental.zig/initial_scan.zig);
/// past this cap the file is skipped.
/// Was 512KB, which silently dropped 512KB-2MB source files entirely.
pub const max_indexed_file_bytes = 2 * 1024 * 1024;

pub const skip_dirs = [_][]const u8{
    ".git",
    ".claude",
    ".codedb",
    "node_modules",
    ".zig-cache",
    "zig-out",
    ".next",
    ".nuxt",
    ".svelte-kit",
    "dist",
    "build",
    ".build",
    ".output",
    "out",
    "__pycache__",
    ".venv",
    "venv",
    ".env",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "target", // rust, java/maven
    ".gradle",
    ".idea",
    ".vs",
    "vendor", // go, php
    "Pods", // cocoapods
    ".dart_tool",
    ".pub-cache",
    "coverage",
    ".nyc_output",
    ".turbo",
    ".parcel-cache",
    ".cache",
    ".tmp",
    ".temp",
    ".DS_Store",
    "bundle",
    ".bundle",
    ".swc",
    ".terraform",
    ".terragrunt-cache",
    ".serverless",
    "elm-stuff",
    ".stack-work",
    ".cabal-sandbox",
    ".cargo",
    "bower_components",
    ".godot", // godot 4 editor cache (imported assets, shader cache)
    ".import", // godot 3 import cache dir
};

pub fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return eqlAsciiIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// Simple glob match where * matches any sequence of characters.
/// Case-insensitive (ASCII). Does not treat / specially (matches name fragments only).
/// Handles: "*.ext", "name.*", "pre*post", "*mid*", etc.
pub fn matchSimpleGlob(name: []const u8, pattern: []const u8) bool {
    var ni: usize = 0;
    var pi: usize = 0;
    var star_ni: usize = 0;
    var star_pi: usize = std.math.maxInt(usize);

    while (ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (pi < pattern.len and std.ascii.toLower(pattern[pi]) == std.ascii.toLower(name[ni])) {
            ni += 1;
            pi += 1;
        } else if (star_pi != std.math.maxInt(usize)) {
            pi = star_pi + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

pub fn shouldSkip(path: []const u8) bool {
    var rest = path;
    while (true) {
        for (skip_dirs) |skip| {
            if (rest.len >= skip.len and
                std.mem.eql(u8, rest[0..skip.len], skip) and
                (rest.len == skip.len or rest[skip.len] == '/'))
                return true;
        }
        if (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
            rest = rest[sep + 1 ..];
        } else break;
    }
    return false;
}

pub fn shouldSkipDir(name: []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

const skip_extensions = [_][]const u8{
    ".png",     ".jpg",  ".jpeg", ".gif",  ".bmp",    ".ico",         ".icns",  ".webp",
    ".svg",     ".ttf",  ".otf",  ".woff", ".woff2",  ".eot",         ".zip",   ".tar",
    ".gz",      ".bz2",  ".xz",   ".7z",   ".rar",    ".pdf",         ".doc",   ".docx",
    ".xls",     ".xlsx", ".pptx", ".mp3",  ".mp4",    ".wav",         ".avi",   ".mov",
    ".flv",     ".ogg",  ".webm", ".exe",  ".dll",    ".so",          ".dylib", ".o",
    ".a",       ".lib",  ".wasm", ".pyc",  ".pyo",    ".class",       ".db",    ".sqlite",
    ".sqlite3", ".lock", ".sum",  ".uid",  ".import", ".translation",
};

/// Lockfile basenames — these are generated, binary-like, and pollute the word index.
const skip_lockfile_names = [_][]const u8{
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lockb",
    "Cargo.lock",
    "composer.lock",
    "Gemfile.lock",
    "poetry.lock",
    "mix.lock",
    "pubspec.lock",
    "Package.resolved",
};

pub fn shouldSkipFile(path: []const u8) bool {
    for (skip_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    for (skip_lockfile_names) |lock_name| {
        if (eqlAsciiIgnoreCase(basename, lock_name)) return true;
    }
    if (std.mem.endsWith(u8, path, ".DS_Store")) return true;
    if (isSensitivePath(path)) return true;
    if (!shouldIncludeGenerated() and isGeneratedPath(path)) {
        _ = generated_skip_events.fetchAdd(1, .monotonic);
        return true;
    }
    return false;
}

// Sensitive-path filter lives in path_safety.zig (shared with snapshot writer
// and HTTP/MCP servers). Keep a re-export here so internal call sites and any
// external consumers of `watcher.isSensitivePath` keep resolving.
const path_safety_mod = @import("../path_safety.zig");
pub const isSensitivePath = path_safety_mod.isSensitivePath;
