//! Locking primitives (uniprocessor for now: spinlocks disable interrupts).
const cpu = @import("arch/cpu.zig");

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
