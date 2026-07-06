// Canonical root resolution — the single funnel every project root passes
// through before root_policy checks, cache-dir hashing, or snapshot writes.
//
// Two historical bugs this closes:
//   * The MCP `roots/list` path stripped `file://` with a bare `uri_raw[7..]`:
//     no percent-decoding, no `localhost`/UNC/Windows-drive handling, no symlink
//     resolution, trailing slashes preserved. The CLI path canonicalized via
//     realpath. So the same project reached two ways got two different cache
//     dirs (`~/.codedb/projects/<hex>/`) and indexes never reused.
//   * `getDataDir` hashed the raw root string, so any of the above divergences
//     produced a different hash. `cacheKey` is now the ONLY place a root string
//     is hashed, and it folds case on macOS/Windows (case-insensitive FSes).
//
// Everything here is allocation-explicit and (for pathFromFileUri) pure: no
// I/O, so the URI parser is unit-testable cross-platform without a filesystem.

const std = @import("std");

pub const UriError = error{ InvalidUri, OutOfMemory };

/// Pure, no I/O. Converts an MCP `file://` URI to a filesystem path.
///
/// - `file:///a/b`            -> `/a/b`
/// - `file://localhost/a/b`   -> `/a/b`    (localhost authority stripped)
/// - `file://server/share`    -> UNC: on Windows `//server/share`;
///                               on POSIX `error.InvalidUri`
/// - `file:///C:/x`           -> `C:/x`    (Windows drive form; leading slash
///                                          before a drive letter is dropped.
///                                          Forward slashes kept — codedb uses
///                                          '/' internally.)
/// - percent-decoding:        `%20` -> ' ', `%2F` -> '/', etc. (RFC 3986)
/// - non-`file:` scheme       -> `error.InvalidUri`
/// - `file:` without `//`     -> `error.InvalidUri` (malformed file URI)
/// - input without a scheme   -> returned duped unchanged (already a path)
///
/// Trailing separators are preserved here; stripping them is `canonicalizeRoot`'s
/// job, so callers can distinguish "URI decoding" from "path canonicalization".
pub fn pathFromFileUri(alloc: std.mem.Allocator, uri: []const u8) UriError![]u8 {
    // file: scheme — must be the `file://` form.
    if (std.mem.startsWith(u8, uri, "file:")) {
        if (!std.mem.startsWith(u8, uri, "file://")) return error.InvalidUri;
        return parseFileUri(alloc, uri);
    }
    // Any other `scheme://` URI is not a filesystem path.
    if (detectScheme(uri) != null) return error.InvalidUri;
    // Bare path — pass through verbatim (caller will realpath it).
    return alloc.dupe(u8, uri) catch return error.OutOfMemory;
}

