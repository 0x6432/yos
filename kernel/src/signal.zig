//! POSIX signals (Linux numbering and rt_sigframe-compatible delivery).
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const idt = @import("arch/idt.zig");
const sched = @import("sched.zig");
const proc = @import("proc.zig");
const log = @import("log.zig");

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
pub const SIGCHLD = 17;
pub const SIGCONT = 18;
pub const SIGSTOP = 19;
pub const SIGTSTP = 20;
pub const SIGTTIN = 21;
pub const SIGTTOU = 22;
pub const SIGURG = 23;
pub const SIGWINCH = 28;
pub const NSIG = 65;

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;
pub const SA_SIGINFO: u64 = 4;
pub const SA_ONSTACK: u64 = 0x08000000;
pub const SA_RESTART: u64 = 0x10000000;
pub const SA_NODEFER: u64 = 0x40000000;
pub const SA_RESETHAND: u64 = 0x80000000;
pub const SA_RESTORER: u64 = 0x04000000;

pub const Action = extern struct {
    handler: u64 = 0,
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

pub const State = struct {
    actions: [NSIG]Action = [_]Action{.{}} ** NSIG,
    pending: u64 = 0,
    blocked: u64 = 0,
    /// mask to restore after the next handler (rt_sigsuspend)
    saved_mask: ?u64 = null,
};

inline fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}

const Default = enum { term, ignore, stop, cont };
fn defaultAction(sig: u32) Default {
    return switch (sig) {
        SIGCHLD, SIGURG, SIGWINCH => .ignore,
        SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .stop,
        SIGCONT => .cont,
        else => .term,
    };
}

pub fn sendSignal(p: *proc.Process, sig: u32) void {
    if (sig == 0 or sig >= NSIG or p.zombie) return;
    const a = p.sig.actions[sig];
    if (sig != SIGKILL and sig != SIGSTOP) {
        if (a.handler == SIG_IGN) return;
        if (a.handler == SIG_DFL) {
            const d = defaultAction(sig);
            if (d == .ignore or d == .cont or d == .stop) return; // no job stop support yet
        }
    }
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    p.sig.pending |= bit(sig);
    if (p.sig.blocked & bit(sig) == 0 or sig == SIGKILL) {
        const t = p.thread;
        t.interrupted = true;
        if (t.state == .blocked) {
            if (t.sleeping) sched.cancelSleep(t);
            sched.wake(t);
        }
    }
}

/// Synchronous fault: deliver now (unblock if needed, kill if ignored).
pub fn forceSignal(p: *proc.Process, sig: u32) void {
    const a = &p.sig.actions[sig];
    if (a.handler == SIG_IGN or p.sig.blocked & bit(sig) != 0) {
        a.handler = SIG_DFL;
        p.sig.blocked &= ~bit(sig);
    }
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
    return p.sig.pending & ~p.sig.blocked != 0 or p.sig.pending & bit(SIGKILL) != 0;
}

pub fn nextPending(p: *proc.Process) ?u32 {
    const deliverable = p.sig.pending & (~p.sig.blocked | bit(SIGKILL));
    if (deliverable == 0) return null;
    return @as(u32, @ctz(deliverable)) + 1;
}

pub fn restartable(p: *proc.Process) bool {
    const sig = nextPending(p) orelse return false;
    const a = p.sig.actions[sig];
    return a.handler > SIG_IGN and a.flags & SA_RESTART != 0;
}

// Layout pushed on the user stack for a handler.
const UContext = extern struct {
    flags: u64,
    link: u64,
    ss_sp: u64,
    ss_flags: u64,
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
    info: [128]u8,
    fpu: [512]u8,
};

fn killWith(p: *proc.Process, sig: u32) noreturn {
    proc.exitProcess(p, sig & 0x7f);
}

/// Called right before returning to user mode.
pub fn deliver(frame: *idt.TrapFrame) void {
    const p = proc.currentOrNull() orelse return;
    p.thread.interrupted = false;
    while (nextPending(p)) |sig| {
        p.sig.pending &= ~bit(sig);
        const a = p.sig.actions[sig];
        if (a.handler == SIG_IGN and sig != SIGKILL) continue;
        if (a.handler == SIG_DFL or sig == SIGKILL) {
            switch (defaultAction(sig)) {
                .ignore, .cont, .stop => continue,
                .term => killWith(p, sig),
            }
        }
        setupFrame(p, frame, sig, a) catch killWith(p, SIGSEGV);
        if (a.flags & SA_RESETHAND != 0) p.sig.actions[sig] = .{};
        return;
    }
}

fn setupFrame(p: *proc.Process, frame: *idt.TrapFrame, sig: u32, a: Action) !void {
    var sp = frame.rsp - 128; // skip red zone
    sp -= @sizeOf(SigFrame);
    sp &= ~@as(u64, 15);
    sp -= 8; // as if `call`ed: (rsp + 8) % 16 == 0
    var sf = std.mem.zeroes(SigFrame);
    sf.restorer = a.restorer;
    sf.uc = .{
        .flags = 0, .link = 0, .ss_sp = 0, .ss_flags = 2, .ss_size = 0,
        .r8 = frame.r8, .r9 = frame.r9, .r10 = frame.r10, .r11 = frame.r11,
        .r12 = frame.r12, .r13 = frame.r13, .r14 = frame.r14, .r15 = frame.r15,
        .rdi = frame.rdi, .rsi = frame.rsi, .rbp = frame.rbp, .rbx = frame.rbx,
        .rdx = frame.rdx, .rax = frame.rax, .rcx = frame.rcx, .rsp = frame.rsp,
        .rip = frame.rip, .eflags = frame.rflags, .csgsfs = 0x23,
        .err = 0, .trapno = 0, .oldmask = p.sig.blocked, .cr2 = 0,
        .fpstate = 0, .reserved = [_]u64{0} ** 8, .sigmask = p.sig.saved_mask orelse p.sig.blocked,
    };
    p.sig.saved_mask = null;
    std.mem.writeInt(i32, sf.info[0..4], @intCast(sig), .little);
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
    p.sig.blocked = newmask & ~(bit(SIGKILL) | bit(SIGSTOP));
    frame.rsp = sp;
    frame.rip = a.handler;
    frame.rdi = sig;
    frame.rsi = sp + @offsetOf(SigFrame, "info");
    frame.rdx = sp + @offsetOf(SigFrame, "uc");
    frame.rax = 0;
    frame.rflags &= ~@as(u64, 0x400); // clear DF
}

pub fn sigreturn(frame: *idt.TrapFrame) void {
    const p = proc.current();
    const base = frame.rsp - 8;
    const sf = proc.readUser(SigFrame, base) catch killWith(p, SIGSEGV);
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
    p.sig.blocked = u.sigmask & ~(bit(SIGKILL) | bit(SIGSTOP));
    p.thread.fpu = sf.fpu;
    p.thread.fpu[24] = 0x80; // MXCSR sanity: keep default masks
    p.thread.fpu[25] = 0x1F;
    p.thread.fpu[26] = 0;
    p.thread.fpu[27] = 0;
    asm volatile ("fxrstor64 (%[b])"
        :
        : [b] "r" (&p.thread.fpu),
        : "memory"
    );
}

fn returnToUser(frame: *idt.TrapFrame) void {
    deliver(frame);
}

pub fn init() void {
    idt.return_to_user_hook = returnToUser;
}
