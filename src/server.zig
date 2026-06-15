// codedb HTTP server — ported to Zig 0.16 std.Io.net (issue #285).
//
// This restores the port server that upstream stubbed out in commit 56ea465
// (v0.2.578). The route set and JSON response shapes match the pre-0.16
// implementation byte-for-byte; only the transport layer (listen/accept/read/
// write/close) was rewritten against the new `std.Io.net` surface. MCP stdio
// remains the primary entry, but `codedb serve --port` is once again usable
// by external clients that speak HTTP/1.1.

const transport = @import("server/transport.zig");

pub const serve = transport.serve;
