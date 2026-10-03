//! Local APIC, I/O APIC and legacy PIC handling.
const std = @import("std");
const cpu = @import("../arch/cpu.zig");
const idt = @import("../arch/idt.zig");
const vmm = @import("../mm/vmm.zig");
const log = @import("../log.zig");
const time = @import("../time.zig");

pub const TIMER_VECTOR: u8 = 32;
pub const IRQ_BASE: u8 = 48;
pub const SPURIOUS: u8 = 0xFF;

var lapic: u64 = 0;

pub const IoApic = struct { id: u8, addr: u64, gsi_base: u32, count: u32 };
pub const Override = struct { source: u8, gsi: u32, flags: u16 };

pub var ioapics: [8]IoApic = undefined;
pub var n_ioapics: usize = 0;
pub var overrides: [16]Override = undefined;
pub var n_overrides: usize = 0;

fn lr(reg: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(lapic + reg)).*;
}
fn lw(reg: u32, v: u32) void {
    @as(*volatile u32, @ptrFromInt(lapic + reg)).* = v;
}

pub fn eoi() void {
    lw(0xB0, 0);
}

pub fn lapicId() u32 {
    return lr(0x20) >> 24;
}

fn disablePic() void {
    // remap to 0x20..0x2F, then mask everything
    cpu.outb(0x20, 0x11);
    cpu.outb(0xA0, 0x11);
    cpu.outb(0x21, 0x20);
    cpu.outb(0xA1, 0x28);
    cpu.outb(0x21, 4);
    cpu.outb(0xA1, 2);
    cpu.outb(0x21, 1);
    cpu.outb(0xA1, 1);
    cpu.outb(0x21, 0xFF);
    cpu.outb(0xA1, 0xFF);
}

pub fn initLapic(phys: u64) void {
    disablePic();
    lapic = vmm.mapMmio(phys, 4096);
    cpu.wrmsr(cpu.MSR_APIC_BASE, cpu.rdmsr(cpu.MSR_APIC_BASE) | (1 << 11));
    lw(0xF0, 0x100 | @as(u32, SPURIOUS)); // enable + spurious vector
    lw(0x80, 0); // TPR
    idt.register(SPURIOUS, struct {
        fn h(_: *idt.TrapFrame) void {}
    }.h);
    log.info("apic: LAPIC id {d} at phys 0x{x}", .{ lapicId(), phys });
}

pub var timer_handler: ?*const fn (*idt.TrapFrame) void = null;

fn timerIrq(f: *idt.TrapFrame) void {
    _ = @atomicRmw(u64, &time.ticks, .Add, 1, .monotonic);
    eoi();
    if (timer_handler) |h| h(f);
}

pub fn startTimer() void {
    lw(0x3E0, 0x3); // divide by 16
    lw(0x320, 1 << 16); // masked one-shot
    lw(0x380, 0xFFFFFFFF);
    time.stallUs(10000);
    const elapsed = 0xFFFFFFFF - lr(0x390);
    lw(0x380, 0);
    const per_tick: u32 = @intCast(elapsed * 100 / time.HZ);
    idt.register(TIMER_VECTOR, timerIrq);
    lw(0x320, @as(u32, TIMER_VECTOR) | (1 << 17)); // periodic
    lw(0x380, per_tick);
    log.info("apic: timer {d} Hz ({d} counts/tick)", .{ time.HZ, per_tick });
}

// ---------------- I/O APIC ----------------
fn ioRead(a: u64, reg: u32) u32 {
    @as(*volatile u32, @ptrFromInt(a)).* = reg;
    return @as(*volatile u32, @ptrFromInt(a + 0x10)).*;
}
fn ioWrite(a: u64, reg: u32, v: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = reg;
    @as(*volatile u32, @ptrFromInt(a + 0x10)).* = v;
}

pub fn addIoApic(id: u8, phys: u64, gsi_base: u32) void {
    const v = vmm.mapMmio(phys, 4096);
    const count = ((ioRead(v, 1) >> 16) & 0xFF) + 1;
    ioapics[n_ioapics] = .{ .id = id, .addr = v, .gsi_base = gsi_base, .count = count };
    n_ioapics += 1;
    for (0..count) |i| ioWrite(v, 0x10 + 2 * @as(u32, @intCast(i)), 1 << 16); // mask all
    log.info("apic: IOAPIC id {d} gsi {d}..{d}", .{ id, gsi_base, gsi_base + count - 1 });
}

pub fn addOverride(source: u8, gsi: u32, flags: u16) void {
    overrides[n_overrides] = .{ .source = source, .gsi = gsi, .flags = flags };
    n_overrides += 1;
}

/// Translate an ISA IRQ to (gsi, flags).
pub fn isaToGsi(irq: u8) struct { gsi: u32, flags: u16 } {
    for (overrides[0..n_overrides]) |o| if (o.source == irq) return .{ .gsi = o.gsi, .flags = o.flags };
    return .{ .gsi = irq, .flags = 0 };
}

const IrqHandler = struct { f: *const fn (?*anyopaque) void, ctx: ?*anyopaque };
var irq_handlers: [64]?IrqHandler = [_]?IrqHandler{null} ** 64;

fn irqEntry(frame: *idt.TrapFrame) void {
    const gsi = frame.vector - IRQ_BASE;
    if (irq_handlers[gsi]) |h| h.f(h.ctx);
    eoi();
}

/// Route a GSI to vector IRQ_BASE+gsi on the BSP and install a handler.
/// flags use MADT MPS INTI encoding (polarity bits 0-1, trigger bits 2-3).
pub fn routeGsi(gsi: u32, flags: u16, f: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    irq_handlers[gsi] = .{ .f = f, .ctx = ctx };
    const vec: u8 = @intCast(IRQ_BASE + gsi);
    idt.register(vec, irqEntry);
    for (ioapics[0..n_ioapics]) |io| {
        if (gsi < io.gsi_base or gsi >= io.gsi_base + io.count) continue;
        var lo: u32 = vec;
        if (flags & 3 == 3) lo |= 1 << 13; // active low
        if ((flags >> 2) & 3 == 3) lo |= 1 << 15; // level triggered
        const idx = gsi - io.gsi_base;
        ioWrite(io.addr, 0x10 + 2 * idx + 1, lapicId() << 24);
        ioWrite(io.addr, 0x10 + 2 * idx, lo);
        return;
    }
    log.info("apic: no IOAPIC for gsi {d}", .{gsi});
}

pub fn routeIsa(irq: u8, f: *const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    const r = isaToGsi(irq);
    routeGsi(r.gsi, r.flags, f, ctx);
}

pub fn unrouteGsi(gsi: u32) void {
    irq_handlers[gsi] = null;
    for (ioapics[0..n_ioapics]) |io| {
        if (gsi < io.gsi_base or gsi >= io.gsi_base + io.count) continue;
        ioWrite(io.addr, 0x10 + 2 * (gsi - io.gsi_base), 1 << 16);
    }
}
