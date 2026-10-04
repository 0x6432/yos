//! POSIX signals with Linux numbering, siginfo, and rt_sigframe delivery.
//!
//! - standard signals (1..31) coalesce; real-time signals (32..64) queue
//! - default actions: terminate, ignore, stop, continue
//! - job control: stopped processes park in `deliver` until SIGCONT/SIGKILL
//! - SA_SIGINFO / SA_ONSTACK / SA_RESTART / SA_NODEFER / SA_RESETHAND
//! - SIGCHLD: SA_NOCLDSTOP, SA_NOCLDWAIT and SIG_IGN auto-reaping
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const idt = @import("arch/idt.zig");
const sched = @import("sched.zig");
const proc = @import("proc.zig");
const log = @import("log.zig");
const heap = @import("mm/heap.zig");

pub const SIGHUP = 1;
pub const SIGINT = 2;
pub const SIGQUIT = 3;
pub const SIGILL = 4;
pub const SIGTRAP = 5;
pub const SIGABRT = 6;
pub const SIGBUS = 7;
pub const SIGFPE = 8;
pub const SIGKILL = 9;
pub const SIGUSR1 = 10;
pub const SIGSEGV = 11;
pub const SIGUSR2 = 12;
pub const SIGPIPE = 13;
pub const SIGALRM = 14;
pub const SIGTERM = 15;
pub const SIGSTKFLT = 16;
pub const SIGCHLD = 17;
pub const SIGCONT = 18;
pub const SIGSTOP = 19;
pub const SIGTSTP = 20;
pub const SIGTTIN = 21;
pub const SIGTTOU = 22;
pub const SIGURG = 23;
pub const SIGXCPU = 24;
pub const SIGXFSZ = 25;
pub const SIGVTALRM = 26;
pub const SIGPROF = 27;
pub const SIGWINCH = 28;
pub const SIGIO = 29;
pub const SIGPWR = 30;
pub const SIGSYS = 31;
pub const SIGRTMIN = 32;
pub const NSIG = 65;

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;
pub const SA_NOCLDSTOP: u64 = 1;
pub const SA_NOCLDWAIT: u64 = 2;
pub const SA_SIGINFO: u64 = 4;
pub const SA_RESTORER: u64 = 0x04000000;
pub const SA_ONSTACK: u64 = 0x08000000;
pub const SA_RESTART: u64 = 0x10000000;
pub const SA_NODEFER: u64 = 0x40000000;
pub const SA_RESETHAND: u64 = 0x80000000;

pub const SS_ONSTACK: u32 = 1;
pub const SS_DISABLE: u32 = 2;

// si_code values
pub const SI_USER: i32 = 0;
pub const SI_KERNEL: i32 = 0x80;
pub const SI_QUEUE: i32 = -1;
pub const SI_TIMER: i32 = -2;
pub const SI_TKILL: i32 = -6;
pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const CLD_DUMPED: i32 = 3;
pub const CLD_STOPPED: i32 = 5;
pub const CLD_CONTINUED: i32 = 6;
pub const SEGV_MAPERR: i32 = 1;
pub const SEGV_ACCERR: i32 = 2;

/// Internal "restart if no handler without SA_RESTART runs" error.
pub const ERESTARTSYS: isize = 512;

