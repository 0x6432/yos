//! Preemptive round-robin scheduler (SMP: one global run queue, BKL-serialised).
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const gdt = @import("arch/gdt.zig");
const idt = @import("arch/idt.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const time = @import("time.zig");
const log = @import("log.zig");
const apic = @import("dev/apic.zig");
const percpu = @import("percpu.zig");
const sync = @import("sync.zig");

pub const KSTACK_ORDER: u8 = 2; // 16 KiB kernel stacks
pub const KSTACK_SIZE: usize = pmm.PAGE_SIZE << KSTACK_ORDER;

pub const State = enum { ready, running, blocked, zombie };

pub const Thread = struct {
    tid: u32,
    state: State = .ready,
    saved_rsp: u64 = 0,
    kstack_phys: u64 = 0,
    kstack_top: u64 = 0,
    fpu: [512]u8 align(16) = undefined,
    fs_base: u64 = 0,
    /// opaque owner (process); null for kernel threads
    proc: ?*anyopaque = null,
    space: ?vmm.AddressSpace = null,
    preemptible: bool = false,
    next: ?*Thread = null, // run queue / wait queue link
    wake_tick: u64 = 0,
    sleeping: bool = false,
    name: [16]u8 = [_]u8{0} ** 16,
    /// set by signal/wakeup code to interrupt a blocking wait
    interrupted: bool = false,
    clear_child_tid: u64 = 0,

    pub fn setName(self: *Thread, n: []const u8) void {
        const l = @min(n.len, 15);
        @memcpy(self.name[0..l], n[0..l]);
        self.name[l] = 0;
    }
    pub fn nameSlice(self: *const Thread) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    /// Pointer to the TrapFrame at the top of the kernel stack (user threads).
    pub fn userFrame(self: *Thread) *idt.TrapFrame {
        return @ptrFromInt(self.kstack_top - @sizeOf(idt.TrapFrame));
    }
};

var boot_thread: Thread = .{ .tid = 0, .state = .running };

/// The thread running on this CPU.
pub inline fn current() *Thread {
    return asm volatile ("movq %%gs:24, %[r]"
        : [r] "=r" (-> *Thread),
    );
}
inline fn idleThread() *Thread {
    return @ptrFromInt(percpu.get().idle);
}
var rq_head: ?*Thread = null;
var rq_tail: ?*Thread = null;
var sleepers: ?*Thread = null;
var next_tid: u32 = 1;
var pending_free: ?*Thread = null;
pub var fpu_template: [512]u8 align(16) = undefined;
pub var started = false;
var need_resched = false;

extern fn switch_context(old: *u64, new: u64) callconv(.c) void;
extern fn kthread_trampoline() callconv(.c) void;
extern fn uthread_trampoline() callconv(.c) void;

fn enqueue(t: *Thread) void {
    t.next = null;
    if (rq_tail) |tail| tail.next = t else rq_head = t;
    rq_tail = t;
    kickIdle();
}
fn dequeue() ?*Thread {
    const t = rq_head orelse return null;
    rq_head = t.next;
    if (rq_head == null) rq_tail = null;
    t.next = null;
    return t;
}

fn fxsave(buf: *[512]u8) void {
    asm volatile ("fxsave64 (%[b])"
        :
        : [b] "r" (buf),
        : .{ .memory = true }
    );
}
fn fxrstor(buf: *const [512]u8) void {
    asm volatile ("fxrstor64 (%[b])"
        :
        : [b] "r" (buf),
        : .{ .memory = true }
    );
}

fn enableFpu() void {
    var cr0 = cpu.readCr0();
    cr0 &= ~@as(u64, 1 << 2); // EM
    cr0 |= 1 << 1; // MP
    cr0 &= ~@as(u64, 1 << 3); // TS
    cpu.writeCr0(cr0);
    cpu.writeCr4(cpu.readCr4() | (1 << 9) | (1 << 10)); // OSFXSR, OSXMMEXCPT
    asm volatile ("fninit");
    const mxcsr: u32 = 0x1F80;
    asm volatile ("ldmxcsr (%[m])"
        :
        : [m] "r" (&mxcsr),
    );
    fxsave(&fpu_template);
}

fn allocThread() !*Thread {
    const t = try heap.allocator.create(Thread);
    t.* = .{ .tid = next_tid };
    next_tid += 1;
    t.fpu = fpu_template;
    const st = pmm.allocPages(KSTACK_ORDER) orelse return error.OutOfMemory;
    t.kstack_phys = st;
    t.kstack_top = pmm.physToVirt(st) + KSTACK_SIZE;
    return t;
}

pub fn freeThread(t: *Thread) void {
    if (t.kstack_phys != 0) pmm.freePages(t.kstack_phys, KSTACK_ORDER);
    t.kstack_phys = 0;
    heap.allocator.destroy(t);
}

pub const KEntry = *const fn (arg: u64) callconv(.c) void;

pub fn spawnKernel(name: []const u8, entry: KEntry, arg: u64) !*Thread {
    const t = try allocThread();
    t.setName(name);
    const sp: [*]u64 = @ptrFromInt(t.kstack_top - 8 * 8);
    // r15 r14 r13 r12 rbx rbp ret
    sp[0] = 0;
    sp[1] = 0;
    sp[2] = arg;
    sp[3] = @intFromPtr(entry);
    sp[4] = 0;
    sp[5] = 0;
    sp[6] = @intFromPtr(&kthread_trampoline);
    sp[7] = 0;
    t.saved_rsp = @intFromPtr(sp);
    makeReady(t);
    return t;
}

/// Create a thread that starts in user mode with the given frame.
pub fn spawnUser(name: []const u8, frame: idt.TrapFrame, space: vmm.AddressSpace, proc: ?*anyopaque) !*Thread {
    const t = try allocThread();
    t.setName(name);
    t.space = space;
    t.proc = proc;
    const f = t.userFrame();
    f.* = frame;
    const sp: [*]u64 = @ptrFromInt(@intFromPtr(f) - 7 * 8);
    @memset(sp[0..6], 0);
    sp[6] = @intFromPtr(&uthread_trampoline);
    t.saved_rsp = @intFromPtr(sp);
    return t;
}

pub fn makeReady(t: *Thread) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    if (t.state == .zombie) return;
    if (t.state == .ready and (t.next != null or rq_tail == t)) return;
    t.state = .ready;
    enqueue(t);
}

