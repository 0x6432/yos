//! Per-CPU data, reached through GS in kernel mode.
const cpu = @import("arch/cpu.zig");

pub const MAX_CPUS = 16;

/// Field offsets 0..24 are used by entry.S (syscall_entry).
pub const PerCpu = extern struct {
    self: u64 = 0, // 0
    kernel_rsp: u64 = 0, // 8
    user_rsp: u64 = 0, // 16
    current: u64 = 0, // 24  (*sched.Thread)
    id: u64 = 0, // 32
    idle: u64 = 0, // 40  (*sched.Thread)
    tss: u64 = 0, // 48  (*gdt.Tss)
    lapic_id: u64 = 0, // 56
    online: bool = false,
    ticks: u64 = 0,
    idle_ticks: u64 = 0,
};

pub var cpus: [MAX_CPUS]PerCpu = [_]PerCpu{.{}} ** MAX_CPUS;
pub var count: usize = 1;

/// Point GS at this CPU's block (call after loading the GDT, which zeroes GS).
pub fn install(i: usize) void {
    cpus[i].self = @intFromPtr(&cpus[i]);
    cpus[i].id = i;
    cpu.wrmsr(cpu.MSR_GS_BASE, @intFromPtr(&cpus[i]));
    cpu.wrmsr(cpu.MSR_KERNEL_GS_BASE, 0);
}

pub inline fn get() *PerCpu {
    return asm volatile ("movq %%gs:0, %[r]"
        : [r] "=r" (-> *PerCpu),
    );
}

pub inline fn id() u32 {
    return @truncate(asm volatile ("movq %%gs:32, %[r]"
        : [r] "=r" (-> u64),
    ));
}
