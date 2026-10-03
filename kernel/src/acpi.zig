//! uACPI integration: kernel API glue + MADT discovery.
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const limine = @import("limine.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const log = @import("log.zig");
const time = @import("time.zig");
const apic = @import("dev/apic.zig");

const Status = c_uint; // uacpi_status
const OK: Status = 0;
const NOT_FOUND: Status = 5;
const Handle = ?*anyopaque;

const PciAddress = extern struct { segment: u16, bus: u8, device: u8, function: u8 };
const Table = extern struct { ptr: ?*anyopaque, index: usize };
const SdtHdr = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oemid: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

extern fn uacpi_initialize(flags: u64) Status;
extern fn uacpi_namespace_load() Status;
extern fn uacpi_namespace_initialize() Status;
extern fn uacpi_finalize_gpe_initialization() Status;
extern fn uacpi_table_find_by_signature(sig: [*:0]const u8, out: *Table) Status;
extern fn uacpi_table_unref(t: *Table) Status;
extern fn uacpi_status_to_string(s: Status) [*:0]const u8;
extern fn uacpi_prepare_for_sleep_state(state: c_uint) Status;
extern fn uacpi_enter_sleep_state(state: c_uint) Status;
extern fn uacpi_reboot() Status;

// ------------------------------------------------------------------
// kernel API exported to uACPI
// ------------------------------------------------------------------
export fn uacpi_kernel_get_rsdp(out: *u64) Status {
    const r = limine.rsdp() orelse return NOT_FOUND;
    out.* = r.address;
    return OK;
}
export fn uacpi_kernel_map(addr: u64, len: usize) ?*anyopaque {
    return @ptrFromInt(vmm.mapMmio(addr, len));
}
export fn uacpi_kernel_unmap(_: ?*anyopaque, _: usize) void {}

export fn uacpi_kernel_log(level: c_uint, msg: [*:0]const u8) void {
    const lv = switch (level) {
        1 => "error",
        2 => "warn",
        3 => "info",
        4 => "trace",
        else => "debug",
    };
    if (level > 3) return;
    log.print("[acpi:{s}] {s}", .{ lv, std.mem.span(msg) });
}

fn pciAddr(h: Handle, off: usize) u32 {
    const v: u64 = @intFromPtr(h);
    const bus: u32 = @truncate(v >> 16);
    const dev: u32 = @truncate((v >> 8) & 0x1F);
    const func: u32 = @truncate(v & 7);
    return 0x80000000 | (bus << 16) | (dev << 11) | (func << 8) | (@as(u32, @truncate(off)) & 0xFC);
}
export fn uacpi_kernel_pci_device_open(addr: PciAddress, out: *Handle) Status {
    const v: u64 = (1 << 40) | (@as(u64, addr.segment) << 24) | (@as(u64, addr.bus) << 16) | (@as(u64, addr.device) << 8) | addr.function;
    out.* = @ptrFromInt(v);
    return OK;
}
export fn uacpi_kernel_pci_device_close(_: Handle) void {}
export fn uacpi_kernel_pci_read8(h: Handle, off: usize, out: *u8) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    out.* = cpu.inb(@intCast(0xCFC + (off & 3)));
    return OK;
}
export fn uacpi_kernel_pci_read16(h: Handle, off: usize, out: *u16) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    out.* = cpu.inw(@intCast(0xCFC + (off & 2)));
    return OK;
}
export fn uacpi_kernel_pci_read32(h: Handle, off: usize, out: *u32) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    out.* = cpu.inl(0xCFC);
    return OK;
}
export fn uacpi_kernel_pci_write8(h: Handle, off: usize, v: u8) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    cpu.outb(@intCast(0xCFC + (off & 3)), v);
    return OK;
}
export fn uacpi_kernel_pci_write16(h: Handle, off: usize, v: u16) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    cpu.outw(@intCast(0xCFC + (off & 2)), v);
    return OK;
}
export fn uacpi_kernel_pci_write32(h: Handle, off: usize, v: u32) Status {
    cpu.outl(0xCF8, pciAddr(h, off));
    cpu.outl(0xCFC, v);
    return OK;
}

export fn uacpi_kernel_io_map(base: u64, _: usize, out: *Handle) Status {
    out.* = @ptrFromInt(base + 0x10000);
    return OK;
}
export fn uacpi_kernel_io_unmap(_: Handle) void {}
fn ioPort(h: Handle, off: usize) u16 {
    return @intCast(@intFromPtr(h) - 0x10000 + off);
}
export fn uacpi_kernel_io_read8(h: Handle, off: usize, out: *u8) Status {
    out.* = cpu.inb(ioPort(h, off));
    return OK;
}
export fn uacpi_kernel_io_read16(h: Handle, off: usize, out: *u16) Status {
    out.* = cpu.inw(ioPort(h, off));
    return OK;
}
export fn uacpi_kernel_io_read32(h: Handle, off: usize, out: *u32) Status {
    out.* = cpu.inl(ioPort(h, off));
    return OK;
}
export fn uacpi_kernel_io_write8(h: Handle, off: usize, v: u8) Status {
    cpu.outb(ioPort(h, off), v);
    return OK;
}
export fn uacpi_kernel_io_write16(h: Handle, off: usize, v: u16) Status {
    cpu.outw(ioPort(h, off), v);
    return OK;
}
export fn uacpi_kernel_io_write32(h: Handle, off: usize, v: u32) Status {
    cpu.outl(ioPort(h, off), v);
    return OK;
}

