const std = @import("std");
const cio = @import("../cio.zig");
const sty = @import("../style.zig");

pub const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,

    pub fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

pub fn isCommand(arg: []const u8) bool {
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "hot", "snapshot", "serve", "mcp", "update", "nuke", "index" };
    for (commands) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

pub fn resolveRoot(io: std.Io, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const sub = if (std.mem.eql(u8, root, ".")) "." else root;
    const n = std.Io.Dir.cwd().realPathFile(io, sub, buf) catch return error.ResolveFailed;
    return buf[0..n];
}

/// Pure predicates over the parsed (cmd, root, root_is_explicit) triple — the
/// single source of truth for the MCP root-resolution gates (#639, mirroring
/// upstream 375997e9). Keeping them in one place prevents the two consumption
/// sites (CODEDB_ROOT fallback, deferred-scan handshake) from drifting.

/// `codedb mcp` with an implicit cwd root (root=="." and NOT passed explicitly)
/// — drives the deferred-scan handshake: the server stays lazy until the client
/// sends roots/list_changed (or the timeout fires), instead of eagerly indexing.
/// A bare `codedb mcp` and a `${workspaceFolder}`-normalized launch both match.
pub fn mcpRootIsImplicitCwd(cmd: []const u8, root: []const u8, root_is_explicit: bool) bool {
    return std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".") and !root_is_explicit;
}

/// `codedb mcp` with the cwd root (explicit OR implicit) — drives the CODEDB_ROOT
/// env fallback. Explicit `<path> mcp` (where path resolved to ".") also matches,
/// since the point is "no concrete project path was given".
pub fn mcpRootAcceptsEnvFallback(cmd: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".");
}

/// Resolve config from the (already-extracted) --config-file path, falling
/// back to $CWD/.codedbrc and then <binary_dir>/.codedbrc. Returns the
/// default Config if nothing is found. Addresses #101, #102.
pub fn printUsage(out: Out, s: sty.Style) void {
    out.p(
        \\
        \\{s}codedb{s}  code intelligence server
        \\
        \\  {s}usage:{s} codedb [root] <command> [args...]
        \\
        \\  {s}commands:{s}
        \\    {s}tree{s}                      show file tree with language and symbol counts
        \\    {s}outline{s} {s}<path>{s}         list all symbols in a file
        \\    {s}find{s}    {s}<name>{s}         find where a symbol is defined
        \\    {s}search{s}  {s}<query>{s}        full-text search (trigram, case-insensitive)
        \\    {s}word{s}    {s}<identifier>{s}   exact word lookup via inverted index
        \\
    , .{
        s.bold, s.reset,
        s.dim,  s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
    out.p(
        \\    {s}hot{s}                       recently modified files
        \\    {s}serve{s}                     HTTP daemon on :7719
        \\    {s}mcp{s}                       JSON-RPC/MCP server over stdio
        \\    {s}nuke{s}                      uninstall codedb, clear caches, and deregister integrations
        \\
    , .{
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
    });
    out.p(
        \\  {s}options:{s}
        \\    {s}--no-telemetry{s}             disable usage telemetry (off by default; set CODEDB_TELEMETRY=1 to opt in)
        \\    {s}--config-file <path>{s}       load config overrides from <path> (default: ./.codedbrc)
        \\
        \\  If root is omitted, uses current working directory.
        \\  Data stored in {s}~/.codedb/projects/<hash>/{s}
        \\
        \\
    , .{
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
}