/// Pick the next thread and switch to it. Interrupts must be disabled.
fn schedule() void {
    const prev = current();
    if (prev.state == .running and prev != idleThread()) {
        prev.state = .ready;
        // re-queue without kicking another CPU to steal it mid-switch
        prev.next = null;
        if (rq_tail) |tail| tail.next = prev else rq_head = prev;
        rq_tail = prev;
    }
    const next = dequeue() orelse idleThread();
    next.state = .running;
    if (next == prev) return;
    switchTo(prev, next);
}

fn switchTo(prev: *Thread, next: *Thread) void {
    if (prev.space != null) {
        fxsave(&prev.fpu);
        prev.fs_base = cpu.rdmsr(cpu.MSR_FS_BASE);
    }
    const pc = percpu.get();
    pc.current = @intFromPtr(next);
    pc.kernel_rsp = next.kstack_top;
    gdt.setKernelStack(next.kstack_top);
    if (next.space) |s| {
        s.activate();
        fxrstor(&next.fpu);
        cpu.wrmsr(cpu.MSR_FS_BASE, next.fs_base);
    } else if (prev.space != null) {
        vmm.kernel_space.activate();
    }
    switch_context(&prev.saved_rsp, next.saved_rsp);
    afterSwitch();
}

fn afterSwitch() void {
    if (pending_free) |z| {
        if (z != current()) {
            pending_free = null;
            if (z.proc == null) freeThread(z) else {
                // user thread: stack is released now, struct by its reaper
                pmm.freePages(z.kstack_phys, KSTACK_ORDER);
                z.kstack_phys = 0;
            }
        }
    }
}

export fn sched_thread_start() callconv(.c) void {
    afterSwitch();
    cpu.sti();
}

/// First run of a user thread: about to iretq to user mode.
export fn sched_uthread_start() callconv(.c) void {
    afterSwitch();
    sync.bklUnlock();
}

pub fn yield() void {
    const e = cpu.saveDisable();
    schedule();
    cpu.restore(e);
}

/// Block the current thread (state already set by caller with ints off).
pub fn block() void {
    const e = cpu.saveDisable();
    current().state = .blocked;
    schedule();
    cpu.restore(e);
}

pub fn wake(t: *Thread) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    if (t.state == .blocked) {
        t.state = .ready;
        enqueue(t);
    }
}

export fn sched_kthread_exit() callconv(.c) noreturn {
    exitCurrent();
}

/// Terminate the current thread; never returns.
pub fn exitCurrent() noreturn {
    cpu.cli();
    current().state = .zombie;
    pending_free = current();
    schedule();
    unreachable;
}

pub fn sleepTicks(n: u64) void {
    const e = cpu.saveDisable();
    current().wake_tick = time.now() + n;
    current().sleeping = true;
    current().state = .blocked;
    // insert into sleep list (unsorted; small)
    current().next = null;
    var t = current();
    t.next = sleepers;
    sleepers = t;
    schedule();
    cpu.restore(e);
}

pub fn sleepMs(ms: u64) void {
    sleepTicks(@max(1, (ms * time.HZ + 999) / 1000));
}

fn wakeSleepers() void {
    var prev: ?*Thread = null;
    var it = sleepers;
    while (it) |t| {
        const nx = t.next;
        if (time.now() >= t.wake_tick or t.interrupted) {
            if (prev) |p| p.next = nx else sleepers = nx;
            t.sleeping = false;
            t.next = null;
            if (t.state == .blocked) {
                t.state = .ready;
                enqueue(t);
            }
        } else prev = t;
        it = nx;
    }
}

