//! Symmetric multiprocessing: bring up the APs Limine parked for us.
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const gdt = @import("arch/gdt.zig");
const idt = @import("arch/idt.zig");
const vmm = @import("mm/vmm.zig");
const apic = @import("dev/apic.zig");
const limine = @import("limine.zig");
const log = @import("log.zig");
const percpu = @import("percpu.zig");
const sched = @import("sched.zig");
const sync = @import("sync.zig");
const syscall = @import("syscall.zig");

var started: u32 = 0;
var ap_stacks: [percpu.MAX_CPUS][16384]u8 align(16) = undefined;
var index_of_lapic: [256]u8 = [_]u8{0} ** 256;

/// Limine jumps here with rdi = *MpInfo, on a bootloader stack.
/// Move to a kernel stack (extra_argument) before anything else.
fn apEntry() callconv(.naked) noreturn {
    asm volatile (
        \\cli
        \\movq 24(%%rdi), %%rsp
        \\xorl %%ebp, %%ebp
        \\call %[main:P]
        \\ud2
        :
        : [main] "X" (&apMain),
    );
}

fn apMain(info: *limine.MpInfo) callconv(.c) noreturn {
    const i: usize = index_of_lapic[info.lapic_id & 0xff];
    vmm.kernel_space.activate();
    gdt.initCpu(i);
    percpu.install(i);
    percpu.cpus[i].lapic_id = info.lapic_id;
    idt.load();
    sched.initCpuFpu();
    syscall.initCpu();
    apic.enableLocal();
    sync.bklLock();
    apic.startTimerLocal();
    _ = @atomicRmw(u32, &started, .Add, 1, .release);
    log.info("smp: cpu{d} online (lapic {d})", .{ i, info.lapic_id });
    sched.enterAp(i);
}

/// Start all APs. Called by the boot thread once the scheduler runs.
pub fn init() void {
    percpu.cpus[0].lapic_id = apic.lapicId();
    percpu.cpus[0].online = true;
    const r = limine.mp() orelse {
        log.info("smp: no MP response, running on 1 CPU", .{});
        return;
    };
    var n: usize = 1;
    for (r.cpus[0..r.cpu_count]) |info| {
        if (info.lapic_id == r.bsp_lapic_id) continue;
        if (n >= percpu.MAX_CPUS) break;
        index_of_lapic[info.lapic_id & 0xff] = @intCast(n);
        info.extra_argument = @intFromPtr(&ap_stacks[n]) + ap_stacks[n].len;
        n += 1;
    }
    percpu.count = n;
    for (r.cpus[0..r.cpu_count]) |info| {
        if (info.lapic_id == r.bsp_lapic_id or info.extra_argument == 0) continue;
        @atomicStore(usize, @as(*usize, @ptrCast(&info.goto_address)), @intFromPtr(&apEntry), .release);
    }
    // APs need the BKL to come up; sleeping releases it
    const want: u32 = @intCast(n - 1);
    var waited: usize = 0;
    while (@atomicLoad(u32, &started, .acquire) < want and waited < 200) : (waited += 1) sched.sleepMs(10);
    while (true) {
        var online: usize = 0;
        for (percpu.cpus[0..n]) |*c| if (@atomicLoad(bool, &c.online, .acquire)) {
            online += 1;
        };
        if (online == n or waited >= 200) break;
        sched.sleepMs(10);
        waited += 1;
    }
    log.info("smp: {d} of {d} CPUs online", .{ @atomicLoad(u32, &started, .acquire) + 1, n });
}
