// Indexing memory budget (#591 Task 8).
//
// A last-resort backstop: even with root canonicalization and the git-repo
// gate, an agent can still point codedb_index at a huge tree (mono-repo, or
// simply the wrong folder). Nothing else bounds TOTAL memory — the per-file
// 2MB cap and the 15k trigram-file cap are per-item guards. This module
// bounds the blast radius: over budget → stop the walk, KEEP the partial
// index, surface `budget_exceeded` in status/tool responses.
//
// The metric is process RSS (cio.processRssBytes) — the honest "don't kill
// the host" number. It overcounts reclaimable mmap'd index pages; acceptable
// for a safety backstop. Deliberately NOT telemetry's approxIndexSizeBytes:
// that walks every index entry (O(index)) and would regress scan time.
//
// `max_index_memory_mb = 0` disables the budget entirely.

const std = @import("std");
const cio = @import("../cio.zig");

/// Check cadence in files: bulk-index loops call shouldStopIndexing() every
/// CHECK_INTERVAL files, so the probe cost (one small read) is amortized.
pub const CHECK_INTERVAL: usize = 256;

pub const BudgetCheck = struct { over: bool, rss_bytes: u64 };

var limit_mb_atomic: std.atomic.Value(u32) = std.atomic.Value(u32).init(6144);
var exceeded_atomic: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var probe_unavailable_logged: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Set at startup from config/env (commands/mod.zig). 0 = unlimited.
pub fn setLimitMb(v: u32) void {
    limit_mb_atomic.store(v, .release);
}

pub fn limitMb() u32 {
    return limit_mb_atomic.load(.acquire);
}

/// Sticky flag: some bulk scan stopped early because the budget was hit.
/// Cleared only by a fresh scan start (clearExceeded).
pub fn exceeded() bool {
    return exceeded_atomic.load(.acquire);
}

pub fn clearExceeded() void {
    exceeded_atomic.store(false, .release);
}

/// Cheap point check against an explicit limit. limit_mb == 0 → never over.
/// RSS probe unavailable (unsupported platform) → never over, logged once.
pub fn checkMemoryBudget(limit_mb: u32) BudgetCheck {
    if (limit_mb == 0) return .{ .over = false, .rss_bytes = 0 };
    const rss = cio.processRssBytes() orelse {
        if (!probe_unavailable_logged.swap(true, .acq_rel)) {
            std.log.warn("codedb: RSS probe unavailable on this platform — memory budget disabled", .{});
        }
        return .{ .over = false, .rss_bytes = 0 };
    };
    return .{ .over = rss > @as(u64, limit_mb) * 1024 * 1024, .rss_bytes = rss };
}

/// The call bulk-index loops make every CHECK_INTERVAL files: checks against
/// the global limit and, when over, marks the sticky exceeded flag and logs
/// the override hint. Returns true when the loop should stop walking.
pub fn shouldStopIndexing() bool {
    const check = checkMemoryBudget(limitMb());
    if (!check.over) return false;
    // Silent in test builds: the zig build runner's listen-mode protocol is
    // disturbed by stderr log writes mid-run (first pass "fails", then the
    // retry passes) — and tests assert the flag, not the log line.
    if (!exceeded_atomic.swap(true, .acq_rel) and !@import("builtin").is_test) {
        std.log.warn(
            "codedb: memory budget {d}MB exceeded (rss={d}MB) — stopping index walk, keeping partial index. Raise max_index_memory_mb in .codedbrc or CODEDB_MAX_MEMORY_MB, or index a subfolder.",
            .{ limitMb(), check.rss_bytes / (1024 * 1024) },
        );
    }
    return true;
}