/// Remove a thread from the sleep list (e.g. interrupted by a signal).
pub fn cancelSleep(t: *Thread) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    var prev: ?*Thread = null;
    var it = sleepers;
    while (it) |x| : (it = x.next) {
        if (x == t) {
            if (prev) |p| p.next = x.next else sleepers = x.next;
            x.next = null;
            x.sleeping = false;
            return;
        }
        prev = x;
    }
}

fn onTick(frame: *idt.TrapFrame) void {
    wakeSleepers();
    if (frame.fromUser() or current().preemptible or current() == idleThread()) {
        schedule();
    }
}

/// Idle: runs with the BKL held, drops it only while halted.
fn idleLoop(_: u64) callconv(.c) noreturn {
    cpu.cli();
    while (true) {
        if (rq_head != null) {
            schedule();
            continue;
        }
        sync.bklUnlock();
        asm volatile ("sti; hlt; cli" ::: .{ .memory = true });
        sync.bklLock();
    }
}

/// Early: make `current()` valid on the BSP (GS must already be installed).
pub fn initBoot() void {
    boot_thread.setName("boot");
    boot_thread.kstack_top = 0;
    percpu.cpus[0].current = @intFromPtr(&boot_thread);
}

fn makeIdle(cpu_id: usize) *Thread {
    var name = [_]u8{ 'i', 'd', 'l', 'e', '0' + @as(u8, @intCast(cpu_id % 10)) };
    const t = spawnKernel(&name, @ptrCast(&idleLoop), 0) catch @panic("idle");
    // idle is never on the run queue
    _ = dequeueThread(t);
    t.state = .ready;
    percpu.cpus[cpu_id].idle = @intFromPtr(t);
    return t;
}

fn dequeueThread(t: *Thread) bool {
    var prev: ?*Thread = null;
    var it = rq_head;
    while (it) |x| : (it = x.next) {
        if (x == t) {
            if (prev) |p| p.next = x.next else rq_head = x.next;
            if (rq_tail == x) rq_tail = prev;
            x.next = null;
            return true;
        }
        prev = x;
    }
    return false;
}

/// Per-AP FPU enable (the template is captured once on the BSP).
pub fn initCpuFpu() void {
    var cr0 = cpu.readCr0();
    cr0 &= ~@as(u64, 1 << 2);
    cr0 |= 1 << 1;
    cr0 &= ~@as(u64, 1 << 3);
    cpu.writeCr0(cr0);
    cpu.writeCr4(cpu.readCr4() | (1 << 9) | (1 << 10));
    asm volatile ("fninit");
    fxrstor(&fpu_template);
}

/// An AP enters the scheduler: becomes its idle thread. BKL must be held.
pub fn enterAp(cpu_id: usize) noreturn {
    const idle = makeIdle(cpu_id);
    idle.state = .running;
    const pc = &percpu.cpus[cpu_id];
    pc.current = @intFromPtr(idle);
    pc.kernel_rsp = idle.kstack_top;
    gdt.setKernelStack(idle.kstack_top);
    pc.online = true;
    // switch onto the idle thread's own stack
    asm volatile (
        \\movq %[sp], %%rsp
        \\xorl %%ebp, %%ebp
        \\call *%[f]
        :
        : [sp] "r" (idle.kstack_top - 16),
          [f] "r" (&idleLoop),
          [a] "{rdi}" (@as(u64, 0)),
        : .{ .memory = true }
    );
    unreachable;
}

/// Wake one halted CPU so it picks up newly runnable work.
fn kickIdle() void {
    if (percpu.count <= 1) return;
    const me = percpu.id();
    for (percpu.cpus[0..percpu.count], 0..) |*c, i| {
        if (i == me or !c.online) continue;
        if (c.current == c.idle) {
            apic.sendIpi(@intCast(c.lapic_id), apic.WAKE_VECTOR);
            return;
        }
    }
}

pub fn init() void {
    enableFpu();
    _ = makeIdle(0);
    apic.timer_handler = onTick;
    started = true;
    log.info("sched: round-robin scheduler ready", .{});
}

// ---------------- wait queues ----------------
pub const WaitQueue = struct {
    head: ?*Waiter = null,

    pub const Waiter = struct { t: *Thread, next: ?*Waiter = null };

    /// Sleep until woken. Call with interrupts disabled after checking the
    /// condition; returns with interrupts disabled.
    pub fn waitLocked(self: *WaitQueue) void {
        var w = Waiter{ .t = current() };
        w.next = self.head;
        self.head = &w;
        current().state = .blocked;
        schedule();
        // unlink if still present (spurious wakeup / interrupted)
        var pp: *?*Waiter = &self.head;
        while (pp.*) |x| {
            if (x == &w) {
                pp.* = x.next;
                break;
            }
            pp = &x.next;
        }
    }

    pub fn wakeAll(self: *WaitQueue) void {
        const e = cpu.saveDisable();
        defer cpu.restore(e);
        var it = self.head;
        self.head = null;
        while (it) |w| {
            it = w.next;
            if (w.t.state == .blocked) {
                w.t.state = .ready;
                enqueue(w.t);
            }
        }
    }
};
