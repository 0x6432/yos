//! Processes: address-space bookkeeping (VMAs), user memory access, exec,
//! exit and the process table.
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const idt = @import("arch/idt.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const sched = @import("sched.zig");
const elf = @import("elf.zig");
const log = @import("log.zig");
const time = @import("time.zig");
const vfs = @import("vfs.zig");
const signal = @import("signal.zig");

const alloc = heap.allocator;
pub const PAGE: u64 = 4096;

pub const PROT_READ = 1;
pub const PROT_WRITE = 2;
pub const PROT_EXEC = 4;

pub const STACK_TOP: u64 = 0x0000_7FFF_FFFF_F000;
pub const STACK_SIZE: u64 = 8 * 1024 * 1024;
pub const MMAP_BASE: u64 = 0x0000_2000_0000_0000;

pub const Vma = struct {
    start: u64,
    end: u64,
    prot: u32,
    kind: enum { anon, stack, heap, image } = .anon,
};

pub const MAX_FDS = 256;

/// Number of copy-on-write faults resolved (statistics).
pub var cow_faults: u64 = 0;

pub const Process = struct {
    pid: i32,
    ppid: i32 = 0,
    pgid: i32 = 0,
    sid: i32 = 0,
    parent: ?*Process = null,
    thread: *sched.Thread = undefined,
    space: vmm.AddressSpace,
    vmas: std.ArrayList(Vma) = .empty,
    brk_start: u64 = 0,
    brk: u64 = 0,
    zombie: bool = false,
    exit_status: u32 = 0, // wait status encoding
    child_wait: sched.WaitQueue = .{},
    fds: [MAX_FDS]?*vfs.File = [_]?*vfs.File{null} ** MAX_FDS,
    cloexec: std.StaticBitSet(MAX_FDS) = std.StaticBitSet(MAX_FDS).initEmpty(),
    cwd: *vfs.Node = undefined,
    umask: u32 = 0o022,
    sig: signal.State = .{},
    name: [16]u8 = [_]u8{0} ** 16,
    utime_ticks: u64 = 0,
    start_tick: u64 = 0,
    reaped_children_ticks: u64 = 0,
    // job control / wait reporting
    stopped: bool = false,
    stop_sig: u32 = 0,
    wait_event: enum { none, stopped, continued } = .none,
    /// reaped by the kernel instead of the parent (SIGCHLD ignored)
    autoreap: bool = false,
    // ITIMER_REAL
    alarm_ns: u64 = 0,
    alarm_interval_ns: u64 = 0,

    // ---------------- VMAs ----------------
    pub fn findVma(self: *Process, addr: u64) ?*Vma {
        for (self.vmas.items) |*v| if (addr >= v.start and addr < v.end) return v;
        return null;
    }

    pub fn addVma(self: *Process, v: Vma) !void {
        // keep sorted by start
        var i: usize = 0;
        while (i < self.vmas.items.len and self.vmas.items[i].start < v.start) i += 1;
        try self.vmas.insert(alloc, i, v);
    }

    fn pteFlags(prot: u32) u64 {
        var f: u64 = vmm.U;
        if (prot & PROT_WRITE != 0) f |= vmm.W;
        if (prot & PROT_EXEC == 0) f |= vmm.NX;
        return f;
    }

    /// Ensure the page containing addr is present; returns its physical frame.
    pub fn populate(self: *Process, addr: u64) ?u64 {
        const page = addr & ~(PAGE - 1);
        if (self.space.translate(page)) |p| return p;
        const v = self.findVma(page) orelse return null;
        const phys = pmm.allocPage() orelse return null;
        self.space.map(page, phys, pteFlags(v.prot)) catch {
            pmm.freePage(phys);
            return null;
        };
        return phys;
    }

    /// Resolve a write to a copy-on-write page. Returns false if `addr`
    /// is not a COW page or memory ran out.
    pub fn breakCow(self: *Process, addr: u64) bool {
        const page = addr & ~(PAGE - 1);
        const pte = self.space.walk(page, false) orelse return false;
        if (pte.* & vmm.P == 0 or pte.* & vmm.COW == 0) return false;
        const v = self.findVma(page) orelse return false;
        if (v.prot & PROT_WRITE == 0) return false;
        const old = pte.* & vmm.ADDR_MASK;
        const flags = (pte.* & ~vmm.ADDR_MASK & ~vmm.COW) | vmm.W;
        if (pmm.pageRefs(old) == 1) {
            // last user of the frame: just take it back
            pte.* = old | flags;
        } else {
            const new = pmm.allocPages(0) orelse return false;
            @memcpy(pmm.ptr(*[4096]u8, new), pmm.ptr(*const [4096]u8, old));
            pte.* = new | flags;
            pmm.pageUnref(old);
        }
        cpu.invlpg(page);
        cow_faults += 1;
        return true;
    }

    /// Remove [start,end) from the VMA list and unmap pages.
    pub fn unmapRange(self: *Process, start: u64, end: u64) !void {
        var i: usize = 0;
        while (i < self.vmas.items.len) {
            const v = self.vmas.items[i];
            if (v.end <= start or v.start >= end) {
                i += 1;
                continue;
            }
            const cs = @max(v.start, start);
            const ce = @min(v.end, end);
            var a = cs;
            while (a < ce) : (a += PAGE) {
                if (self.space.unmap(a)) |p| pmm.pageUnref(p);
            }
            if (cs == v.start and ce == v.end) {
                _ = self.vmas.orderedRemove(i);
                continue;
            } else if (cs == v.start) {
                self.vmas.items[i].start = ce;
            } else if (ce == v.end) {
                self.vmas.items[i].end = cs;
            } else {
                self.vmas.items[i].end = cs;
                var tail = v;
                tail.start = ce;
                try self.vmas.insert(alloc, i + 1, tail);
                i += 1;
            }
            i += 1;
        }
    }

    pub fn protectRange(self: *Process, start: u64, end: u64, prot: u32) !void {
        // split so that [start,end) is covered by whole VMAs, then update
        var i: usize = 0;
        while (i < self.vmas.items.len) : (i += 1) {
            const v = self.vmas.items[i];
            if (v.end <= start or v.start >= end) continue;
            if (v.start < start) {
                self.vmas.items[i].end = start;
                var b = v;
                b.start = start;
                try self.vmas.insert(alloc, i + 1, b);
                continue;
            }
            if (v.end > end) {
                self.vmas.items[i].end = end;
                var b = v;
                b.start = end;
                try self.vmas.insert(alloc, i + 1, b);
            }
            self.vmas.items[i].prot = prot;
            var a = self.vmas.items[i].start;
            while (a < self.vmas.items[i].end) : (a += PAGE) {
                if (self.space.walk(a, false)) |pte| {
                    if (pte.* & vmm.P != 0) {
                        var nf = pteFlags(prot);
                        // shared COW frames stay read-only until written
                        if (pte.* & vmm.COW != 0 and nf & vmm.W != 0) nf = (nf & ~vmm.W) | vmm.COW;
                        pte.* = (pte.* & vmm.ADDR_MASK) | nf | vmm.P;
                        cpu.invlpg(a);
                    }
                }
            }
        }
    }

    pub fn isFree(self: *Process, start: u64, end: u64) bool {
        for (self.vmas.items) |v| if (v.start < end and start < v.end) return false;
        return true;
    }

    /// First-fit search for a free range of `len` bytes.
    pub fn findGap(self: *Process, len: u64) ?u64 {
        var cand: u64 = MMAP_BASE;
        for (self.vmas.items) |v| {
            if (v.end <= cand) continue;
            if (v.start >= cand + len) break;
            cand = std.mem.alignForward(u64, v.end, PAGE);
        }
        if (cand + len > STACK_TOP - STACK_SIZE) return null;
        return cand;
    }

    // ---------------- user memory access ----------------
    pub fn checkRange(self: *Process, addr: u64, len: usize, write: bool) bool {
        if (len == 0) return true;
        if (addr >= vmm.USER_TOP or addr + len > vmm.USER_TOP or addr + len < addr) return false;
        var a = addr & ~(PAGE - 1);
        while (a < addr + len) : (a += PAGE) {
            const v = self.findVma(a) orelse return false;
            if (write and v.prot & PROT_WRITE == 0) return false;
            if (self.populate(a) == null) return false;
            if (write) {
                if (self.space.pteFlags(a)) |fl| if (fl & vmm.COW != 0 and !self.breakCow(a)) return false;
            }
        }
        return true;
    }
};

// ---------------- process table ----------------
pub var procs: std.ArrayList(*Process) = .empty;
var next_pid: i32 = 1;

pub fn current() *Process {
    return @ptrCast(@alignCast(sched.current().proc.?));
}
pub fn currentOrNull() ?*Process {
    return @ptrCast(@alignCast(sched.current().proc));
}

pub fn byPid(pid: i32) ?*Process {
    for (procs.items) |p| if (p.pid == pid) return p;
    return null;
}

pub fn newProcess() !*Process {
    return newProcessWith(try vmm.AddressSpace.createUser());
}

pub fn newProcessWith(space: vmm.AddressSpace) !*Process {
    const p = try alloc.create(Process);
    p.* = .{ .pid = next_pid, .space = space };
    next_pid += 1;
    p.start_tick = time.now();
    try procs.append(alloc, p);
    return p;
}

pub fn setName(p: *Process, path: []const u8) void {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const l = @min(base.len, 15);
    @memset(&p.name, 0);
    @memcpy(p.name[0..l], base[0..l]);
}

// ---------------- copy helpers (current process) ----------------
pub const Fault = error{Fault};

pub fn copyFromUser(dst: []u8, src: u64) Fault!void {
    if (!current().checkRange(src, dst.len, false)) return error.Fault;
    @memcpy(dst, @as([*]const u8, @ptrFromInt(src))[0..dst.len]);
}
pub fn copyToUser(dst: u64, src: []const u8) Fault!void {
    if (!current().checkRange(dst, src.len, true)) return error.Fault;
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..src.len], src);
}
pub fn readUser(comptime T: type, addr: u64) Fault!T {
    var v: T = undefined;
    try copyFromUser(std.mem.asBytes(&v), addr);
    return v;
}
pub fn writeUser(comptime T: type, addr: u64, v: T) Fault!void {
    try copyToUser(addr, std.mem.asBytes(&v));
}
pub fn userSlice(addr: u64, len: usize, write: bool) Fault![]u8 {
    if (len == 0) return &.{};
    if (!current().checkRange(addr, len, write)) return error.Fault;
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}
/// Copy a NUL-terminated user string into buf.
pub fn readString(addr: u64, buf: []u8) ![]u8 {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const c = try readUser(u8, addr + i);
        if (c == 0) return buf[0..i];
        buf[i] = c;
    }
    return error.NameTooLong;
}

