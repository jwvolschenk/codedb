const std = @import("std");
const cio = @import("cio.zig");
const builtin = @import("builtin");
const sty = @import("style.zig");
const release_info = @import("release_info.zig");

const github_repo = "jwvolschenk/codedb";
const default_base_url = "https://codedb.codegraff.com";
const user_agent = "codedb-update";

const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

const VersionSource = enum {
    env,
    github,
    fallback,
};

const ResolvedVersion = struct {
    value: []u8,
    source: VersionSource,
};

pub fn run(io: std.Io, stdout: cio.File, s: sty.Style, allocator: std.mem.Allocator) void {
    const out = Out{ .file = stdout, .alloc = allocator };

    const resolved = resolveTargetVersion(allocator) catch |err| {
        out.p("{s}x{s} failed to resolve update target: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(resolved.value);

    const version_order = compareVersions(release_info.semver, resolved.value) catch |err| {
        out.p("{s}x{s} invalid release version: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };

    switch (version_order) {
        .eq => {
            out.p("codedb {s} is already up to date\n", .{release_info.semver});
            return;
        },
        .gt => {
            out.p("{s}x{s} refusing to replace codedb {s} with older release {s}\n", .{ s.red, s.reset, release_info.semver, resolved.value });
            std.process.exit(1);
        },
        .lt => {},
    }

    const asset_name = assetNameForTarget(builtin.os.tag, builtin.cpu.arch) orelse {
        out.p("{s}x{s} self-update is unsupported on this platform\n", .{ s.red, s.reset });
        std.process.exit(1);
    };

    out.p("updating codedb {s} -> {s}\n", .{ release_info.semver, resolved.value });
    out.p("  source: {s}\n", .{switch (resolved.source) {
        .env => "CODEDB_VERSION",
        .github => "github releases",
        .fallback => "codedb.codegraff.com/latest.json",
    }});
    out.p("  asset:  {s}\n", .{asset_name});

    const manifest = fetchChecksumsManifest(allocator, resolved.value) catch |err| {
        out.p("{s}x{s} failed to download checksums for v{s}: {s}\n", .{ s.red, s.reset, resolved.value, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(manifest);

    const expected_hash = checksumForBinary(manifest, asset_name) orelse {
        out.p("{s}x{s} release v{s} is missing a checksum for {s}\n", .{ s.red, s.reset, resolved.value, asset_name });
        std.process.exit(1);
    };

    const self_path = std.process.executablePathAlloc(io, allocator) catch |err| {
        out.p("{s}x{s} cannot locate current executable: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(self_path);

    downloadAndReplaceBinary(io, allocator, resolved.value, asset_name, self_path, expected_hash) catch |err| {
        out.p("{s}x{s} update failed: {s}\n", .{ s.red, s.reset, @errorName(err) });
        std.process.exit(1);
    };

    if (builtin.os.tag == .windows) {
        out.p("{s}v{s} update staged for codedb {s} (applies on next restart)\n", .{ s.green, s.reset, resolved.value });
    } else {
        out.p("{s}v{s} updated to codedb {s}\n", .{ s.green, s.reset, resolved.value });
    }
}

pub fn assetNameForTarget(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os_tag) {
        .macos => switch (arch) {
            .aarch64 => "codedb-aarch64-darwin",
            .x86_64 => "codedb-x86_64-darwin",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "codedb-aarch64-linux",
            .x86_64 => "codedb-x86_64-linux",
            else => null,
        },
        .windows => switch (arch) {
            .aarch64 => "codedb-aarch64-windows.exe",
            .x86_64 => "codedb-x86_64-windows.exe",
            else => null,
        },
        else => null,
    };
}

pub fn compareVersions(current: []const u8, target: []const u8) !std.math.Order {
    var current_it = std.mem.splitScalar(u8, trimVersionPrefix(current), '.');
    var target_it = std.mem.splitScalar(u8, trimVersionPrefix(target), '.');

    while (true) {
        const current_part = current_it.next();
        const target_part = target_it.next();

        if (current_part == null and target_part == null) return .eq;

        const current_num = if (current_part) |part| try parseVersionPart(part) else 0;
        const target_num = if (target_part) |part| try parseVersionPart(part) else 0;

        if (current_num < target_num) return .lt;
        if (current_num > target_num) return .gt;
    }
}

pub fn checksumForBinary(manifest: []const u8, binary_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const hash_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const hash = line[0..hash_end];
        var name = std.mem.trimStart(u8, line[hash_end..], " \t");
        if (name.len == 0) continue;
        if (name[0] == '*') name = name[1..];
        if (std.mem.eql(u8, name, binary_name)) return hash;
    }

    return null;
}

fn resolveTargetVersion(allocator: std.mem.Allocator) !ResolvedVersion {
    if (cio.posixGetenv("CODEDB_VERSION")) |value| {
        if (value.len != 0) {
            const dup = try allocator.dupe(u8, value);
            return .{ .value = dup, .source = .env };
        }
    }

    if (fetchLatestVersionFromGitHub(allocator) catch null) |value| {
        return .{ .value = value, .source = .github };
    }

    if (fetchLatestVersionFromFallback(allocator) catch null) |value| {
        return .{ .value = value, .source = .fallback };
    }

    return error.CouldNotResolveLatestVersion;
}

fn fetchLatestVersionFromGitHub(allocator: std.mem.Allocator) !?[]u8 {
    const response = fetchUrlToMemory(allocator, "https://api.github.com/repos/" ++ github_repo ++ "/releases/latest", 1 * 1024 * 1024) catch return null;
    defer allocator.free(response);
    return parseJsonStringField(allocator, response, "tag_name", true);
}

fn fetchLatestVersionFromFallback(allocator: std.mem.Allocator) !?[]u8 {
    const base_url = try getBaseUrl(allocator);
    defer if (base_url.owned) allocator.free(base_url.value);

    const url = try std.fmt.allocPrint(allocator, "{s}/latest.json", .{base_url.value});
    defer allocator.free(url);

    const response = fetchUrlToMemory(allocator, url, 256 * 1024) catch return null;
    defer allocator.free(response);
    return parseJsonStringField(allocator, response, "version", false);
}

fn fetchChecksumsManifest(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/checksums.sha256", .{ github_repo, version });
    defer allocator.free(url);
    return fetchUrlToMemory(allocator, url, 256 * 1024);
}

fn fetchUrlToMemory(allocator: std.mem.Allocator, url: []const u8, max_output_bytes: usize) ![]u8 {
    const result = try cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", "-A", user_agent, url },
        .max_output_bytes = max_output_bytes,
    });
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CurlFailed;
    }

    return result.stdout;
}

fn parseJsonStringField(allocator: std.mem.Allocator, json_text: []const u8, field_name: []const u8, trim_v_prefix: bool) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const field = parsed.value.object.get(field_name) orelse return null;
    if (field != .string) return null;

    const value = if (trim_v_prefix) trimVersionPrefix(field.string) else field.string;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn getBaseUrl(allocator: std.mem.Allocator) !struct { value: []const u8, owned: bool } {
    if (cio.posixGetenv("CODEDB_URL")) |value| {
        if (value.len != 0) {
            const dup = try allocator.dupe(u8, value);
            return .{ .value = dup, .owned = true };
        }
    }
    return .{ .value = default_base_url, .owned = false };
}

fn trimVersionPrefix(value: []const u8) []const u8 {
    return std.mem.trimStart(u8, value, "vV");
}

fn parseVersionPart(part: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, part, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;
    return std.fmt.parseInt(u64, trimmed, 10);
}

fn downloadAndReplaceBinary(io: std.Io, allocator: std.mem.Allocator, version: []const u8, asset_name: []const u8, dest_path: []const u8, expected_hash: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/{s}", .{ github_repo, version, asset_name });
    defer allocator.free(url);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ dest_path, cio.nanoTimestamp() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    try downloadToFile(allocator, url, tmp_path);

    const actual_hash = try sha256FileHex(io, allocator, tmp_path);
    defer allocator.free(actual_hash);
    if (!std.ascii.eqlIgnoreCase(actual_hash, expected_hash)) {
        return error.ChecksumMismatch;
    }

    {
        var tmp_file = try std.Io.Dir.openFileAbsolute(io, tmp_path, .{ .mode = .read_write });
        defer tmp_file.close(io);
        // setPermissions(fromMode) is POSIX-only; Windows executables don't
        // need an explicit +x bit.
        if (builtin.os.tag != .windows) {
            try tmp_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
        }
    }

    if (builtin.os.tag == .windows) {
        // Windows locks running executables. Stage the update as .pending;
        // applyPendingUpdate() swaps it in on next startup.
        const pending_path = try std.fmt.allocPrint(allocator, "{s}.pending", .{dest_path});
        defer allocator.free(pending_path);
        std.Io.Dir.deleteFileAbsolute(io, pending_path) catch {};
        try std.Io.Dir.renameAbsolute(tmp_path, pending_path, io);
    } else {
        // POSIX: atomic rename works even over a running binary.
        try std.Io.Dir.renameAbsolute(tmp_path, dest_path, io);
    }
}

/// Called very early on startup. Two jobs:
/// 1. Clean up stale .old / .tmp files from previous updates (best-effort).
/// 2. If a .pending file exists next to the running executable, swap it in.
pub fn applyPendingUpdate(io: std.Io, err_out: anytype) void {
    const self_path = std.process.executablePathAlloc(io, std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(self_path);

    const self_dir = std.fs.path.dirname(self_path) orelse return;

    // --- Job 1: best-effort cleanup of leftover update artifacts -----------
    cleanupStaleFiles(io, self_dir, self_path);

    // --- Job 2: apply a staged .pending update -----------------------------
    const pending_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}.pending", .{self_path}) catch return;
    defer std.heap.page_allocator.free(pending_path);

    // Check if .pending exists.
    std.Io.Dir.accessAbsolute(io, pending_path, .{}) catch return;

    const old_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}.old", .{self_path}) catch return;
    defer std.heap.page_allocator.free(old_path);

    std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
    std.Io.Dir.renameAbsolute(self_path, old_path, io) catch |err| {
        err_out.p("warning: staged update found but cannot rename running exe: {s}\n", .{@errorName(err)});
        err_out.p("  close all codedb instances and run again to apply\n", .{});
        return;
    };
    std.Io.Dir.renameAbsolute(pending_path, self_path, io) catch |err| {
        // Roll back: put the old binary back.
        std.Io.Dir.renameAbsolute(old_path, self_path, io) catch {};
        err_out.p("warning: staged update found but cannot apply: {s}\n", .{@errorName(err)});
        return;
    };
    // Swap succeeded. .old may still be locked by this process — it will be
    // cleaned up on a future startup by cleanupStaleFiles() once all old
    // processes have exited.
}

/// Remove leftover .old and .tmp.{timestamp} files from previous updates.
/// On Windows, .old may still be locked by a running process — the delete
/// silently fails and will succeed on a future run.
fn cleanupStaleFiles(io: std.Io, dir_path: []const u8, self_path: []const u8) void {
    const self_base = std.fs.path.basename(self_path);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = entry.name;
        // Clean up .old files matching our binary name.
        if (std.mem.endsWith(u8, name, ".old") and std.mem.startsWith(u8, name, self_base)) {
            const full = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
            defer std.heap.page_allocator.free(full);
            std.Io.Dir.deleteFileAbsolute(io, full) catch {};
        }
        // Clean up stale .tmp files from interrupted downloads.
        if (std.mem.startsWith(u8, name, self_base) and std.mem.indexOf(u8, name, ".tmp.") != null) {
            const full = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
            defer std.heap.page_allocator.free(full);
            std.Io.Dir.deleteFileAbsolute(io, full) catch {};
        }
    }
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    const result = try cio.runCapture(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", "-A", user_agent, url, "-o", dest_path },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.DownloadFailed;
    }
}

fn sha256FileHex(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const read_len = try file.readPositionalAll(io, &buf, offset);
        if (read_len == 0) break;
        hasher.update(buf[0..read_len]);
        offset += read_len;
        if (read_len < buf.len) break;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &digest_hex);
}

// ── Auto-update ──────────────────────────────────────────────────────────────
//
// On startup we kick off a detached check that shells out to the public
// install.sh. The check is:
//   • disabled when CODEDB_NO_AUTO_UPDATE is set in the environment
//   • throttled to at most once every 24 hours, tracked in
//     ~/.codedb/last_auto_update_check (a u64 little-endian unix-ms timestamp)
// The update itself runs in a background thread so it never blocks server
// startup. If the binary on disk gets replaced mid-session, the kernel keeps
// the old inode mapped for the running process; subsequent invocations get the
// new binary.

const auto_update_throttle_ms: i64 = 24 * 60 * 60 * 1000;
const auto_update_stamp_filename = "last_auto_update_check";

/// Pure decision function — useful for tests. Returns true when the next
/// auto-update attempt should fire.
pub fn shouldRunAutoUpdate(now_ms: i64, last_check_ms: ?i64, env_disabled: bool) bool {
    if (env_disabled) return false;
    const last = last_check_ms orelse return true;
    if (last > now_ms) return true;
    const delta: i128 = @as(i128, now_ms) - @as(i128, last);
    return delta >= auto_update_throttle_ms;
}

pub fn maybeAutoUpdate(io: std.Io, allocator: std.mem.Allocator) void {
    const env_disabled = cio.posixGetenv("CODEDB_NO_AUTO_UPDATE") != null;
    const home = cio.getHomeDir() orelse return;
    if (home.len == 0) return;

    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb", .{home}) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    const stamp_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, auto_update_stamp_filename }) catch return;
    defer allocator.free(stamp_path);

    const last_ms = readAutoUpdateStamp(io, stamp_path);
    const now_ms = cio.milliTimestamp();
    if (!shouldRunAutoUpdate(now_ms, last_ms, env_disabled)) return;

    // Persist the new timestamp before launching so concurrent invocations
    // don't all race the same check.
    writeAutoUpdateStamp(io, stamp_path, now_ms);

    const thread = std.Thread.spawn(.{}, autoUpdateWorker, .{}) catch return;
    thread.detach();
}

fn autoUpdateWorker() void {
    // Use the binary's own `update` command instead of curl-pipe-bash.
    // This reuses the checksum-verified self-update path and doesn't depend
    // on a hosted install script.
    const self_path: []const u8 = switch (builtin.os.tag) {
        .linux => "/proc/self/exe",
        .freebsd => "/proc/curproc/file",
        else => return,
    };

    const result = cio.runCapture(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ self_path, "update" },
        .max_output_bytes = 64 * 1024,
    }) catch return;
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
}

fn readAutoUpdateStamp(io: std.Io, path: []const u8) ?i64 {
    var buf: [8]u8 = undefined;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    if (n < 8) return null;
    return std.mem.readInt(i64, buf[0..8], .little);
}

fn writeAutoUpdateStamp(io: std.Io, path: []const u8, ms: i64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, ms, .little);
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer f.close(io);
    f.writePositionalAll(io, &buf, 0) catch {};
}