export fn uacpi_kernel_alloc(size: usize) ?*anyopaque {
    return @ptrCast(heap.kmalloc(size, 16));
}
export fn uacpi_kernel_free(mem: ?*anyopaque, _: usize) void {
    if (mem) |m| heap.kfree(@ptrCast(m));
}

export fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
    return time.nanos();
}
export fn uacpi_kernel_stall(us: u8) void {
    time.stallUs(us);
}
pub var sleep_hook: ?*const fn (ms: u64) void = null;
export fn uacpi_kernel_sleep(ms: u64) void {
    if (sleep_hook) |h| h(ms) else time.stallUs(ms * 1000);
}

const Mutex = struct { locked: bool = false };
pub var yield_hook: ?*const fn () void = null;
fn relax() void {
    if (yield_hook) |y| y() else cpu.pause();
}

export fn uacpi_kernel_create_mutex() Handle {
    const m: *Mutex = @ptrCast(@alignCast(heap.kmalloc(@sizeOf(Mutex), 8) orelse return null));
    m.* = .{};
    return m;
}
export fn uacpi_kernel_free_mutex(h: Handle) void {
    if (h) |p| heap.kfree(@ptrCast(p));
}
export fn uacpi_kernel_acquire_mutex(h: Handle, timeout: u16) Status {
    const m: *Mutex = @ptrCast(@alignCast(h.?));
    const deadline = time.nanos() + @as(u64, timeout) * 1_000_000;
    while (@atomicRmw(bool, &m.locked, .Xchg, true, .acquire)) {
        if (timeout == 0) return 11; // UACPI_STATUS_TIMEOUT
        if (timeout != 0xFFFF and time.nanos() > deadline) return 11;
        relax();
    }
    return OK;
}
export fn uacpi_kernel_release_mutex(h: Handle) void {
    const m: *Mutex = @ptrCast(@alignCast(h.?));
    @atomicStore(bool, &m.locked, false, .release);
}

const Event = struct { count: u64 = 0 };
export fn uacpi_kernel_create_event() Handle {
    const e: *Event = @ptrCast(@alignCast(heap.kmalloc(@sizeOf(Event), 8) orelse return null));
    e.* = .{};
    return e;
}
export fn uacpi_kernel_free_event(h: Handle) void {
    if (h) |p| heap.kfree(@ptrCast(p));
}
export fn uacpi_kernel_wait_for_event(h: Handle, timeout: u16) bool {
    const e: *Event = @ptrCast(@alignCast(h.?));
    const deadline = time.nanos() + @as(u64, timeout) * 1_000_000;
    while (true) {
        const c = @atomicLoad(u64, &e.count, .acquire);
        if (c > 0 and @cmpxchgWeak(u64, &e.count, c, c - 1, .acq_rel, .acquire) == null) return true;
        if (timeout != 0xFFFF and time.nanos() > deadline) return false;
        relax();
    }
}
export fn uacpi_kernel_signal_event(h: Handle) void {
    const e: *Event = @ptrCast(@alignCast(h.?));
    _ = @atomicRmw(u64, &e.count, .Add, 1, .release);
}
export fn uacpi_kernel_reset_event(h: Handle) void {
    const e: *Event = @ptrCast(@alignCast(h.?));
    @atomicStore(u64, &e.count, 0, .release);
}

pub var thread_id_hook: ?*const fn () usize = null;
export fn uacpi_kernel_get_thread_id() ?*anyopaque {
    return @ptrFromInt(if (thread_id_hook) |h| h() else 1);
}

export fn uacpi_kernel_disable_interrupts() c_ulong {
    return @intFromBool(cpu.saveDisable());
}
export fn uacpi_kernel_restore_interrupts(state: c_ulong) void {
    cpu.restore(state != 0);
}

export fn uacpi_kernel_handle_firmware_request(_: ?*anyopaque) Status {
    return OK;
}