/// THE funnel. `pathFromFileUri` (when URI-shaped) → realpath → strip trailing
/// path separators. Every root MUST pass through this before root_policy
/// checks, `getDataDir`, or snapshot writes — it is what makes the CLI and MCP
/// paths agree on the same canonical string (and thus the same cache dir).
pub fn canonicalizeRoot(io: std.Io, alloc: std.mem.Allocator, raw: []const u8) error{ ResolveFailed, InvalidUri, OutOfMemory }![]u8 {
    // Step 1: URI-decode if shaped like a file URI, else dupe. Either way we
    // own `path` and must free it.
    const path = pathFromFileUri(alloc, raw) catch |err| switch (err) {
        error.InvalidUri => return error.InvalidUri,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(path);

    // Step 2: resolve symlinks / relative components via realpath, using the
    // same primitive as `cli/shell.resolveRoot`.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, path, &buf) catch return error.ResolveFailed;
    const rp = buf[0..n];

    // Step 3: trim trailing path separators, but never below length 1 — "/"
    // stays "/" (it will be denied by root_policy, but canonicalizeRoot itself
    // must leave it intact rather than returning an empty string).
    var end = rp.len;
    while (end > 1 and (rp[end - 1] == '/' or rp[end - 1] == '\\')) end -= 1;
    return alloc.dupe(u8, rp[0..end]) catch return error.OutOfMemory;
}

/// Cache-dir / snapshot `root_hash` key. This is the ONLY place a root string
/// is ever hashed. On macOS/Windows (comptime `builtin.os.tag`) it hashes the
/// ASCII-lowercased canonical path, because those filesystems are
/// case-insensitive; on Linux it hashes exact bytes. Routing both the writer
/// (snapshot `root_hash`) and reader (cache-dir selection) through here is what
/// keeps them consistent cross-OS.
pub fn cacheKey(canonical_root: []const u8) u64 {
    switch (@import("builtin").os.tag) {
        .macos, .windows => {
            // Streaming hash so we can fold case byte-by-byte without allocating
            // a lowercased copy. Equivalent to Wyhash over the folded string.
            var h = std.hash.Wyhash.init(0);
            for (canonical_root) |b| {
                var folded = [_]u8{foldForKey(b)};
                h.update(&folded);
            }
            return h.final();
        },
        else => return std.hash.Wyhash.hash(0, canonical_root),
    }
}

/// ASCII case-fold a single byte for hashing purposes (A-Z -> a-z; all else
/// unchanged). Factored out so the fold logic is unit-testable on every
/// platform — only the `cacheKey` dispatch above is gated on `builtin.os.tag`.
pub fn foldForKey(byte: u8) u8 {
    if (byte >= 'A' and byte <= 'Z') return byte + 32;
    return byte;
}

// ── internals ───────────────────────────────────────────────────────

/// Detects a URI scheme: `^[a-zA-Z][a-zA-Z0-9+.-]*://`. Returns the length of
/// the scheme (the offset of the `:`) when present, else null. Used only to
/// reject non-`file:` schemes — the `file:` case is handled before this runs.
fn detectScheme(uri: []const u8) ?usize {
    if (uri.len == 0 or !isAlpha(uri[0])) return null;
    var i: usize = 1;
    while (i < uri.len and (isAlnum(uri[i]) or uri[i] == '+' or uri[i] == '-' or uri[i] == '.')) : (i += 1) {}
    // Must be followed by "://".
    if (i + 2 >= uri.len or uri[i] != ':' or uri[i + 1] != '/' or uri[i + 2] != '/') return null;
    return i;
}

fn parseFileUri(alloc: std.mem.Allocator, uri: []const u8) UriError![]u8 {
    // uri starts with "file://"; everything after the "//" is authority/path.
    const after = uri["file://".len..];

    // Authority is everything up to the first '/', path is the rest.
    const slash_idx = std.mem.indexOfScalar(u8, after, '/');
    const authority = if (slash_idx) |s| after[0..s] else after;
    const raw_path = if (slash_idx) |s| after[s..] else "";

    // Resolve the authority.
    const path_start: []const u8 = blk: {
        if (authority.len == 0) {
            // No authority (file:///path). Use raw_path as-is.
            break :blk raw_path;
        } else if (std.mem.eql(u8, authority, "localhost")) {
            // localhost is equivalent to no authority — strip it.
            break :blk raw_path;
        } else {
            // Non-localhost authority.
            switch (@import("builtin").os.tag) {
                .windows => {
                    // UNC path: //authority/path. Build it; percent-decoding is
                    // applied below to the combined string via a decode of the
                    // full reconstructed buffer.
                    // NOTE: untested on this Linux box; see plan risk note
                    // (Windows e2e needs a Windows CI runner).
                    const combined = std.fmt.allocPrint(alloc, "//{s}{s}", .{ authority, raw_path }) catch return error.OutOfMemory;
                    defer alloc.free(combined);
                    return percentDecode(alloc, combined);
                },
                else => return error.InvalidUri,
            }
        }
    };

    // An empty path after authority resolution is invalid (`file://` alone, or
    // `file://localhost` with nothing).
    if (path_start.len == 0) return error.InvalidUri;

    // Percent-decode the path.
    const decoded = try percentDecode(alloc, path_start);

    // Windows drive form: `/C:/...` -> `C:/...`. The leading slash before a
    // drive letter is an artifact of the URI `file:///C:` shape; drop it so
    // internal paths stay forward-slash + drive-letter form.
    if (decoded.len >= 3 and decoded[0] == '/' and isAlpha(decoded[1]) and decoded[2] == ':') {
        const trimmed = decoded[1..];
        const out = alloc.alloc(u8, trimmed.len) catch {
            alloc.free(decoded);
            return error.OutOfMemory;
        };
        @memcpy(out, trimmed);
        alloc.free(decoded);
        return out;
    }

    return decoded;
}

/// Two-pass percent-decoder (RFC 3986). Pass 1 validates and computes the
/// decoded length; pass 2 allocates exactly and writes. Avoids ArrayList and
/// realloc so the testing allocator sees a clean single allocation.
fn percentDecode(alloc: std.mem.Allocator, src: []const u8) UriError![]u8 {
    // Pass 1: validate + measure.
    var decoded_len: usize = 0;
    var r: usize = 0;
    while (r < src.len) {
        if (src[r] == '%') {
            // Need two hex digits.
            if (r + 2 >= src.len) return error.InvalidUri;
            _ = hexVal(src[r + 1]) orelse return error.InvalidUri;
            _ = hexVal(src[r + 2]) orelse return error.InvalidUri;
            decoded_len += 1;
            r += 3;
        } else {
            decoded_len += 1;
            r += 1;
        }
    }

    var out = alloc.alloc(u8, decoded_len) catch return error.OutOfMemory;
    errdefer alloc.free(out);

    // Pass 2: write (inputs already validated).
    var w: usize = 0;
    r = 0;
    while (r < src.len) {
        if (src[r] == '%') {
            const hi = hexVal(src[r + 1]).?;
            const lo = hexVal(src[r + 2]).?;
            out[w] = (hi << 4) | lo;
            w += 1;
            r += 3;
        } else {
            out[w] = src[r];
            w += 1;
            r += 1;
        }
    }
    return out;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}
