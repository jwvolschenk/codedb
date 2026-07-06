//! cio.zig — 0.16 stdlib compatibility shim.
//!
//! 0.16 removed std.fs.File.{stdout,stderr,stdin}, cio.Mutex/RwLock,
//! std.time.Timer, std.time.nanoTimestamp, std.process.Child.run, and
//! cio.posixGetenv. This shim wraps libc/pthread primitives so existing
//! call sites continue to work with minimal import-line changes.
//!
//! Windows: uses MSVC CRT (_write, _read, etc.), kernel32 (time, env, sleep),
//! and std.atomic.Mutex (spinlock) since pthreads are not available.

const file = @import("cio/file.zig");
const sync = @import("cio/sync.zig");
const time = @import("cio/time.zig");
const process = @import("cio/process.zig");
const spawn = @import("cio/spawn.zig");

pub const File = file.File;
pub const ListWriter = file.ListWriter;
pub const listWriter = file.listWriter;

pub const Mutex = sync.Mutex;
pub const RwLock = sync.RwLock;
pub const LOCK_EX = sync.LOCK_EX;
pub const LOCK_UN = sync.LOCK_UN;
pub const flockFd = sync.flockFd;

pub const nanoTimestamp = time.nanoTimestamp;
pub const milliTimestamp = time.milliTimestamp;
pub const Timer = time.Timer;
pub const randU64 = time.randU64;
pub const sleepMs = time.sleepMs;

pub const PipeError = process.PipeError;
pub const makePipe = process.makePipe;
pub const closeFd = process.closeFd;
pub const posixGetenv = process.posixGetenv;
pub const getHomeDir = process.getHomeDir;
pub const tempDir = process.tempDir;
pub const processRssBytes = process.processRssBytes;
pub const setProcessArgs = process.setProcessArgs;
pub const setProcessArgsWindows = process.setProcessArgsWindows;
pub const argsAlloc = process.argsAlloc;
pub const argsFree = process.argsFree;

pub const CaptureResult = spawn.CaptureResult;
pub const RunOptions = spawn.RunOptions;
pub const runCapture = spawn.runCapture;
