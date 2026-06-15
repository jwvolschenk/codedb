const path_safety = @import("../path_safety.zig");

// Sensitive-path filter lives in path_safety.zig so the watcher, snapshot
// writer, and HTTP/MCP servers all share one reviewable implementation.
pub const isSensitivePath = path_safety.isSensitivePath;
