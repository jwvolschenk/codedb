const std = @import("std");

/// User-tunable config loaded from .codedbrc files.
///
/// Resolution order (first match wins):
///   1. --config-file=<path>  (explicit)
///   2. $CWD/.codedbrc
///   3. <binary_dir>/.codedbrc
///
/// Format: one `key = value` per line. Blank lines and `#`-prefixed lines
/// are ignored. Unknown keys are silently ignored so upgrades don't break
/// older configs.
///
/// Addresses #101 (max_versions) and #102 (max_cached).
pub const Config = struct {
    /// Cap per-file version history in the Store. Default 100.
    max_versions: usize = 100,
    /// Cap on files kept in the Explorer's in-memory content cache. Default 1000.
    max_cached: u32 = 1000,
    /// When true, append one JSON line per searchContent invocation to
    /// <data_dir>/rerank-traces.jsonl. v0 logger for offline rerank-tuning
    /// experiments. Off by default — opt in via .codedbrc.
    rerank_trace: bool = false,
    /// When true, index generated code artifacts (EF migrations, *.Designer.cs,
    /// *.g.cs, *.generated.*). Default false — generated files pollute word/symbol
    /// indexes and rarely carry useful signal. Query-time `exclude_generated`
    /// still filters them from results regardless of this setting.
    index_generated_files: bool = false,
    /// When true, the MCP server auto-indexes CWD on startup when no
    /// explicit root is provided. Default false — the server stays idle until
    /// the agent explicitly calls codedb_index. Set to true in .codedbrc to
    /// restore legacy auto-index behavior.
    mcp_auto_index: bool = false,

    pub const default: Config = .{};

    /// Parse a config body. Errors only on malformed integer values for
    /// known keys; unknown keys are ignored.
    pub fn parse(body: []const u8) !Config {
        var cfg: Config = .{};
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            // Strip inline comments (# ...) from the value
            var val_raw = line[eq + 1 ..];
            if (std.mem.indexOfScalar(u8, val_raw, '#')) |comment_pos| {
                val_raw = val_raw[0..comment_pos];
            }
            const val = std.mem.trim(u8, val_raw, " \t");
            if (std.mem.eql(u8, key, "max_versions")) {
                cfg.max_versions = std.fmt.parseInt(usize, val, 10) catch return error.InvalidMaxVersions;
                if (cfg.max_versions == 0) return error.InvalidMaxVersions;
            } else if (std.mem.eql(u8, key, "max_cached")) {
                cfg.max_cached = std.fmt.parseInt(u32, val, 10) catch return error.InvalidMaxCached;
                if (cfg.max_cached == 0) return error.InvalidMaxCached;
            } else if (std.mem.eql(u8, key, "rerank_trace")) {
                cfg.rerank_trace = parseBool(val) catch return error.InvalidRerankTrace;
            } else if (std.mem.eql(u8, key, "index_generated_files")) {
                cfg.index_generated_files = parseBool(val) catch return error.InvalidBool;
            } else if (std.mem.eql(u8, key, "mcp_auto_index")) {
                cfg.mcp_auto_index = parseBool(val) catch return error.InvalidBool;
            }
        }
        return cfg;
    }

    /// Load a config from a specific path. Returns the default config if the
    /// file doesn't exist; propagates parse errors.
    pub fn loadFromPath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Config {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config.default,
            else => return err,
        };
        defer file.close(io);
        const size = try file.length(io);
        if (size > 64 * 1024) return error.ConfigTooLarge;
        const body = try alloc.alloc(u8, @intCast(size));
        defer alloc.free(body);
        const read = try file.readPositionalAll(io, body, 0);
        return try parse(body[0..read]);
    }

    /// Walk the resolution order and load the first config found.
    /// `explicit_path` is the value of --config-file (if passed, null otherwise).
    /// `binary_dir` is the absolute directory containing the running codedb binary.
    pub fn loadDefault(
        io: std.Io,
        alloc: std.mem.Allocator,
        explicit_path: ?[]const u8,
        binary_dir: ?[]const u8,
    ) !Config {
        if (explicit_path) |p| return try loadFromPath(io, alloc, p);

        // Step 2: $CWD/.codedbrc
        if (cwdConfigExists(io)) {
            return try loadFromPath(io, alloc, ".codedbrc");
        }

        // Step 3: <binary_dir>/.codedbrc
        if (binary_dir) |bd| {
            const path = try std.fmt.allocPrint(alloc, "{s}/.codedbrc", .{bd});
            defer alloc.free(path);
            return try loadFromPath(io, alloc, path);
        }

        return Config.default;
    }

    fn cwdConfigExists(io: std.Io) bool {
        const f = std.Io.Dir.cwd().openFile(io, ".codedbrc", .{}) catch return false;
        f.close(io);
        return true;
    }
};

fn parseBool(val: []const u8) !bool {
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) return true;
    if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) return false;
    return error.InvalidBool;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