pub const Action = extern struct {
    handler: u64 = 0,
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

/// Linux `siginfo_t` (128 bytes).
pub const SigInfo = extern struct {
    signo: i32 = 0,
    errno: i32 = 0,
    code: i32 = 0,
    _pad: i32 = 0,
    // union: kill {pid, uid}, chld {pid, uid, status, utime, stime},
    // fault {addr}, rt {pid, uid, value}
    f0: u64 = 0, // pid | uid<<32, or fault address
    f1: u64 = 0, // status / sigval
    f2: u64 = 0,
    f3: u64 = 0,
    rest: [12]u64 = [_]u64{0} ** 12,

    pub fn kill(sig: u32, code: i32, pid: i32) SigInfo {
        return .{ .signo = @intCast(sig), .code = code, .f0 = @as(u32, @bitCast(pid)) };
    }
    pub fn fault(sig: u32, code: i32, addr: u64) SigInfo {
        return .{ .signo = @intCast(sig), .code = code, .f0 = addr };
    }
};

const RT_QUEUE_MAX = 32;

pub const AltStack = extern struct { sp: u64 = 0, flags: u32 = SS_DISABLE, _pad: u32 = 0, size: u64 = 0 };

pub const State = struct {
    actions: [NSIG]Action = [_]Action{.{}} ** NSIG,
    pending: u64 = 0,
    blocked: u64 = 0,
    /// mask to restore after the next handler (rt_sigsuspend)
    saved_mask: ?u64 = null,
    /// siginfo of pending standard signals
    info: [SIGRTMIN]SigInfo = [_]SigInfo{.{}} ** SIGRTMIN,
    /// queued real-time signals, delivered in signal-number order
    rtq: [RT_QUEUE_MAX]SigInfo = undefined,
    rtq_len: usize = 0,
    altstack: AltStack = .{},
};

pub inline fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}
const UNBLOCKABLE: u64 = (1 << (SIGKILL - 1)) | (1 << (SIGSTOP - 1));
const STOP_MASK: u64 = (1 << (SIGSTOP - 1)) | (1 << (SIGTSTP - 1)) | (1 << (SIGTTIN - 1)) | (1 << (SIGTTOU - 1));

pub const Default = enum { term, core, ignore, stop, cont };
pub fn defaultAction(sig: u32) Default {
    return switch (sig) {
        SIGCHLD, SIGURG, SIGWINCH => .ignore,
        SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .stop,
        SIGCONT => .cont,
        SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGXCPU, SIGXFSZ, SIGSYS => .core,
        else => .term,
    };
}

pub fn sanitizeMask(m: u64) u64 {
    return m & ~UNBLOCKABLE;
}

fn ignored(p: *proc.Process, sig: u32) bool {
    if (sig == SIGKILL or sig == SIGSTOP) return false;
    const a = p.sig.actions[sig];
    if (a.handler == SIG_IGN) return true;
    if (a.handler == SIG_DFL) {
        const d = defaultAction(sig);
        return d == .ignore or d == .cont;
    }
    return false;
}

fn wakeThread(p: *proc.Process) void {
    const t = p.thread;
    t.interrupted = true;
    if (t.state == .blocked) {
        if (t.sleeping) sched.cancelSleep(t);
        sched.wake(t);
    }
}

/// Notify the parent about a child state change.
pub fn notifyParent(child: *proc.Process, code: i32, status: i32) void {
    const par = child.parent orelse return;
    const a = par.sig.actions[SIGCHLD];
    const is_stop = code == CLD_STOPPED or code == CLD_CONTINUED;
    if (!(is_stop and a.flags & SA_NOCLDSTOP != 0)) {
        var info = SigInfo.kill(SIGCHLD, code, child.pid);
        info.f1 = @as(u32, @bitCast(status));
        sendSignalInfo(par, SIGCHLD, info);
    }
    par.child_wait.wakeAll();
}

pub fn sendSignal(p: *proc.Process, sig: u32) void {
    sendSignalInfo(p, sig, SigInfo.kill(sig, SI_KERNEL, 0));
}

pub fn sendSignalInfo(p: *proc.Process, sig: u32, info_in: SigInfo) void {
    if (sig == 0 or sig >= NSIG or p.zombie) return;
    var info = info_in;
    info.signo = @intCast(sig);
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    // SIGCONT resumes a stopped process regardless of disposition;
    // stop signals cancel a pending SIGCONT and vice versa.
    if (sig == SIGCONT) {
        p.sig.pending &= ~STOP_MASK;
        if (p.stopped) {
            p.stopped = false;
            p.wait_event = .continued;
            notifyParent(p, CLD_CONTINUED, SIGCONT);
            wakeThread(p);
        }
    } else if (STOP_MASK & bit(sig) != 0) {
        p.sig.pending &= ~bit(SIGCONT);
    }
    if (sig == SIGKILL and p.stopped) p.stopped = false;
    if (ignored(p, sig)) return;
    if (sig >= SIGRTMIN) {
        if (p.sig.rtq_len >= RT_QUEUE_MAX) return; // queue overflow: drop
        p.sig.rtq[p.sig.rtq_len] = info;
        p.sig.rtq_len += 1;
    } else if (p.sig.pending & bit(sig) == 0) {
        p.sig.info[sig] = info;
    }
    p.sig.pending |= bit(sig);
    if (p.sig.blocked & bit(sig) == 0 or sig == SIGKILL) wakeThread(p);
}