// ---------------- page faults ----------------
fn onException(frame: *idt.TrapFrame) bool {
    const p = currentOrNull() orelse return false;
    if (frame.vector == 14) {
        const addr = cpu.readCr2();
        const present = frame.error_code & 1 != 0;
        const write = frame.error_code & 2 != 0;
        if (present and write and addr < vmm.USER_TOP and p.breakCow(addr)) return true;
        if (!present and addr < vmm.USER_TOP) {
            if (p.findVma(addr)) |v| {
                const ok_prot = if (write) v.prot & PROT_WRITE != 0 else true;
                if (ok_prot and p.populate(addr) != null) return true;
            }
        }
        if (!frame.fromUser()) return false;
        if (debug_faults) log.print("[yos] pid {d} ({s}): segfault at 0x{x} rip=0x{x} err={x}\n", .{ p.pid, std.mem.sliceTo(&p.name, 0), addr, frame.rip, frame.error_code });
        const code = if (present) signal.SEGV_ACCERR else signal.SEGV_MAPERR;
        signal.forceSignal(p, signal.SigInfo.fault(signal.SIGSEGV, code, addr));
        return true;
    }
    if (!frame.fromUser()) return false;
    const sig: u32, const code: i32 = switch (frame.vector) {
        0 => .{ signal.SIGFPE, 1 }, // FPE_INTDIV
        16, 19 => .{ signal.SIGFPE, 0 },
        6 => .{ signal.SIGILL, 2 }, // ILL_ILLOPN
        1, 3 => .{ signal.SIGTRAP, 1 }, // TRAP_BRKPT
        17 => .{ signal.SIGBUS, 1 },
        else => .{ signal.SIGSEGV, signal.SI_KERNEL },
    };
    if (debug_faults) log.print("[yos] pid {d} ({s}): exception {d} at rip=0x{x}\n", .{ p.pid, std.mem.sliceTo(&p.name, 0), frame.vector, frame.rip });
    signal.forceSignal(p, signal.SigInfo.fault(sig, code, frame.rip));
    return true;
}

