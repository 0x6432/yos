//! Time keeping: TSC calibrated against the PIT, plus a tick counter.
const cpu = @import("arch/cpu.zig");
const log = @import("log.zig");
const limine = @import("limine.zig");

pub var tsc_per_us: u64 = 1000;
var tsc_boot: u64 = 0;
pub var ticks: u64 = 0;
pub const HZ: u64 = 100;
pub var boot_epoch: i64 = 0;

/// Busy-wait ~`ms` milliseconds using PIT channel 2 (only used for calibration).
fn pitWait10ms() void {
    const count: u16 = 11932; // 1193182 Hz / 100
    cpu.outb(0x61, (cpu.inb(0x61) & 0xFD) | 1);
    cpu.outb(0x43, 0xB0);
    cpu.outb(0x42, @truncate(count));
    cpu.outb(0x42, @truncate(count >> 8));
    const v = cpu.inb(0x61) & 0xFE;
    cpu.outb(0x61, v);
    cpu.outb(0x61, v | 1);
    while (cpu.inb(0x61) & 0x20 == 0) cpu.pause();
}

pub fn init() void {
    tsc_boot = cpu.rdtsc();
    var best: u64 = ~@as(u64, 0);
    for (0..3) |_| {
        const t0 = cpu.rdtsc();
        pitWait10ms();
        const d = cpu.rdtsc() - t0;
        best = @min(best, d);
    }
    tsc_per_us = @max(best / 10000, 1);
    boot_epoch = limine.bootTime();
    log.info("time: TSC ~{d} MHz, boot epoch {d}", .{ tsc_per_us, boot_epoch });
}

pub inline fn now() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

pub fn nanos() u64 {
    return (cpu.rdtsc() - tsc_boot) * 1000 / tsc_per_us;
}

pub fn stallUs(us: u64) void {
    const end = cpu.rdtsc() + us * tsc_per_us;
    while (cpu.rdtsc() < end) cpu.pause();
}
