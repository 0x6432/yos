//! Locking primitives.
//!
//! SMP model: a Big Kernel Lock (BKL) serialises all kernel code. A CPU
//! owns the BKL whenever it executes kernel code, except while its idle
//! thread is halted. Ownership is per CPU and is handed across context
//! switches implicitly. It is taken on entry from user mode (syscall,
//! interrupt, exception) and released right before returning to user mode.
//! Within the kernel, disabling interrupts still provides mutual exclusion
//! against interrupt handlers on the same CPU.
const cpu = @import("arch/cpu.zig");
const percpu = @import("percpu.zig");

pub const SpinLock = struct {
    locked: bool = false,

    pub fn lock(self: *SpinLock) bool {
        const e = cpu.saveDisable();
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) cpu.pause();
        return e;
    }
    pub fn unlock(self: *SpinLock, e: bool) void {
        @atomicStore(bool, &self.locked, false, .release);
        cpu.restore(e);
    }
};

/// Owner CPU id, or -1. The BSP owns it from boot.
var bkl_owner: i32 = 0;
pub var bkl_contended: u64 = 0;

pub inline fn bklHeld() bool {
    return @atomicLoad(i32, &bkl_owner, .monotonic) == @as(i32, @intCast(percpu.id()));
}

/// Acquire the BKL (interrupts must be disabled).
pub fn bklLock() void {
    const me: i32 = @intCast(percpu.id());
    if (@cmpxchgStrong(i32, &bkl_owner, -1, me, .acquire, .monotonic) == null) return;
    _ = @atomicRmw(u64, &bkl_contended, .Add, 1, .monotonic);
    while (true) {
        while (@atomicLoad(i32, &bkl_owner, .monotonic) != -1) cpu.pause();
        if (@cmpxchgWeak(i32, &bkl_owner, -1, me, .acquire, .monotonic) == null) return;
    }
}

pub fn bklUnlock() void {
    @atomicStore(i32, &bkl_owner, -1, .release);
}