/// Log user faults to the console (signals are delivered either way).
pub var debug_faults = false;

pub fn init() void {
    idt.exception_hook = onException;
}

// ---------------- exec ----------------
const AT_NULL = 0;
const AT_PHDR = 3;
const AT_PHENT = 4;
const AT_PHNUM = 5;
const AT_PAGESZ = 6;
const AT_BASE = 7;
const AT_FLAGS = 8;
const AT_ENTRY = 9;
const AT_UID = 11;
const AT_EUID = 12;
const AT_GID = 13;
const AT_EGID = 14;
const AT_HWCAP = 16;
const AT_CLKTCK = 17;
const AT_SECURE = 23;
const AT_RANDOM = 25;
const AT_EXECFN = 31;

/// Builds a fresh image in `space`, writing via the HHDM.
const Builder = struct {
    p: *Process,
    space: vmm.AddressSpace,
    vmas: *std.ArrayList(Vma),

    fn findVma(self: *Builder, addr: u64) ?*Vma {
        for (self.vmas.items) |*v| if (addr >= v.start and addr < v.end) return v;
        return null;
    }

    fn pageFor(self: *Builder, addr: u64) !u64 {
        const page = addr & ~(PAGE - 1);
        if (self.space.translate(page)) |ph| return ph;
        const v = self.findVma(page) orelse return error.Fault;
        const phys = pmm.allocPage() orelse return error.OutOfMemory;
        try self.space.map(page, phys, Process.pteFlags(v.prot));
        return phys;
    }

    fn write(self: *Builder, addr: u64, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const a = addr + off;
            const phys = try self.pageFor(a);
            const in_page = @min(bytes.len - off, PAGE - (a & (PAGE - 1)));
            const dst = pmm.ptr([*]u8, phys + (a & (PAGE - 1)));
            @memcpy(dst[0..in_page], bytes[off .. off + in_page]);
            off += in_page;
        }
    }

    pub fn segment(self: *Builder, seg: elf.Segment) elf.Error!void {
        const start = seg.vaddr & ~(PAGE - 1);
        const end = std.mem.alignForward(u64, seg.vaddr + seg.memsz, PAGE);
        var prot: u32 = 0;
        if (seg.flags & elf.PF_R != 0) prot |= PROT_READ;
        if (seg.flags & elf.PF_W != 0) prot |= PROT_WRITE;
        if (seg.flags & elf.PF_X != 0) prot |= PROT_EXEC;
        // segments may share a page; merge permissions
        var a = start;
        while (a < end) {
            if (self.findVma(a)) |v| {
                v.prot |= prot;
                a = v.end;
                continue;
            }
            var b = a + PAGE;
            while (b < end and self.findVma(b) == null) b += PAGE;
            var i: usize = 0;
            while (i < self.vmas.items.len and self.vmas.items[i].start < a) i += 1;
            self.vmas.insert(alloc, i, .{ .start = a, .end = b, .prot = prot, .kind = .image }) catch return error.OutOfMemory;
            a = b;
        }
        self.write(seg.vaddr, seg.data) catch return error.OutOfMemory;
        // make sure bss pages exist (they are zero-filled on allocation)
        _ = &a;
    }
};

