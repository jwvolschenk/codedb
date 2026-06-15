const std = @import("std");

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
    ".png",     ".jpg",  ".jpeg", ".gif",  ".bmp",   ".ico",   ".icns",  ".webp",
    ".svg",     ".ttf",  ".otf",  ".woff", ".woff2", ".eot",   ".zip",   ".tar",
    ".gz",      ".bz2",  ".xz",   ".7z",   ".rar",   ".pdf",   ".doc",   ".docx",
    ".xls",     ".xlsx", ".pptx", ".mp3",  ".mp4",   ".wav",   ".avi",   ".mov",
    ".flv",     ".ogg",  ".webm", ".exe",  ".dll",   ".so",    ".dylib", ".o",
    ".a",       ".lib",  ".wasm", ".pyc",  ".pyo",   ".class", ".db",    ".sqlite",
    ".sqlite3", ".lock", ".sum",
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
    return false;
}

// Sensitive-path filter lives in path_safety.zig (shared with snapshot writer
// and HTTP/MCP servers). Keep a re-export here so internal call sites and any
// external consumers of `watcher.isSensitivePath` keep resolving.
const path_safety_mod = @import("../path_safety.zig");
pub const isSensitivePath = path_safety_mod.isSensitivePath;