/// Synchronous fault: deliver now (unblock / reset if ignored).
pub fn forceSignal(p: *proc.Process, info: SigInfo) void {
    const sig: u32 = @intCast(info.signo);
    const a = &p.sig.actions[sig];
    if (a.handler == SIG_IGN or p.sig.blocked & bit(sig) != 0) {
        a.handler = SIG_DFL;
        p.sig.blocked &= ~bit(sig);
    }
    p.sig.info[sig] = info;
    p.sig.pending |= bit(sig);
}

pub fn sendGroup(pgid: i32, sig: u32) usize {
    var n: usize = 0;
    for (proc.procs.items) |p| {
        if (p.pgid == pgid and !p.zombie) {
            sendSignal(p, sig);
            n += 1;
        }
    }
    return n;
}

/// Is a deliverable signal pending for the current process?
pub fn hasPending() bool {
    const p = proc.currentOrNull() orelse return false;
    return p.sig.pending & (~p.sig.blocked | UNBLOCKABLE) != 0;
}

pub fn nextPending(p: *proc.Process) ?u32 {
    const deliverable = p.sig.pending & (~p.sig.blocked | UNBLOCKABLE);
    if (deliverable == 0) return null;
    // SIGKILL first, then lowest number
    if (deliverable & bit(SIGKILL) != 0) return SIGKILL;
    return @as(u32, @ctz(deliverable)) + 1;
}

/// Remove one instance of `sig` from the pending set; returns its info.
pub fn dequeue(p: *proc.Process, sig: u32) SigInfo {
    if (sig >= SIGRTMIN) {
        var info: SigInfo = .{ .signo = @intCast(sig) };
        var found = false;
        var still = false;
        var i: usize = 0;
        while (i < p.sig.rtq_len) {
            if (p.sig.rtq[i].signo == @as(i32, @intCast(sig))) {
                if (!found) {
                    info = p.sig.rtq[i];
                    found = true;
                    std.mem.copyForwards(SigInfo, p.sig.rtq[i .. p.sig.rtq_len - 1], p.sig.rtq[i + 1 .. p.sig.rtq_len]);
                    p.sig.rtq_len -= 1;
                    continue;
                }
                still = true;
            }
            i += 1;
        }
        if (!still) p.sig.pending &= ~bit(sig);
        return info;
    }
    p.sig.pending &= ~bit(sig);
    return p.sig.info[sig];
}

/// Drop all pending instances of `sig` (disposition became "ignore").
pub fn discard(p: *proc.Process, sig: u32) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    p.sig.pending &= ~bit(sig);
    if (sig >= SIGRTMIN) {
        var j: usize = 0;
        for (p.sig.rtq[0..p.sig.rtq_len]) |x| {
            if (x.signo != @as(i32, @intCast(sig))) {
                p.sig.rtq[j] = x;
                j += 1;
            }
        }
        p.sig.rtq_len = j;
    }
}

/// Sleep until a deliverable signal is pending (pause/sigsuspend).
pub fn waitForSignal() void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    while (!hasPending()) sched.block();
}

/// Decide what an interrupted syscall returning ERESTARTSYS/EINTR should do.
pub fn shouldRestart(p: *proc.Process) bool {
    const sig = nextPending(p) orelse return true;
    const a = p.sig.actions[sig];
    if (a.handler > SIG_IGN) return a.flags & SA_RESTART != 0;
    return true; // ignored / stop / continue: transparently restart
}