pub const ExecError = error{ NotFound, NotElf, Unsupported, OutOfMemory, Fault, TooBig };

/// Replace the image of `p` with the ELF `data`. Builds the new address space
/// and fills `frame` with the user entry state. On error the old image is intact.
pub fn execImage(p: *Process, data: []const u8, argv: []const []const u8, envp: []const []const u8, frame: *idt.TrapFrame, path: []const u8) ExecError!void {
    const space = try vmm.AddressSpace.createUser();
    var vmas: std.ArrayList(Vma) = .empty;
    var b = Builder{ .p = p, .space = space, .vmas = &vmas };
    const info = elf.load(data, &b) catch |e| {
        vmas.deinit(alloc);
        space.destroy();
        return switch (e) {
            error.NotElf => error.NotElf,
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
            error.Fault => error.Fault,
        };
    };
    errdefer {
        vmas.deinit(alloc);
        space.destroy();
    }
    // heap + stack VMAs
    vmas.append(alloc, .{ .start = STACK_TOP - STACK_SIZE, .end = STACK_TOP, .prot = PROT_READ | PROT_WRITE, .kind = .stack }) catch return error.OutOfMemory;

    // ---- build the initial stack ----
    var sp: u64 = STACK_TOP;
    const pushBytes = struct {
        fn f(bb: *Builder, spp: *u64, bytes: []const u8) !u64 {
            spp.* -= bytes.len;
            try bb.write(spp.*, bytes);
            return spp.*;
        }
    }.f;
    const zero = [_]u8{0};
    const execfn = pushBytes(&b, &sp, &zero) catch return error.OutOfMemory;
    _ = execfn;
    sp -= path.len;
    b.write(sp, path) catch return error.OutOfMemory;
    const execfn_addr = sp;
    _ = pushBytes(&b, &sp, &zero) catch return error.OutOfMemory;

    var arg_ptrs = std.ArrayList(u64).empty;
    defer arg_ptrs.deinit(alloc);
    var env_ptrs = std.ArrayList(u64).empty;
    defer env_ptrs.deinit(alloc);
    var total: usize = 0;
    for (envp) |e| total += e.len + 1;
    for (argv) |a| total += a.len + 1;
    if (total > 256 * 1024) return error.TooBig;
    var i: usize = envp.len;
    while (i > 0) {
        i -= 1;
        _ = pushBytes(&b, &sp, &zero) catch return error.OutOfMemory;
        const a = pushBytes(&b, &sp, envp[i]) catch return error.OutOfMemory;
        env_ptrs.insert(alloc, 0, a) catch return error.OutOfMemory;
    }
    i = argv.len;
    while (i > 0) {
        i -= 1;
        _ = pushBytes(&b, &sp, &zero) catch return error.OutOfMemory;
        const a = pushBytes(&b, &sp, argv[i]) catch return error.OutOfMemory;
        arg_ptrs.insert(alloc, 0, a) catch return error.OutOfMemory;
    }
    var rnd: [16]u8 = undefined;
    var seed = cpu.rdtsc();
    for (&rnd) |*r| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        r.* = @truncate(seed >> 33);
    }
    const rnd_addr = pushBytes(&b, &sp, &rnd) catch return error.OutOfMemory;
    sp &= ~@as(u64, 15);

    const auxv = [_][2]u64{
        .{ AT_PHDR, info.phdr },  .{ AT_PHENT, info.phent },   .{ AT_PHNUM, info.phnum },
        .{ AT_PAGESZ, PAGE },     .{ AT_BASE, 0 },             .{ AT_FLAGS, 0 },
        .{ AT_ENTRY, info.entry }, .{ AT_UID, 0 },             .{ AT_EUID, 0 },
        .{ AT_GID, 0 },           .{ AT_EGID, 0 },             .{ AT_HWCAP, 0x178bfbff },
        .{ AT_CLKTCK, 100 },      .{ AT_SECURE, 0 },           .{ AT_RANDOM, rnd_addr },
        .{ AT_EXECFN, execfn_addr }, .{ AT_NULL, 0 },
    };
    const nwords = 1 + arg_ptrs.items.len + 1 + env_ptrs.items.len + 1 + auxv.len * 2;
    sp -= nwords * 8;
    sp &= ~@as(u64, 15);
    var w = sp;
    const put = struct {
        fn f(bb: *Builder, ww: *u64, v: u64) !void {
            try bb.write(ww.*, std.mem.asBytes(&v));
            ww.* += 8;
        }
    }.f;
    put(&b, &w, arg_ptrs.items.len) catch return error.OutOfMemory;
    for (arg_ptrs.items) |a| put(&b, &w, a) catch return error.OutOfMemory;
    put(&b, &w, 0) catch return error.OutOfMemory;
    for (env_ptrs.items) |a| put(&b, &w, a) catch return error.OutOfMemory;
    put(&b, &w, 0) catch return error.OutOfMemory;
    for (auxv) |kv| {
        put(&b, &w, kv[0]) catch return error.OutOfMemory;
        put(&b, &w, kv[1]) catch return error.OutOfMemory;
    }

    // ---- commit: swap in the new image ----
    const old_space = p.space;
    var old_vmas = p.vmas;
    p.space = space;
    p.vmas = vmas;
    p.brk_start = info.brk;
    p.brk = info.brk;
    p.vmas.append(alloc, .{ .start = info.brk, .end = info.brk, .prot = PROT_READ | PROT_WRITE, .kind = .heap }) catch {};
    p.thread.space = space;
    p.thread.fs_base = 0;
    p.thread.fpu = sched.fpu_template;
    const e = cpu.saveDisable();
    if (sched.current() == p.thread) {
        space.activate();
        cpu.wrmsr(cpu.MSR_FS_BASE, 0);
    }
    cpu.restore(e);
    old_space.destroy();
    old_vmas.deinit(alloc);
    setName(p, path);

    frame.* = std.mem.zeroes(idt.TrapFrame);
    frame.rip = info.entry;
    frame.rsp = sp;
    frame.cs = 0x23;
    frame.ss = 0x1b;
    frame.rflags = 0x202;
}

