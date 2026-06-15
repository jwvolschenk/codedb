const initial_scan = @import("watcher/initial_scan.zig");
const incremental = @import("watcher/incremental.zig");
const skip_rules = @import("watcher/skip_rules.zig");

pub const skip_dirs = skip_rules.skip_dirs;
pub const isSensitivePath = skip_rules.isSensitivePath;

pub const EventKind = incremental.EventKind;
pub const FsEvent = incremental.FsEvent;
pub const EventQueue = incremental.EventQueue;

pub const initialScan = initial_scan.initialScan;
pub const initialScanWithWorkerCount = initial_scan.initialScanWithWorkerCount;
pub const initialScanWithTrigrams = initial_scan.initialScanWithTrigrams;
pub const buildTrigramsFromCache = initial_scan.buildTrigramsFromCache;

pub const incrementalLoop = incremental.incrementalLoop;
pub const notifyLineBelongsToOtherRoot = incremental.notifyLineBelongsToOtherRoot;