// ---------------- frame layout (matches Linux rt_sigframe) ----------------
const UContext = extern struct {
    flags: u64,
    link: u64,
    ss_sp: u64,
    ss_flags: u32,
    _ss_pad: u32,
    ss_size: u64,
    // mcontext gregs in Linux order
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rax: u64,
    rcx: u64,
    rsp: u64,
    rip: u64,
    eflags: u64,
    csgsfs: u64,
    err: u64,
    trapno: u64,
    oldmask: u64,
    cr2: u64,
    fpstate: u64,
    reserved: [8]u64,
    sigmask: u64,
};
const SigFrame = extern struct {
    restorer: u64,
    uc: UContext,
    info: SigInfo,
    fpu: [512]u8,
};
comptime {
    // frame base is 8 mod 16, so fpu must sit at 8 mod 16 to be aligned
    std.debug.assert(@offsetOf(SigFrame, "fpu") % 16 == 8);
}

fn onAltStack(p: *proc.Process, sp: u64) bool {
    const as = p.sig.altstack;
    return as.flags & SS_DISABLE == 0 and sp > as.sp and sp <= as.sp + as.size;
}

pub fn altStackFlags(p: *proc.Process, sp: u64) u32 {
    if (p.sig.altstack.flags & SS_DISABLE != 0) return SS_DISABLE;
    return if (onAltStack(p, sp)) SS_ONSTACK else 0;
}

fn terminate(p: *proc.Process, sig: u32) noreturn {
    proc.exitProcess(p, sig & 0x7f);
}

/// Park a process stopped by `sig` until SIGCONT or SIGKILL.
fn stopProcess(p: *proc.Process, sig: u32) void {
    p.stopped = true;
    p.stop_sig = sig;
    p.wait_event = .stopped;
    notifyParent(p, CLD_STOPPED, @intCast(sig));
    while (p.stopped and p.sig.pending & bit(SIGKILL) == 0) {
        p.thread.interrupted = false;
        sched.block();
    }
}

/// Called right before returning to user mode.
pub fn deliver(frame: *idt.TrapFrame) void {
    const p = proc.currentOrNull() orelse return;
    p.thread.interrupted = false;
    while (nextPending(p)) |sig| {
        const info = dequeue(p, sig);
        const a = p.sig.actions[sig];
        if (sig == SIGKILL) terminate(p, sig);
        if (a.handler == SIG_IGN) continue;
        if (a.handler == SIG_DFL) {
            switch (defaultAction(sig)) {
                .ignore, .cont => continue,
                .stop => {
                    stopProcess(p, sig);
                    continue;
                },
                .term, .core => terminate(p, sig),
            }
        }
        setupFrame(p, frame, sig, a, info) catch terminate(p, SIGSEGV);
        if (a.flags & SA_RESETHAND != 0) p.sig.actions[sig] = .{};
        return;
    }
    // no handler ran: undo a sigsuspend temporary mask
    if (p.sig.saved_mask) |m| {
        p.sig.blocked = m;
        p.sig.saved_mask = null;
    }
}

fn setupFrame(p: *proc.Process, frame: *idt.TrapFrame, sig: u32, a: Action, info: SigInfo) !void {
    var sp = frame.rsp;
    const as = p.sig.altstack;
    if (a.flags & SA_ONSTACK != 0 and as.flags & SS_DISABLE == 0 and !onAltStack(p, sp)) {
        sp = as.sp + as.size;
    } else {
        sp -= 128; // skip red zone
    }
    sp -= @sizeOf(SigFrame);
    sp &= ~@as(u64, 15);
    sp -= 8; // as if `call`ed: (rsp + 8) % 16 == 0
    var sf = std.mem.zeroes(SigFrame);
    sf.restorer = a.restorer;
    sf.uc = .{
        .flags = 0, .link = 0, .ss_sp = as.sp, .ss_flags = altStackFlags(p, frame.rsp), ._ss_pad = 0, .ss_size = as.size,
        .r8 = frame.r8, .r9 = frame.r9, .r10 = frame.r10, .r11 = frame.r11,
        .r12 = frame.r12, .r13 = frame.r13, .r14 = frame.r14, .r15 = frame.r15,
        .rdi = frame.rdi, .rsi = frame.rsi, .rbp = frame.rbp, .rbx = frame.rbx,
        .rdx = frame.rdx, .rax = frame.rax, .rcx = frame.rcx, .rsp = frame.rsp,
        .rip = frame.rip, .eflags = frame.rflags, .csgsfs = 0x23,
        .err = frame.error_code, .trapno = frame.vector, .oldmask = p.sig.blocked,
        .cr2 = if (sig == SIGSEGV or sig == SIGBUS) info.f0 else 0,
        .fpstate = 0, .reserved = [_]u64{0} ** 8, .sigmask = p.sig.saved_mask orelse p.sig.blocked,
    };
    p.sig.saved_mask = null;
    sf.info = info;
    asm volatile ("fxsave64 (%[b])"
        :
        : [b] "r" (&p.thread.fpu),
        : "memory"
    );
    sf.fpu = p.thread.fpu;
    sf.uc.fpstate = sp + @offsetOf(SigFrame, "fpu");
    try proc.copyToUser(sp, std.mem.asBytes(&sf));
    var newmask = p.sig.blocked | a.mask;
    if (a.flags & SA_NODEFER == 0) newmask |= bit(sig);
    p.sig.blocked = sanitizeMask(newmask);
    frame.rsp = sp;
    frame.rip = a.handler;
    frame.rdi = sig;
    frame.rsi = sp + @offsetOf(SigFrame, "info");
    frame.rdx = sp + @offsetOf(SigFrame, "uc");
    frame.rax = 0;
    frame.rflags &= ~@as(u64, 0x400 | 0x100); // clear DF, TF
}