// ---------------- exit / wait ----------------
pub fn exitProcess(p: *Process, status: u32) noreturn {
    vfs.closeAll(p);
    p.vmas.deinit(alloc);
    p.vmas = .empty;
    p.space.clearUser();
    p.exit_status = status;
    p.alarm_ns = 0;
    // reparent children to init (pid 1)
    const init_p = byPid(1);
    for (procs.items) |c| {
        if (c.parent == p) {
            c.parent = init_p;
            c.ppid = 1;
            if (c.zombie) if (init_p) |ip| ip.child_wait.wakeAll();
        }
    }
    p.zombie = true;
    p.stopped = false;
    if (p.parent) |par| {
        const a = par.sig.actions[signal.SIGCHLD];
        if (a.handler == signal.SIG_IGN or a.flags & signal.SA_NOCLDWAIT != 0) p.autoreap = true;
        const killed = status & 0x7f != 0;
        signal.notifyParent(p, if (killed) signal.CLD_KILLED else signal.CLD_EXITED, @intCast(if (killed) status & 0x7f else (status >> 8) & 0xff));
    } else p.autoreap = true;
    if (p.pid == 1) {
        log.print("\n[yos] init exited with status 0x{x}\n", .{status});
        @import("acpi.zig").poweroff();
    }
    sched.exitCurrent();
}

/// Free a zombie's remaining resources.
pub fn reap(p: *Process) void {
    for (procs.items, 0..) |x, i| if (x == p) {
        _ = procs.swapRemove(i);
        break;
    };
    p.space.destroy();
    sched.freeThread(p.thread);
    alloc.destroy(p);
}

/// Reap zombies nobody will wait for (parent ignores SIGCHLD).
pub fn reapOrphans() void {
    var i: usize = 0;
    while (i < procs.items.len) {
        const p = procs.items[i];
        if (p.zombie and p.autoreap and p.thread.state == .zombie and p.thread.kstack_phys == 0) {
            reap(p);
            continue;
        }
        i += 1;
    }
}
