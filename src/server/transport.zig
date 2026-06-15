// codedb HTTP server — ported to Zig 0.16 std.Io.net (issue #285).
//
// This restores the port server that upstream stubbed out in commit 56ea465
// (v0.2.578). The route set and JSON response shapes match the pre-0.16
// implementation byte-for-byte; only the transport layer (listen/accept/read/
// write/close) was rewritten against the new `std.Io.net` surface. MCP stdio
// remains the primary entry, but `codedb serve --port` is once again usable
// by external clients that speak HTTP/1.1.

const std = @import("std");
const Store = @import("../store.zig").Store;
const AgentRegistry = @import("../agent.zig").AgentRegistry;
const Explorer = @import("../explore.zig").Explorer;
const watcher = @import("../watcher.zig");
const routes = @import("routes.zig");

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    queue: *watcher.EventQueue,
    port: u16,
) !void {
    _ = queue;

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var srv = try addr.listen(io, .{
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    });
    defer srv.deinit(io);

    while (true) {
        const stream = srv.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return err,
        };
        const ctx = allocator.create(HandlerCtx) catch {
            stream.close(io);
            continue;
        };
        ctx.* = .{
            .io = io,
            .allocator = allocator,
            .store = store,
            .agents = agents,
            .explorer = explorer,
            .stream = stream,
        };
        const t = std.Thread.spawn(.{}, handleThread, .{ctx}) catch {
            stream.close(io);
            allocator.destroy(ctx);
            continue;
        };
        t.detach();
    }
}

const HandlerCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    agents: *AgentRegistry,
    explorer: *Explorer,
    stream: std.Io.net.Stream,
};

fn handleThread(ctx: *HandlerCtx) void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    defer {
        ctx.stream.close(io);
        allocator.destroy(ctx);
    }
    routes.handleConnection(io, allocator, ctx.store, ctx.agents, ctx.explorer, ctx.stream);
}

/// Thin wrapper that owns a TCP stream plus a matching `std.Io.Writer` with a
/// small drain buffer. The response helpers below call `writeAll` followed by
/// `flush`, and the buffer is only used so the Io.Writer interface has a place
/// to stage bytes before the vectored drain hits the socket.
pub const Conn = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    writer: std.Io.net.Stream.Writer,

    fn init(io: std.Io, stream: std.Io.net.Stream, buf: []u8) Conn {
        return .{
            .io = io,
            .stream = stream,
            .writer = stream.writer(io, buf),
        };
    }

    /// Best-effort flush+write of `bytes`. Silently drops errors — the remote
    /// may have closed; we just want to finish the handler cleanly in that
    /// case so the caller's `defer stream.close(io)` runs.
    fn writeAll(self: *Conn, bytes: []const u8) void {
        self.writer.interface.writeAll(bytes) catch {};
    }

    fn flush(self: *Conn) void {
        self.writer.interface.flush() catch {};
    }
};
// -- Transport helpers -------------------------------------------------------

pub fn readSome(io: std.Io, stream: std.Io.net.Stream, dest: []u8) !usize {
    if (dest.len == 0) return 0;
    var iov: [1][]u8 = .{dest};
    const n = try io.vtable.netRead(io.userdata, stream.socket.handle, &iov);
    return n;
}

// ── Response helpers ────────────────────────────────────────────

// -- Response helpers --------------------------------------------------------

pub fn respondJson(conn: *Conn, status: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    conn.writeAll(hdr);
    conn.writeAll(body);
    conn.flush();
}

// ── HTTP parsing helpers ────────────────────────────────────────
