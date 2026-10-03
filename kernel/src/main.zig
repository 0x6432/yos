const std = @import("std");
const limine = @import("limine.zig");
const cpu = @import("arch/cpu.zig");
const serial = @import("serial.zig");
const log = @import("log.zig");
const gdt = @import("arch/gdt.zig");
const idt = @import("arch/idt.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const time = @import("time.zig");
const acpi = @import("acpi.zig");
const apic = @import("dev/apic.zig");
const sched = @import("sched.zig");
const proc = @import("proc.zig");
const vfs = @import("vfs.zig");
const signal = @import("signal.zig");
const syscall = @import("syscall.zig");
const initrd = @import("initrd.zig");
const tty = @import("dev/tty.zig");

comptime {
    _ = limine;
}

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    cpu.cli();
    log.print("\n!!! KERNEL PANIC: {s}\n", .{msg});
    if (first_trace_addr) |a| log.print("    at 0x{x}\n", .{a});
    var it = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    var n: usize = 0;
    while (it.next()) |ra| : (n += 1) {
        if (n > 16) break;
        log.print("    #{d}: 0x{x}\n", .{ n, ra });
    }
    cpu.halt();
}

var counters = [_]u64{ 0, 0, 0 };
var demo_done: u32 = 0;
fn spinThread(arg: u64) callconv(.c) void {
    const start = time.now();
    while (time.now() < start + 20) {
        counters[arg] += 1;
    }
    log.info("sched: spin thread {d} finished after {d} iterations", .{ arg, counters[arg] });
    _ = @atomicRmw(u32, &demo_done, .Add, 1, .release);
}
fn sleeperThread(_: u64) callconv(.c) void {
    for (0..3) |i| {
        sched.sleepMs(50);
        log.info("sched: sleeper woke ({d}) at tick {d}", .{ i, time.now() });
    }
    _ = @atomicRmw(u32, &demo_done, .Add, 1, .release);
}

const init_candidates = [_][]const u8{ "/sbin/init", "/bin/bash", "/bin/sh", "/bin/hello" };

fn startInit() void {
    const p = proc.newProcess() catch @panic("init: oom");
    p.pgid = 1;
    p.sid = 1;
    p.cwd = vfs.resolve(vfs.root, "/root", true) catch vfs.root;
    const t = sched.spawnUser("init", std.mem.zeroes(idt.TrapFrame), p.space, p) catch @panic("init: oom");
    p.thread = t;
    const con = vfs.resolve(vfs.root, "/dev/console", true) catch @panic("no /dev/console");
    for (0..3) |i| p.fds[i] = vfs.openNode(con, vfs.O_RDWR) catch @panic("init: oom");
    const envp = [_][]const u8{ "HOME=/root", "PATH=/bin:/usr/bin:/sbin", "TERM=vt100", "SHELL=/bin/bash", "USER=root", "PS1=\\u@yos:\\w\\$ " };
    for (init_candidates) |path| {
        const n = vfs.resolve(vfs.root, path, true) catch continue;
        if (n.kind != .file) continue;
        const argv = [_][]const u8{path};
        proc.execImage(p, n.contents(), &argv, &envp, t.userFrame(), path) catch |e| {
            log.info("init: exec {s} failed: {s}", .{ path, @errorName(e) });
            continue;
        };
        log.info("starting init: {s}", .{path});
        sched.makeReady(t);
        return;
    }
    @panic("no init found");
}

export fn kmain() callconv(.c) noreturn {
    serial.init();
    log.print("\n", .{});
    log.info("yos booting (zig {s})", .{@import("builtin").zig_version_string});
    if (!limine.baseRevisionSupported()) @panic("limine base revision 3 not supported");
    log.info("hhdm offset 0x{x}", .{limine.hhdm().offset});
    const mm = limine.memmap();
    var total: u64 = 0;
    for (mm.entries[0..mm.entry_count]) |e| {
        if (e.kind == .usable) total += e.length;
    }
    log.info("usable memory: {d} MiB in {d} entries", .{ total >> 20, mm.entry_count });
    gdt.init();
    idt.init();
    log.info("gdt/tss/idt loaded", .{});
    pmm.init();
    pmm.selfTest();
    // exception path sanity check
    idt.register(3, struct {
        fn h(f: *idt.TrapFrame) void {
            log.info("breakpoint trap at rip=0x{x} handled", .{f.rip});
        }
    }.h);
    asm volatile ("int3");
    vmm.init();
    heap.selfTest();
    {
        // map a fresh page at a user address in a new address space and read it back
        const as = vmm.AddressSpace.createUser() catch @panic("as");
        const pg = pmm.allocPage().?;
        pmm.ptr(*u64, pg).* = 0xdeadbeefcafe;
        as.map(0x400000, pg, vmm.W | vmm.U) catch @panic("map");
        if (as.translate(0x400123) != pg + 0x123) @panic("vmm translate");
        const clone = as.cloneUser() catch @panic("clone");
        const cp = clone.translate(0x400000).?;
        if (cp == pg or pmm.ptr(*u64, cp).* != 0xdeadbeefcafe) @panic("vmm clone");
        clone.destroy();
        as.destroy();
        log.info("vmm: address space create/map/clone/destroy ok", .{});
    }
    time.init();
    acpi.initTables();
    apic.startTimer();
    cpu.sti();
    acpi.initNamespace();
    const t0 = time.now();
    while (time.now() < t0 + 10) cpu.hlt();
    log.info("timer: got 10 ticks", .{});
    sched.init();
    acpi.yield_hook = sched.yield;
    acpi.sleep_hook = sched.sleepMs;
    // round-robin demo: three busy threads that never yield + a sleeper
    for (0..3) |i| {
        const t = sched.spawnKernel("spin", spinThread, i) catch @panic("spawn");
        t.preemptible = true;
    }
    _ = sched.spawnKernel("sleeper", sleeperThread, 0) catch @panic("spawn");
    while (@atomicLoad(u32, &demo_done, .acquire) < 4) sched.sleepMs(20);
    log.info("sched: counters {d} {d} {d} (all progressed under preemption)", .{ counters[0], counters[1], counters[2] });
    log.info("M4 ok", .{});

    proc.init();
    signal.init();
    syscall.init();
    if (!initrd.init()) @panic("no initrd module");
    vfs.init();
    tty.init();
    startInit();
    // the boot thread has nothing left to do
    while (true) sched.sleepMs(1_000_000);
}
