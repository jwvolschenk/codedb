//! Per-project progress; independent atomics keep status available during scans.
const std = @import("std");
const cio = @import("cio.zig");
pub const Metrics = struct {
    started_ms: std.atomic.Value(i64) = .init(0),
    walk_finished_ms: std.atomic.Value(i64) = .init(0),
    finished_ms: std.atomic.Value(i64) = .init(0),
    last_progress_ms: std.atomic.Value(i64) = .init(0),
    scanned: std.atomic.Value(u64) = .init(0),
    parsed: std.atomic.Value(u64) = .init(0),
    oversized: std.atomic.Value(u64) = .init(0),
    peak_sampled_rss: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    verification_finished_ms: std.atomic.Value(i64) = .init(0),
    verification_pending: std.atomic.Value(u64) = .init(0),

    pub fn start(self: *Metrics) void {
        self.started_ms.store(cio.milliTimestamp(), .release);
        self.walk_finished_ms.store(0, .release);
        self.finished_ms.store(0, .release);
        self.scanned.store(0, .release);
        self.parsed.store(0, .release);
        self.oversized.store(0, .release);
        self.failed.store(false, .release);
        self.progress();
    }
    pub fn progress(self: *Metrics) void {
        self.last_progress_ms.store(cio.milliTimestamp(), .release);
    }
    pub fn sampleMemory(self: *Metrics) void {
        if (cio.processRssBytes()) |rss| _ = self.peak_sampled_rss.fetchMax(rss, .monotonic);
    }
    pub fn walked(self: *Metrics) void {
        const n = self.scanned.fetchAdd(1, .monotonic);
        self.progress();
        if (n % 256 == 0) self.sampleMemory();
    }
    pub fn committed(self: *Metrics) void {
        const n = self.parsed.fetchAdd(1, .monotonic);
        self.progress();
        if (n % 256 == 0) self.sampleMemory();
    }
    pub fn finish(self: *Metrics) void {
        self.finished_ms.store(cio.milliTimestamp(), .release);
        self.progress();
        self.sampleMemory();
    }
};
