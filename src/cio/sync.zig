const std = @import("std");
const platform = @import("platform.zig");

const is_windows = platform.is_windows;
const posix = platform.posix;

pub const Mutex = struct {
    inner: if (is_windows) std.atomic.Mutex else std.c.pthread_mutex_t = if (is_windows) .unlocked else .{},

    pub fn lock(self: *Mutex) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
    }
    pub fn unlock(self: *Mutex) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *Mutex) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
        }
    }
};

pub const RwLock = struct {
    inner: if (is_windows) std.atomic.Mutex else std.c.pthread_rwlock_t = if (is_windows) .unlocked else .{},

    // Windows: uses atomic spinlock (Mutex) for both exclusive and shared.
    // This is acceptable for codedb's short critical sections.
    pub fn lock(self: *RwLock) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_rwlock_wrlock(&self.inner);
        }
    }
    pub fn unlock(self: *RwLock) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn lockShared(self: *RwLock) void {
        if (is_windows) {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        } else {
            _ = std.c.pthread_rwlock_rdlock(&self.inner);
        }
    }
    pub fn unlockShared(self: *RwLock) void {
        if (is_windows) {
            self.inner.unlock();
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *RwLock) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_rwlock_trywrlock(&self.inner) == .SUCCESS;
        }
    }
    pub fn tryLockShared(self: *RwLock) bool {
        if (is_windows) {
            return self.inner.tryLock();
        } else {
            return std.c.pthread_rwlock_tryrdlock(&self.inner) == .SUCCESS;
        }
    }
};

pub const LOCK_EX: c_int = 2;
pub const LOCK_UN: c_int = 8;

/// Best-effort advisory lock on an open file descriptor. Non-fatal on error.
pub fn flockFd(fd: c_int, operation: c_int) void {
    if (!is_windows) {
        _ = posix.flock(fd, operation);
    }
    // Windows: advisory flock not implemented (not used in Windows builds yet).
    // TODO: Use LockFileEx/UnlockFileEx on Windows HANDLE if needed.
}