pub fn sigreturn(frame: *idt.TrapFrame) void {
    const p = proc.current();
    const base = frame.rsp - 8;
    const sf = proc.readUser(SigFrame, base) catch terminate(p, SIGSEGV);
    const u = sf.uc;
    frame.r8 = u.r8;
    frame.r9 = u.r9;
    frame.r10 = u.r10;
    frame.r11 = u.r11;
    frame.r12 = u.r12;
    frame.r13 = u.r13;
    frame.r14 = u.r14;
    frame.r15 = u.r15;
    frame.rdi = u.rdi;
    frame.rsi = u.rsi;
    frame.rbp = u.rbp;
    frame.rbx = u.rbx;
    frame.rdx = u.rdx;
    frame.rax = u.rax;
    frame.rcx = u.rcx;
    frame.rsp = u.rsp;
    frame.rip = u.rip;
    frame.rflags = (u.eflags & 0xDD5) | 0x202;
    frame.cs = 0x23;
    frame.ss = 0x1b;
    p.sig.blocked = sanitizeMask(u.sigmask);
    p.thread.fpu = sf.fpu;
    // keep MXCSR valid (reserved bits set would #GP in fxrstor)
    const mxcsr = std.mem.readInt(u32, p.thread.fpu[24..28], .little) & 0xFFFF;
    std.mem.writeInt(u32, p.thread.fpu[24..28], mxcsr, .little);
    asm volatile ("fxrstor64 (%[b])"
        :
        : [b] "r" (&p.thread.fpu),
        : "memory"
    );
}

/// Reset dispositions on exec: caught signals revert to default.
pub fn onExec(p: *proc.Process) void {
    for (&p.sig.actions) |*a| {
        if (a.handler > SIG_IGN) a.* = .{};
        a.flags &= ~SA_ONSTACK;
    }
    p.sig.altstack = .{};
    p.sig.saved_mask = null;
}

fn returnToUser(frame: *idt.TrapFrame) void {
    deliver(frame);
}

// ---------------- interval timers (ITIMER_REAL / alarm) ----------------
fn timerThread(_: u64) callconv(.c) void {
    const time = @import("time.zig");
    while (true) {
        sched.sleepTicks(1);
        const now = time.nanos();
        for (proc.procs.items) |p| {
            if (p.zombie or p.alarm_ns == 0 or now < p.alarm_ns) continue;
            p.alarm_ns = if (p.alarm_interval_ns != 0) now + p.alarm_interval_ns else 0;
            sendSignalInfo(p, SIGALRM, SigInfo.kill(SIGALRM, SI_TIMER, 0));
        }
        proc.reapOrphans();
    }
}

pub fn init() void {
    idt.return_to_user_hook = returnToUser;
    _ = sched.spawnKernel("ksignald", timerThread, 0) catch @panic("ksignald");
}