const IrqCtx = struct { handler: *const fn (Handle) callconv(.c) u32, ctx: Handle, gsi: u32 };
fn irqTrampoline(p: ?*anyopaque) void {
    const c: *IrqCtx = @ptrCast(@alignCast(p.?));
    _ = c.handler(c.ctx);
}
export fn uacpi_kernel_install_interrupt_handler(irq: u32, handler: *const fn (Handle) callconv(.c) u32, ctx: Handle, out: *Handle) Status {
    const c: *IrqCtx = @ptrCast(@alignCast(heap.kmalloc(@sizeOf(IrqCtx), 8) orelse return 10));
    var gsi = irq;
    var flags: u16 = 0xF; // level, active low (SCI default)
    if (irq < 16) {
        const r = apic.isaToGsi(@intCast(irq));
        gsi = r.gsi;
        if (r.flags != 0) flags = r.flags;
    }
    c.* = .{ .handler = handler, .ctx = ctx, .gsi = gsi };
    apic.routeGsi(gsi, flags, irqTrampoline, c);
    out.* = c;
    log.info("acpi: installed SCI handler on gsi {d}", .{gsi});
    return OK;
}
export fn uacpi_kernel_uninstall_interrupt_handler(_: ?*anyopaque, h: Handle) Status {
    const c: *IrqCtx = @ptrCast(@alignCast(h.?));
    apic.unrouteGsi(c.gsi);
    heap.kfree(@ptrCast(c));
    return OK;
}

const Spin = struct { locked: bool = false };
export fn uacpi_kernel_create_spinlock() Handle {
    return uacpi_kernel_create_mutex();
}
export fn uacpi_kernel_free_spinlock(h: Handle) void {
    uacpi_kernel_free_mutex(h);
}
export fn uacpi_kernel_lock_spinlock(h: Handle) c_ulong {
    const e = cpu.saveDisable();
    const m: *Mutex = @ptrCast(@alignCast(h.?));
    while (@atomicRmw(bool, &m.locked, .Xchg, true, .acquire)) cpu.pause();
    return @intFromBool(e);
}
export fn uacpi_kernel_unlock_spinlock(h: Handle, flags: c_ulong) void {
    const m: *Mutex = @ptrCast(@alignCast(h.?));
    @atomicStore(bool, &m.locked, false, .release);
    cpu.restore(flags != 0);
}

export fn uacpi_kernel_schedule_work(_: c_uint, handler: *const fn (Handle) callconv(.c) void, ctx: Handle) Status {
    // No deferred work queue yet: run inline.
    handler(ctx);
    return OK;
}
export fn uacpi_kernel_wait_for_work_completion() Status {
    return OK;
}

// ------------------------------------------------------------------
fn check(what: []const u8, s: Status) bool {
    if (s != OK) {
        log.info("acpi: {s} failed: {s}", .{ what, std.mem.span(uacpi_status_to_string(s)) });
        return false;
    }
    return true;
}

/// Early init: tables only; parse the MADT and bring up the APICs.
pub fn initTables() void {
    if (!check("uacpi_initialize", uacpi_initialize(0))) @panic("ACPI init failed");
    var t: Table = undefined;
    if (!check("find MADT", uacpi_table_find_by_signature("APIC", &t))) @panic("no MADT");
    const hdr: *align(1) const SdtHdr = @ptrCast(t.ptr.?);
    const base: [*]const u8 = @ptrCast(t.ptr.?);
    const lapic_phys = std.mem.readInt(u32, base[36..40], .little);
    apic.initLapic(lapic_phys);
    var off: usize = 44;
    var cpus: usize = 0;
    while (off + 2 <= hdr.length) {
        const kind = base[off];
        const len = base[off + 1];
        if (len == 0) break;
        const e = base[off .. off + len];
        switch (kind) {
            0 => {
                if (std.mem.readInt(u32, e[4..8], .little) & 1 != 0) cpus += 1;
            },
            1 => apic.addIoApic(e[2], std.mem.readInt(u32, e[4..8], .little), std.mem.readInt(u32, e[8..12], .little)),
            2 => apic.addOverride(e[3], std.mem.readInt(u32, e[4..8], .little), std.mem.readInt(u16, e[8..10], .little)),
            else => {},
        }
        off += len;
    }
    _ = uacpi_table_unref(&t);
    log.info("acpi: MADT parsed: {d} cpu(s), {d} ioapic(s), {d} override(s)", .{ cpus, apic.n_ioapics, apic.n_overrides });
}

/// Full namespace init (needs interrupts + timer).
pub fn initNamespace() void {
    if (!check("namespace load", uacpi_namespace_load())) return;
    if (!check("namespace init", uacpi_namespace_initialize())) return;
    _ = check("gpe init", uacpi_finalize_gpe_initialization());
    log.info("acpi: namespace initialized", .{});
}

pub fn poweroff() noreturn {
    _ = check("prepare S5", uacpi_prepare_for_sleep_state(5));
    cpu.cli();
    _ = check("enter S5", uacpi_enter_sleep_state(5));
    cpu.halt();
}

pub fn reboot() noreturn {
    _ = check("reboot", uacpi_reboot());
    cpu.outb(0x64, 0xFE);
    cpu.halt();
}
