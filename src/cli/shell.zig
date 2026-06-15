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
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "hot", "snapshot", "serve", "mcp", "update", "nuke" };
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
