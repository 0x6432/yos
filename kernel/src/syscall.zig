//! Linux x86_64 system call ABI.
const std = @import("std");
const cpu = @import("arch/cpu.zig");
const idt = @import("arch/idt.zig");
const gdt = @import("arch/gdt.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const sched = @import("sched.zig");
const proc = @import("proc.zig");
const vfs = @import("vfs.zig");
const signal = @import("signal.zig");
const tty = @import("dev/tty.zig");
const time = @import("time.zig");
const log = @import("log.zig");
const acpi = @import("acpi.zig");
const E = @import("errno.zig");

const alloc = heap.allocator;
const Process = proc.Process;
const File = vfs.File;
const Frame = idt.TrapFrame;

extern fn syscall_entry() callconv(.c) void;

pub fn init() void {
    cpu.wrmsr(cpu.MSR_EFER, cpu.rdmsr(cpu.MSR_EFER) | 1); // SCE
    cpu.wrmsr(cpu.MSR_STAR, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    cpu.wrmsr(cpu.MSR_LSTAR, @intFromPtr(&syscall_entry));
    cpu.wrmsr(cpu.MSR_SFMASK, 0x47700); // IF, TF, DF, AC, NT
    log.info("syscall: entry installed (Linux x86_64 ABI)", .{});
}

pub var trace = false;
var warned: std.StaticBitSet(512) = std.StaticBitSet(512).initEmpty();

export fn syscall_dispatch(frame: *Frame) callconv(.c) void {
    const nr = frame.rax;
    const p = proc.current();
    const r = handle(nr, frame);
    if (trace) log.print("[sys] pid {d} {d}({x}, {x}, {x}) = {d}\n", .{ p.pid, nr, frame.rdi, frame.rsi, frame.rdx, r });
    frame.rax = @bitCast(r);
    if (r == -E.EINTR and signal.restartable(p)) {
        frame.rip -= 2;
        frame.rax = nr;
    }
    signal.deliver(frame);
}

fn handle(nr: u64, f: *Frame) isize {
    const a0 = f.rdi;
    const a1 = f.rsi;
    const a2 = f.rdx;
    const a3 = f.r10;
    const a4 = f.r8;
    const a5 = f.r9;
    return switch (nr) {
        0 => sysRead(a0, a1, a2),
        1 => sysWrite(a0, a1, a2),
        2 => sysOpenat(AT_FDCWD, a0, a1, a2),
        3 => sysClose(a0),
        4 => sysStatat(AT_FDCWD, a0, a1, 0),
        5 => sysFstat(a0, a1),
        6 => sysStatat(AT_FDCWD, a0, a1, AT_SYMLINK_NOFOLLOW),
        7 => sysPoll(a0, a1, @bitCast(a2)),
        8 => sysLseek(a0, @bitCast(a1), a2),
        9 => sysMmap(a0, a1, a2, a3, a4, a5),
        10 => sysMprotect(a0, a1, a2),
        11 => sysMunmap(a0, a1),
        12 => sysBrk(a0),
        13 => sysSigaction(a0, a1, a2),
        14 => sysSigprocmask(a0, a1, a2),
        15 => blk: {
            signal.sigreturn(f);
            break :blk @bitCast(f.rax);
        },
        16 => sysIoctl(a0, a1, a2),
        17 => sysPread(a0, a1, a2, a3),
        18 => sysPwrite(a0, a1, a2, a3),
        19 => sysReadv(a0, a1, a2),
        20 => sysWritev(a0, a1, a2),
        21 => sysFaccessat(AT_FDCWD, a0, a1),
        22 => sysPipe2(a0, 0),
        23 => sysSelect(a0, a1, a2, a3, if (a4 == 0) null else timevalMs(a4)),
        24 => blk: {
            sched.yield();
            break :blk 0;
        },
        25 => -E.ENOMEM, // mremap
        26, 27 => 0, // msync, mincore
        28 => 0, // madvise
        32 => sysDup(a0),
        33 => sysDup3(a0, a1, 0, true),
        34 => sysPause(),
        35 => sysNanosleep(a0, a1),
        37 => 0, // alarm
        39 => proc.current().pid,
        41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55 => -E.ENOSYS, // sockets
        56 => sysClone(f, a0, a1, a2, a3, a4),
        57, 58 => doFork(f, 0, 0, 0),
        59 => sysExecve(f, a0, a1, a2),
        60 => proc.exitProcess(proc.current(), (@as(u32, @truncate(a0)) & 0xff) << 8),
        61 => sysWait4(@bitCast(@as(u32, @truncate(a0))), a1, a2),
        62 => sysKill(@truncate(@as(i64, @bitCast(a0))), a1),
        63 => sysUname(a0),
        72 => sysFcntl(a0, a1, a2),
        73, 74, 75 => 0, // flock, fsync, fdatasync
        76 => sysTruncate(a0, a1),
        77 => sysFtruncate(a0, a1),
        78 => -E.ENOSYS,
        79 => sysGetcwd(a0, a1),
        80 => sysChdir(a0),
        81 => sysFchdir(a0),
        82 => sysRenameat(AT_FDCWD, a0, AT_FDCWD, a1),
        83 => sysMkdirat(AT_FDCWD, a0, a1),
        84 => sysUnlinkat(AT_FDCWD, a0, AT_REMOVEDIR),
        85 => sysOpenat(AT_FDCWD, a0, vfs.O_CREAT | vfs.O_WRONLY | vfs.O_TRUNC, a1),
        86 => -E.EPERM, // link
        87 => sysUnlinkat(AT_FDCWD, a0, 0),
        88 => sysSymlinkat(a0, AT_FDCWD, a1),
        89 => sysReadlinkat(AT_FDCWD, a0, a1, a2),
        90 => sysFchmodat(AT_FDCWD, a0, a1),
        91 => sysFchmod(a0, a1),
        92, 93, 94 => 0, // chown family
        95 => blk: {
            const p = proc.current();
            const old = p.umask;
            p.umask = @truncate(a0 & 0o777);
            break :blk old;
        },
        96 => sysGettimeofday(a0),
        97 => sysPrlimit(0, a0, 0, a1),
        98 => sysGetrusage(a1),
        99 => sysSysinfo(a0),
        100 => sysTimes(a0),
        102, 104, 107, 108 => 0, // getuid/getgid/geteuid/getegid
        105, 106, 113, 114, 117, 119, 116 => 0, // set*id, setgroups
        115 => 0, // getgroups -> none
        118, 120 => sysGetres(a0, a1, a2),
        109 => sysSetpgid(@truncate(@as(i64, @bitCast(a0))), @truncate(@as(i64, @bitCast(a1)))),
        110 => proc.current().ppid,
        111 => proc.current().pgid,
        112 => sysSetsid(),
        121 => sysGetpgid(@truncate(@as(i64, @bitCast(a0)))),
        124 => sysGetsid(@truncate(@as(i64, @bitCast(a0)))),
        127 => sysSigpending(a0),
        130 => sysSigsuspend(a0),
        131 => sysSigaltstack(a1),
        132 => 0, // utime
        137, 138 => sysStatfs(a1),
        157 => 0, // prctl
        158 => sysArchPrctl(a0, a1),
        160 => 0, // setrlimit
        169 => sysReboot(a0, a1, a2),
        186 => proc.current().pid,
        200 => sysKill(@truncate(@as(i64, @bitCast(a0))), a1),
        201 => blk: {
            const t = vfs.now();
            if (a0 != 0) proc.writeUser(i64, a0, t) catch break :blk -E.EFAULT;
            break :blk t;
        },
        202 => sysFutex(a0, a1, a2),
        204 => -E.ENOSYS, // sched_getaffinity
        217 => sysGetdents64(a0, a1, a2),
        218 => blk: {
            sched.current.clear_child_tid = a0;
            break :blk proc.current().pid;
        },
        228 => sysClockGettime(a0, a1),
        229 => blk: {
            if (a1 != 0) proc.writeUser([2]i64, a1, .{ 0, 1 }) catch break :blk -E.EFAULT;
            break :blk 0;
        },
        230 => sysNanosleep(a2, a3),
        231 => proc.exitProcess(proc.current(), (@as(u32, @truncate(a0)) & 0xff) << 8),
        234 => sysKill(@truncate(@as(i64, @bitCast(a1))), a2),
        257 => sysOpenat(a0, a1, a2, a3),
        258 => sysMkdirat(a0, a1, a2),
        262 => sysStatat(a0, a1, a2, a3),
        263 => sysUnlinkat(a0, a1, a2),
        264, 316 => sysRenameat(a0, a1, a2, a3),
        265 => -E.EPERM,
        266 => sysSymlinkat(a0, a1, a2),
        267 => sysReadlinkat(a0, a1, a2, a3),
        268 => sysFchmodat(a0, a1, a2),
        269, 439 => sysFaccessat(a0, a1, a2),
        270 => sysPselect(a0, a1, a2, a3, a4),
        271 => sysPpoll(a0, a1, a2),
        273 => 0, // set_robust_list
        280 => 0, // utimensat
        292 => sysDup3(a0, a1, a2, false),
        293 => sysPipe2(a0, a1),
        302 => sysPrlimit(a0, a1, a2, a3),
        318 => sysGetrandom(a0, a1),
        332 => sysStatx(a0, a1, a2, a4),
        334 => -E.ENOSYS, // rseq
        435 => -E.ENOSYS, // clone3 -> libc falls back to clone
        else => blk: {
            if (nr < 512 and !warned.isSet(nr)) {
                warned.set(nr);
                log.print("[yos] unimplemented syscall {d} (pid {d})\n", .{ nr, proc.current().pid });
            }
            break :blk -E.ENOSYS;
        },
    };
}

// ------------------------------------------------------------------
// helpers
// ------------------------------------------------------------------
const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
const AT_SYMLINK_NOFOLLOW: u64 = 0x100;
const AT_REMOVEDIR: u64 = 0x200;
const AT_EMPTY_PATH: u64 = 0x1000;

fn getFile(fd: u64) ?*File {
    if (fd >= proc.MAX_FDS) return null;
    return proc.current().fds[fd];
}

fn allocFd(p: *Process, min: usize) ?usize {
    var i = min;
    while (i < proc.MAX_FDS) : (i += 1) if (p.fds[i] == null) return i;
    return null;
}

pub fn installFd(p: *Process, f: *File, cloexec: bool) isize {
    const fd = allocFd(p, 0) orelse {
        vfs.release(f);
        return -E.EMFILE;
    };
    p.fds[fd] = f;
    p.cloexec.setValue(fd, cloexec);
    return @intCast(fd);
}

var path_buf_pool: [2][4096]u8 = undefined;

fn readPath(addr: u64, buf: []u8) ![]u8 {
    if (addr == 0) return error.Fault;
    const s = try proc.readString(addr, buf);
    return s;
}

fn startDir(dirfd: u64, path: []const u8) !*vfs.Node {
    if (path.len > 0 and path[0] == '/') return vfs.root;
    if (dirfd == AT_FDCWD) return proc.current().cwd;
    const f = getFile(dirfd) orelse return error.BadFd;
    const n = f.node orelse return error.NotDir;
    if (n.kind != .dir) return error.NotDir;
    return n;
}

fn err(e: anyerror) isize {
    return switch (e) {
        error.BadFd => -E.EBADF,
        error.Fault => -E.EFAULT,
        error.NameTooLong => -E.ENAMETOOLONG,
        else => vfs.errno(e),
    };
}

// ------------------------------------------------------------------
// file I/O
// ------------------------------------------------------------------
fn sysRead(fd: u64, buf: u64, len: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const b = proc.userSlice(buf, len, true) catch return -E.EFAULT;
    return vfs.read(f, b);
}

fn sysWrite(fd: u64, buf: u64, len: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const b = proc.userSlice(buf, len, false) catch return -E.EFAULT;
    return vfs.write(f, b);
}

fn sysPread(fd: u64, buf: u64, len: u64, off: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (f.pipe != null) return -E.ESPIPE;
    const b = proc.userSlice(buf, len, true) catch return -E.EFAULT;
    return vfs.pread(f, b, off);
}

fn sysPwrite(fd: u64, buf: u64, len: u64, off: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (f.pipe != null) return -E.ESPIPE;
    const b = proc.userSlice(buf, len, false) catch return -E.EFAULT;
    const saved = f.off;
    f.off = off;
    const r = vfs.write(f, b);
    f.off = saved;
    return r;
}

const Iovec = extern struct { base: u64, len: u64 };

fn sysReadv(fd: u64, iov: u64, cnt: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (cnt > 1024) return -E.EINVAL;
    var total: isize = 0;
    for (0..cnt) |i| {
        const v = proc.readUser(Iovec, iov + i * 16) catch return -E.EFAULT;
        if (v.len == 0) continue;
        const b = proc.userSlice(v.base, v.len, true) catch return -E.EFAULT;
        const r = vfs.read(f, b);
        if (r < 0) return if (total > 0) total else r;
        total += r;
        if (@as(u64, @intCast(r)) < v.len) break;
    }
    return total;
}

fn sysWritev(fd: u64, iov: u64, cnt: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (cnt > 1024) return -E.EINVAL;
    var total: isize = 0;
    for (0..cnt) |i| {
        const v = proc.readUser(Iovec, iov + i * 16) catch return -E.EFAULT;
        if (v.len == 0) continue;
        const b = proc.userSlice(v.base, v.len, false) catch return -E.EFAULT;
        const r = vfs.write(f, b);
        if (r < 0) return if (total > 0) total else r;
        total += r;
    }
    return total;
}

fn sysOpenat(dirfd: u64, path_addr: u64, flags64: u64, mode: u64) isize {
    var buf: [4096]u8 = undefined;
    const path = readPath(path_addr, &buf) catch |e| return err(e);
    const flags: u32 = @truncate(flags64);
    const p = proc.current();
    const start = startDir(dirfd, path) catch |e| return err(e);
    const follow = flags & vfs.O_NOFOLLOW == 0;
    var node: *vfs.Node = undefined;
    if (vfs.resolve(start, path, follow)) |n| {
        if (flags & vfs.O_CREAT != 0 and flags & vfs.O_EXCL != 0) return -E.EEXIST;
        node = n;
    } else |e| {
        if (e != error.NotFound or flags & vfs.O_CREAT == 0) return err(e);
        const pr = vfs.resolveParent(start, path) catch |e2| return err(e2);
        if (pr.dir.lookup(pr.name)) |existing| {
            // dangling symlink etc.
            _ = existing;
            return -E.ENOENT;
        }
        node = vfs.newNode(.file, @as(u32, @truncate(mode)) & ~p.umask & 0o7777) catch return -E.ENOMEM;
        vfs.addChild(pr.dir, pr.name, node) catch return -E.ENOMEM;
    }
    if (node.kind == .symlink) return -E.ELOOP;
    if (flags & vfs.O_DIRECTORY != 0 and node.kind != .dir) return -E.ENOTDIR;
    const acc = flags & vfs.O_ACCMODE;
    if (node.kind == .dir and (acc == vfs.O_WRONLY or acc == vfs.O_RDWR)) return -E.EISDIR;
    if (node.kind == .file and flags & vfs.O_TRUNC != 0 and acc != 0) node.truncate(0) catch return -E.ENOMEM;
    const f = vfs.openNode(node, flags & ~@as(u32, vfs.O_CREAT | vfs.O_EXCL | vfs.O_TRUNC | vfs.O_CLOEXEC)) catch return -E.ENOMEM;
    return installFd(p, f, flags & vfs.O_CLOEXEC != 0);
}

fn sysClose(fd: u64) isize {
    const p = proc.current();
    if (fd >= proc.MAX_FDS) return -E.EBADF;
    const f = p.fds[fd] orelse return -E.EBADF;
    p.fds[fd] = null;
    p.cloexec.unset(fd);
    vfs.release(f);
    return 0;
}

const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    pad0: u32 = 0,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atime: i64,
    atime_ns: i64 = 0,
    mtime: i64,
    mtime_ns: i64 = 0,
    ctime: i64,
    ctime_ns: i64 = 0,
    unused: [3]i64 = .{ 0, 0, 0 },
};

fn fillStat(n: *vfs.Node) Stat {
    const sz = n.size();
    return .{
        .dev = 1,
        .ino = n.ino,
        .nlink = n.nlink,
        .mode = n.fullMode(),
        .uid = n.uid,
        .gid = n.gid,
        .rdev = n.rdev,
        .size = @intCast(sz),
        .blksize = 4096,
        .blocks = @intCast((sz + 511) / 512),
        .atime = n.mtime,
        .mtime = n.mtime,
        .ctime = n.mtime,
    };
}

fn pipeStat() Stat {
    return .{ .dev = 2, .ino = 1, .nlink = 1, .mode = vfs.S_IFIFO | 0o600, .uid = 0, .gid = 0, .rdev = 0, .size = 0, .blksize = 4096, .blocks = 0, .atime = 0, .mtime = 0, .ctime = 0 };
}

fn sysFstat(fd: u64, st: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const s = if (f.node) |n| fillStat(n) else pipeStat();
    proc.writeUser(Stat, st, s) catch return -E.EFAULT;
    return 0;
}

fn sysStatat(dirfd: u64, path_addr: u64, st: u64, flags: u64) isize {
    var buf: [4096]u8 = undefined;
    const path = readPath(path_addr, &buf) catch |e| return err(e);
    if (path.len == 0 and flags & AT_EMPTY_PATH != 0) {
        if (dirfd == AT_FDCWD) return sysFstatNode(proc.current().cwd, st);
        return sysFstat(dirfd, st);
    }
    const start = startDir(dirfd, path) catch |e| return err(e);
    const n = vfs.resolve(start, path, flags & AT_SYMLINK_NOFOLLOW == 0) catch |e| return err(e);
    return sysFstatNode(n, st);
}

fn sysStatx(dirfd: u64, path_addr: u64, flags: u64, buf: u64) isize {
    var pb: [4096]u8 = undefined;
    const path = readPath(path_addr, &pb) catch |e| return err(e);
    var n: *vfs.Node = undefined;
    var pipe = false;
    if (path.len == 0 and flags & AT_EMPTY_PATH != 0) {
        if (dirfd == AT_FDCWD) n = proc.current().cwd else {
            const f = getFile(dirfd) orelse return -E.EBADF;
            if (f.node) |x| n = x else pipe = true;
        }
    } else {
        const start = startDir(dirfd, path) catch |e| return err(e);
        n = vfs.resolve(start, path, flags & AT_SYMLINK_NOFOLLOW == 0) catch |e| return err(e);
    }
    const st = if (pipe) pipeStat() else fillStat(n);
    var b = [_]u8{0} ** 256;
    std.mem.writeInt(u32, b[0..4], 0x7ff, .little);
    std.mem.writeInt(u32, b[4..8], 4096, .little);
    std.mem.writeInt(u32, b[16..20], @intCast(st.nlink), .little);
    std.mem.writeInt(u16, b[28..30], @truncate(st.mode), .little);
    std.mem.writeInt(u64, b[32..40], st.ino, .little);
    std.mem.writeInt(u64, b[40..48], @intCast(st.size), .little);
    std.mem.writeInt(u64, b[48..56], @intCast(st.blocks), .little);
    inline for (.{ 64, 80, 96, 112 }) |off| std.mem.writeInt(i64, b[off .. off + 8], st.mtime, .little);
    std.mem.writeInt(u32, b[128..132], @intCast(st.rdev >> 8), .little);
    std.mem.writeInt(u32, b[132..136], @intCast(st.rdev & 0xff), .little);
    std.mem.writeInt(u32, b[140..144], 1, .little);
    proc.copyToUser(buf, &b) catch return -E.EFAULT;
    return 0;
}

fn sysFstatNode(n: *vfs.Node, st: u64) isize {
    proc.writeUser(Stat, st, fillStat(n)) catch return -E.EFAULT;
    return 0;
}

fn sysLseek(fd: u64, off: i64, whence: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (f.pipe != null) return -E.ESPIPE;
    const n = f.node.?;
    if (n.kind == .chardev) return 0;
    const base: i64 = switch (whence) {
        0 => 0,
        1 => @intCast(f.off),
        2 => @intCast(n.size()),
        else => return -E.EINVAL,
    };
    const new = base + off;
    if (new < 0) return -E.EINVAL;
    f.off = @intCast(new);
    return new;
}

fn sysIoctl(fd: u64, req: u64, arg: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    switch (req) {
        0x5421 => { // FIONBIO
            const v = proc.readUser(i32, arg) catch return -E.EFAULT;
            if (v != 0) f.flags |= vfs.O_NONBLOCK else f.flags &= ~@as(u32, vfs.O_NONBLOCK);
            return 0;
        },
        0x5451 => {
            proc.current().cloexec.set(fd);
            return 0;
        },
        0x5450 => {
            proc.current().cloexec.unset(fd);
            return 0;
        },
        else => {},
    }
    if (f.node) |n| if (n.kind == .chardev) if (n.dev.?.ioctl) |io| return io(f, req, arg);
    if (req == 0x541B and f.pipe != null) {
        proc.writeUser(i32, arg, @intCast(f.pipe.?.len)) catch return -E.EFAULT;
        return 0;
    }
    return -E.ENOTTY;
}

fn sysDup(fd: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    return installFd(proc.current(), vfs.ref(f), false);
}

fn sysDup3(old: u64, new: u64, flags: u64, allow_same: bool) isize {
    const p = proc.current();
    const f = getFile(old) orelse return -E.EBADF;
    if (new >= proc.MAX_FDS) return -E.EBADF;
    if (old == new) return if (allow_same) @intCast(new) else -E.EINVAL;
    if (p.fds[new]) |o| vfs.release(o);
    p.fds[new] = vfs.ref(f);
    p.cloexec.setValue(new, flags & vfs.O_CLOEXEC != 0);
    return @intCast(new);
}

fn sysFcntl(fd: u64, cmd: u64, arg: u64) isize {
    const p = proc.current();
    const f = getFile(fd) orelse return -E.EBADF;
    switch (cmd) {
        0, 1030 => { // F_DUPFD, F_DUPFD_CLOEXEC
            const nfd = allocFd(p, arg) orelse return -E.EMFILE;
            p.fds[nfd] = vfs.ref(f);
            p.cloexec.setValue(nfd, cmd == 1030);
            return @intCast(nfd);
        },
        1 => return @intFromBool(p.cloexec.isSet(fd)),
        2 => {
            p.cloexec.setValue(fd, arg & 1 != 0);
            return 0;
        },
        3 => return @intCast(f.flags),
        4 => {
            const mask: u32 = vfs.O_APPEND | vfs.O_NONBLOCK;
            f.flags = (f.flags & ~mask) | (@as(u32, @truncate(arg)) & mask);
            return 0;
        },
        5, 6, 7 => return 0, // locks
        else => return -E.EINVAL,
    }
}

fn sysPipe2(fds: u64, flags: u64) isize {
    const p = proc.current();
    const pr = vfs.makePipe() catch return -E.ENOMEM;
    const nb: u32 = @truncate(flags & vfs.O_NONBLOCK);
    pr[0].flags |= nb;
    pr[1].flags |= nb;
    const r = installFd(p, pr[0], flags & vfs.O_CLOEXEC != 0);
    if (r < 0) {
        vfs.release(pr[1]);
        return r;
    }
    const w = installFd(p, pr[1], flags & vfs.O_CLOEXEC != 0);
    if (w < 0) {
        _ = sysClose(@intCast(r));
        return w;
    }
    proc.writeUser([2]i32, fds, .{ @intCast(r), @intCast(w) }) catch return -E.EFAULT;
    return 0;
}

const Dirent = extern struct { ino: u64 align(1), off: i64 align(1), reclen: u16 align(1), kind: u8 align(1) };

fn sysGetdents64(fd: u64, buf: u64, len: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const n = f.node orelse return -E.ENOTDIR;
    if (n.kind != .dir) return -E.ENOTDIR;
    var written: u64 = 0;
    while (true) {
        const idx = f.off;
        var name: []const u8 = undefined;
        var child: *vfs.Node = undefined;
        if (idx == 0) {
            name = ".";
            child = n;
        } else if (idx == 1) {
            name = "..";
            child = n.parent orelse n;
        } else {
            if (idx - 2 >= n.children.items.len) break;
            child = n.children.items[idx - 2];
            name = child.name;
        }
        const reclen = std.mem.alignForward(u64, 19 + name.len + 1, 8);
        if (written + reclen > len) {
            if (written == 0) return -E.EINVAL;
            break;
        }
        const dtype: u8 = switch (child.kind) {
            .file => 8,
            .dir => 4,
            .symlink => 10,
            .chardev => 2,
            .fifo => 1,
        };
        const d = Dirent{ .ino = child.ino, .off = @intCast(idx + 1), .reclen = @intCast(reclen), .kind = dtype };
        proc.copyToUser(buf + written, std.mem.asBytes(&d)) catch return -E.EFAULT;
        proc.copyToUser(buf + written + 19, name) catch return -E.EFAULT;
        var zeros = [_]u8{0} ** 8;
        proc.copyToUser(buf + written + 19 + name.len, zeros[0 .. reclen - 19 - name.len]) catch return -E.EFAULT;
        written += reclen;
        f.off += 1;
    }
    return @intCast(written);
}

fn sysGetcwd(buf: u64, size: u64) isize {
    var tmp: [4096]u8 = undefined;
    const path = vfs.pathOf(proc.current().cwd, &tmp);
    if (path.len + 1 > size) return -E.ERANGE;
    proc.copyToUser(buf, path) catch return -E.EFAULT;
    proc.writeUser(u8, buf + path.len, 0) catch return -E.EFAULT;
    return @intCast(path.len + 1);
}

fn sysChdir(path_addr: u64) isize {
    var buf: [4096]u8 = undefined;
    const path = readPath(path_addr, &buf) catch |e| return err(e);
    const p = proc.current();
    const n = vfs.resolve(p.cwd, path, true) catch |e| return err(e);
    if (n.kind != .dir) return -E.ENOTDIR;
    p.cwd = n;
    return 0;
}

fn sysFchdir(fd: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const n = f.node orelse return -E.ENOTDIR;
    if (n.kind != .dir) return -E.ENOTDIR;
    proc.current().cwd = n;
    return 0;
}

fn sysMkdirat(dirfd: u64, path_addr: u64, mode: u64) isize {
    var buf: [4096]u8 = undefined;
    const path = readPath(path_addr, &buf) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const pr = vfs.resolveParent(start, path) catch |e| return err(e);
    if (pr.dir.lookup(pr.name) != null) return -E.EEXIST;
    if (std.mem.eql(u8, pr.name, ".") or std.mem.eql(u8, pr.name, "..")) return -E.EEXIST;
    const n = vfs.newNode(.dir, @as(u32, @truncate(mode)) & ~proc.current().umask & 0o7777) catch return -E.ENOMEM;
    vfs.addChild(pr.dir, pr.name, n) catch return -E.ENOMEM;
    return 0;
}

fn sysUnlinkat(dirfd: u64, path_addr: u64, flags: u64) isize {
    var buf: [4096]u8 = undefined;
    const path = readPath(path_addr, &buf) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const pr = vfs.resolveParent(start, path) catch |e| return err(e);
    const n = pr.dir.lookup(pr.name) orelse return -E.ENOENT;
    if (flags & AT_REMOVEDIR != 0) {
        if (n.kind != .dir) return -E.ENOTDIR;
        if (n.children.items.len != 0) return -E.ENOTEMPTY;
        if (n == vfs.root) return -E.EBUSY;
    } else if (n.kind == .dir) return -E.EISDIR;
    vfs.removeChild(pr.dir, n);
    return 0;
}

fn sysRenameat(od: u64, op: u64, nd: u64, np: u64) isize {
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const oldp = readPath(op, &b1) catch |e| return err(e);
    const newp = readPath(np, &b2) catch |e| return err(e);
    const os = startDir(od, oldp) catch |e| return err(e);
    const ns = startDir(nd, newp) catch |e| return err(e);
    const opr = vfs.resolveParent(os, oldp) catch |e| return err(e);
    const npr = vfs.resolveParent(ns, newp) catch |e| return err(e);
    const n = opr.dir.lookup(opr.name) orelse return -E.ENOENT;
    // refuse to move a directory into itself
    var it: ?*vfs.Node = npr.dir;
    while (it) |x| : (it = x.parent) if (x == n) return -E.EINVAL;
    if (npr.dir.lookup(npr.name)) |existing| {
        if (existing == n) return 0;
        if (existing.kind == .dir and existing.children.items.len != 0) return -E.ENOTEMPTY;
        vfs.removeChild(npr.dir, existing);
    }
    vfs.removeChild(opr.dir, n);
    n.unlinked = false;
    alloc.free(n.name);
    vfs.addChild(npr.dir, npr.name, n) catch return -E.ENOMEM;
    return 0;
}

fn sysSymlinkat(target_addr: u64, dirfd: u64, path_addr: u64) isize {
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const target = readPath(target_addr, &b1) catch |e| return err(e);
    const path = readPath(path_addr, &b2) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const pr = vfs.resolveParent(start, path) catch |e| return err(e);
    if (pr.dir.lookup(pr.name) != null) return -E.EEXIST;
    const n = vfs.newNode(.symlink, 0o777) catch return -E.ENOMEM;
    n.link = alloc.dupe(u8, target) catch return -E.ENOMEM;
    vfs.addChild(pr.dir, pr.name, n) catch return -E.ENOMEM;
    return 0;
}

fn sysReadlinkat(dirfd: u64, path_addr: u64, buf: u64, size: u64) isize {
    var b: [4096]u8 = undefined;
    const path = readPath(path_addr, &b) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const n = vfs.resolve(start, path, false) catch |e| return err(e);
    if (n.kind != .symlink) return -E.EINVAL;
    const l = @min(n.link.len, size);
    proc.copyToUser(buf, n.link[0..l]) catch return -E.EFAULT;
    return @intCast(l);
}

fn sysFchmodat(dirfd: u64, path_addr: u64, mode: u64) isize {
    var b: [4096]u8 = undefined;
    const path = readPath(path_addr, &b) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const n = vfs.resolve(start, path, true) catch |e| return err(e);
    n.mode = @truncate(mode & 0o7777);
    return 0;
}

fn sysFchmod(fd: u64, mode: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    if (f.node) |n| n.mode = @truncate(mode & 0o7777);
    return 0;
}

fn sysFaccessat(dirfd: u64, path_addr: u64, mode: u64) isize {
    var b: [4096]u8 = undefined;
    const path = readPath(path_addr, &b) catch |e| return err(e);
    const start = startDir(dirfd, path) catch |e| return err(e);
    const n = vfs.resolve(start, path, true) catch |e| return err(e);
    if (mode & 1 != 0 and n.kind == .file and n.mode & 0o111 == 0) return -E.EACCES;
    return 0;
}

fn sysTruncate(path_addr: u64, len: u64) isize {
    var b: [4096]u8 = undefined;
    const path = readPath(path_addr, &b) catch |e| return err(e);
    const n = vfs.resolve(proc.current().cwd, path, true) catch |e| return err(e);
    if (n.kind != .file) return -E.EISDIR;
    n.truncate(len) catch return -E.ENOMEM;
    return 0;
}

fn sysFtruncate(fd: u64, len: u64) isize {
    const f = getFile(fd) orelse return -E.EBADF;
    const n = f.node orelse return -E.EINVAL;
    if (n.kind != .file) return -E.EINVAL;
    n.truncate(len) catch return -E.ENOMEM;
    return 0;
}

fn sysStatfs(buf: u64) isize {
    var s = [_]u64{0} ** 15;
    s[0] = 0x858458f6; // RAMFS_MAGIC
    s[1] = 4096;
    s[2] = pmm.total_pages;
    s[3] = pmm.free_pages;
    s[4] = pmm.free_pages;
    s[8] = 255;
    proc.copyToUser(buf, std.mem.sliceAsBytes(&s)) catch return -E.EFAULT;
    return 0;
}

// ------------------------------------------------------------------
// poll / select
// ------------------------------------------------------------------
const PollFd = extern struct { fd: i32, events: i16, revents: i16 };

fn pollOnce(fds: u64, n: u64) !usize {
    var ready: usize = 0;
    for (0..n) |i| {
        var pf = try proc.readUser(PollFd, fds + i * 8);
        pf.revents = 0;
        if (pf.fd >= 0) {
            if (getFile(@intCast(pf.fd))) |f| {
                pf.revents = @bitCast(vfs.poll(f, @bitCast(pf.events)));
            } else pf.revents = 32; // POLLNVAL
        }
        if (pf.revents != 0) ready += 1;
        try proc.writeUser(PollFd, fds + i * 8, pf);
    }
    return ready;
}

/// Generic wait loop: `check` returns ready count; timeout_ms < 0 = forever.
fn waitReady(ctx: anytype, timeout_ms: i64) isize {
    const start = time.now();
    while (true) {
        const r = ctx.check() catch return -E.EFAULT;
        if (r > 0) return @intCast(r);
        if (timeout_ms == 0) return 0;
        if (timeout_ms > 0 and (time.now() - start) * 1000 / time.HZ >= @as(u64, @intCast(timeout_ms))) return 0;
        if (signal.hasPending()) return -E.EINTR;
        sched.sleepTicks(1);
    }
}

fn sysPoll(fds: u64, n: u64, timeout: i64) isize {
    if (n > 1024) return -E.EINVAL;
    const Ctx = struct {
        fds: u64,
        n: u64,
        fn check(s: @This()) !usize {
            return pollOnce(s.fds, s.n);
        }
    };
    return waitReady(Ctx{ .fds = fds, .n = n }, timeout);
}

fn timespecMs(addr: u64) ?i64 {
    const ts = proc.readUser([2]i64, addr) catch return null;
    return ts[0] * 1000 + @divTrunc(ts[1], 1_000_000);
}
fn timevalMs(addr: u64) ?i64 {
    const tv = proc.readUser([2]i64, addr) catch return null;
    return tv[0] * 1000 + @divTrunc(tv[1], 1000);
}

fn sysPpoll(fds: u64, n: u64, ts: u64) isize {
    const t: i64 = if (ts == 0) -1 else (timespecMs(ts) orelse return -E.EFAULT);
    return sysPoll(fds, n, t);
}

const FdSet = [16]u64; // 1024 bits

fn selectOnce(nfds: u64, rset: u64, wset: u64, eset: u64) !usize {
    var rin: FdSet = std.mem.zeroes(FdSet);
    var win: FdSet = std.mem.zeroes(FdSet);
    const words = (nfds + 63) / 64;
    if (rset != 0) try proc.copyFromUser(std.mem.sliceAsBytes(rin[0..words]), rset);
    if (wset != 0) try proc.copyFromUser(std.mem.sliceAsBytes(win[0..words]), wset);
    var rout: FdSet = std.mem.zeroes(FdSet);
    var wout: FdSet = std.mem.zeroes(FdSet);
    var ready: usize = 0;
    for (0..nfds) |fd| {
        const w = fd / 64;
        const b = @as(u64, 1) << @intCast(fd % 64);
        const want_r = rin[w] & b != 0;
        const want_w = win[w] & b != 0;
        if (!want_r and !want_w) continue;
        const f = getFile(fd) orelse return error.BadFd;
        const ev = vfs.poll(f, vfs.POLLIN | vfs.POLLOUT);
        if (want_r and ev & (vfs.POLLIN | vfs.POLLHUP | vfs.POLLERR) != 0) {
            rout[w] |= b;
            ready += 1;
        }
        if (want_w and ev & (vfs.POLLOUT | vfs.POLLERR) != 0) {
            wout[w] |= b;
            ready += 1;
        }
    }
    if (ready > 0 or true) {
        if (rset != 0) try proc.copyToUser(rset, std.mem.sliceAsBytes(rout[0..words]));
        if (wset != 0) try proc.copyToUser(wset, std.mem.sliceAsBytes(wout[0..words]));
        if (eset != 0) {
            const z: FdSet = std.mem.zeroes(FdSet);
            try proc.copyToUser(eset, std.mem.sliceAsBytes(z[0..words]));
        }
    }
    return ready;
}

fn sysSelect(nfds: u64, r: u64, w: u64, e: u64, timeout: ?i64) isize {
    if (nfds > 1024) return -E.EINVAL;
    // keep the caller's input sets: copy them, since selectOnce overwrites
    var rin: FdSet = std.mem.zeroes(FdSet);
    var win: FdSet = std.mem.zeroes(FdSet);
    const words = (nfds + 63) / 64;
    if (r != 0) proc.copyFromUser(std.mem.sliceAsBytes(rin[0..words]), r) catch return -E.EFAULT;
    if (w != 0) proc.copyFromUser(std.mem.sliceAsBytes(win[0..words]), w) catch return -E.EFAULT;
    const Ctx = struct {
        nfds: u64,
        r: u64,
        w: u64,
        e: u64,
        rin: *FdSet,
        win: *FdSet,
        words: u64,
        fn check(s: @This()) !usize {
            if (s.r != 0) try proc.copyToUser(s.r, std.mem.sliceAsBytes(s.rin[0..s.words]));
            if (s.w != 0) try proc.copyToUser(s.w, std.mem.sliceAsBytes(s.win[0..s.words]));
            return selectOnce(s.nfds, s.r, s.w, s.e);
        }
    };
    return waitReady(Ctx{ .nfds = nfds, .r = r, .w = w, .e = e, .rin = &rin, .win = &win, .words = words }, timeout orelse -1);
}

fn sysPselect(nfds: u64, r: u64, w: u64, e: u64, ts: u64) isize {
    const t: ?i64 = if (ts == 0) null else (timespecMs(ts) orelse return -E.EFAULT);
    return sysSelect(nfds, r, w, e, t);
}

// ------------------------------------------------------------------
// memory
// ------------------------------------------------------------------
const MAP_SHARED = 1;
const MAP_PRIVATE = 2;
const MAP_FIXED = 0x10;
const MAP_ANONYMOUS = 0x20;
const MAP_FIXED_NOREPLACE = 0x100000;

fn sysMmap(addr: u64, len_in: u64, prot: u64, flags: u64, fd: u64, off: u64) isize {
    const p = proc.current();
    if (len_in == 0) return -E.EINVAL;
    const len = std.mem.alignForward(u64, len_in, proc.PAGE);
    if (addr & (proc.PAGE - 1) != 0 and flags & MAP_FIXED != 0) return -E.EINVAL;
    var file: ?*File = null;
    if (flags & MAP_ANONYMOUS == 0) {
        file = getFile(fd) orelse return -E.EBADF;
        if (file.?.node == null or file.?.node.?.kind != .file) return -E.ENODEV;
    }
    var start: u64 = undefined;
    if (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE) != 0) {
        if (addr + len > vmm.USER_TOP) return -E.ENOMEM;
        if (flags & MAP_FIXED_NOREPLACE != 0 and !p.isFree(addr, addr + len)) return -E.EEXIST;
        p.unmapRange(addr, addr + len) catch return -E.ENOMEM;
        start = addr;
    } else if (addr != 0 and addr + len <= vmm.USER_TOP and p.isFree(addr & ~(proc.PAGE - 1), (addr & ~(proc.PAGE - 1)) + len)) {
        start = addr & ~(proc.PAGE - 1);
    } else {
        start = p.findGap(len) orelse return -E.ENOMEM;
    }
    p.addVma(.{ .start = start, .end = start + len, .prot = @truncate(prot & 7) }) catch return -E.ENOMEM;
    if (file) |f| {
        const data = f.node.?.contents();
        var o: u64 = 0;
        while (o < len and off + o < data.len) : (o += proc.PAGE) {
            const phys = p.populate(start + o) orelse return -E.ENOMEM;
            const cnt = @min(proc.PAGE, data.len - (off + o));
            @memcpy(pmm.ptr([*]u8, phys)[0..cnt], data[off + o .. off + o + cnt]);
        }
    }
    return @bitCast(start);
}

fn sysMunmap(addr: u64, len: u64) isize {
    if (addr & (proc.PAGE - 1) != 0) return -E.EINVAL;
    proc.current().unmapRange(addr, addr + std.mem.alignForward(u64, len, proc.PAGE)) catch return -E.ENOMEM;
    return 0;
}

fn sysMprotect(addr: u64, len: u64, prot: u64) isize {
    if (addr & (proc.PAGE - 1) != 0) return -E.EINVAL;
    proc.current().protectRange(addr, addr + std.mem.alignForward(u64, len, proc.PAGE), @truncate(prot & 7)) catch return -E.ENOMEM;
    return 0;
}

fn sysBrk(addr: u64) isize {
    const p = proc.current();
    if (addr < p.brk_start) return @bitCast(p.brk);
    var heap_vma: ?*proc.Vma = null;
    for (p.vmas.items) |*v| if (v.kind == .heap) {
        heap_vma = v;
    };
    const new_end = std.mem.alignForward(u64, addr, proc.PAGE);
    if (heap_vma) |hv| {
        if (new_end > hv.end) {
            if (!p.isFree(hv.end, new_end)) return @bitCast(p.brk);
            hv.end = new_end;
        } else if (new_end < hv.end) {
            const old_end = hv.end;
            p.unmapRange(new_end, old_end) catch {};
        }
    } else {
        if (new_end > p.brk_start) {
            if (!p.isFree(p.brk_start, new_end)) return @bitCast(p.brk);
            p.addVma(.{ .start = p.brk_start, .end = new_end, .prot = 3, .kind = .heap }) catch return @bitCast(p.brk);
        }
    }
    p.brk = addr;
    return @bitCast(addr);
}

// ------------------------------------------------------------------
// processes
// ------------------------------------------------------------------
const CLONE_VM = 0x100;
const CLONE_VFORK = 0x4000;
const CLONE_THREAD = 0x10000;
const CLONE_SETTLS = 0x80000;
const CLONE_PARENT_SETTID = 0x100000;
const CLONE_CHILD_CLEARTID = 0x200000;
const CLONE_CHILD_SETTID = 0x1000000;

fn sysClone(f: *Frame, flags: u64, newsp: u64, ptid: u64, ctid: u64, tls: u64) isize {
    if (flags & CLONE_THREAD != 0) return -E.ENOSYS;
    const r = doFork(f, newsp, flags, tls);
    if (r > 0) {
        if (flags & CLONE_PARENT_SETTID != 0) proc.writeUser(i32, ptid, @intCast(r)) catch {};
        if (flags & CLONE_CHILD_SETTID != 0) {
            // child's copy of memory
            if (proc.byPid(@intCast(r))) |c| {
                if (c.space.translate(ctid)) |phys| pmm.ptr(*align(1) i32, phys).* = @intCast(r);
            }
        }
    }
    return r;
}

fn doFork(f: *Frame, newsp: u64, flags: u64, tls: u64) isize {
    const parent = proc.current();
    const space = parent.space.cloneUser() catch return -E.ENOMEM;
    const child = proc.newProcessWith(space) catch {
        space.destroy();
        return -E.ENOMEM;
    };
    child.parent = parent;
    child.ppid = parent.pid;
    child.pgid = parent.pgid;
    child.sid = parent.sid;
    child.cwd = parent.cwd;
    child.umask = parent.umask;
    child.brk_start = parent.brk_start;
    child.brk = parent.brk;
    child.name = parent.name;
    child.sig.actions = parent.sig.actions;
    child.sig.blocked = parent.sig.blocked;
    child.vmas = parent.vmas.clone(alloc) catch return -E.ENOMEM;
    for (parent.fds, 0..) |fd, i| {
        if (fd) |x| child.fds[i] = vfs.ref(x);
    }
    child.cloexec = parent.cloexec;
    var cf = f.*;
    cf.rax = 0;
    if (newsp != 0) cf.rsp = newsp;
    const t = sched.spawnUser(sched.current.nameSlice(), cf, space, child) catch return -E.ENOMEM;
    child.thread = t;
    asm volatile ("fxsave64 (%[b])"
        :
        : [b] "r" (&t.fpu),
        : "memory"
    );
    t.fs_base = if (flags & CLONE_SETTLS != 0) tls else cpu.rdmsr(cpu.MSR_FS_BASE);
    sched.makeReady(t);
    return child.pid;
}

fn readStrArray(addr: u64, list: *std.ArrayListUnmanaged([]const u8)) !void {
    if (addr == 0) return;
    var i: u64 = 0;
    while (i < 4096) : (i += 1) {
        const ptr = try proc.readUser(u64, addr + i * 8);
        if (ptr == 0) return;
        var tmp: [4096]u8 = undefined;
        const s = proc.readString(ptr, &tmp) catch |e| switch (e) {
            error.NameTooLong => return error.TooBig,
            else => return error.Fault,
        };
        try list.append(alloc, try alloc.dupe(u8, s));
    }
    return error.TooBig;
}

fn freeStrList(list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

fn sysExecve(f: *Frame, path_addr: u64, argv_addr: u64, envp_addr: u64) isize {
    var pbuf: [4096]u8 = undefined;
    const path = readPath(path_addr, &pbuf) catch |e| return err(e);
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer freeStrList(&argv);
    var envp: std.ArrayListUnmanaged([]const u8) = .{};
    defer freeStrList(&envp);
    readStrArray(argv_addr, &argv) catch |e| return if (e == error.TooBig) -E.E2BIG else -E.EFAULT;
    readStrArray(envp_addr, &envp) catch |e| return if (e == error.TooBig) -E.E2BIG else -E.EFAULT;
    return execPath(f, path, &argv, envp.items, 0);
}

pub fn execPath(f: *Frame, path: []const u8, argv: *std.ArrayListUnmanaged([]const u8), envp: []const []const u8, depth: u32) isize {
    const p = proc.current();
    const n = vfs.resolve(p.cwd, path, true) catch |e| return err(e);
    if (n.kind == .dir) return -E.EACCES;
    if (n.kind != .file) return -E.EACCES;
    if (n.mode & 0o111 == 0) return -E.EACCES;
    const data = n.contents();
    if (data.len >= 2 and data[0] == '#' and data[1] == '!') {
        if (depth > 3) return -E.ELOOP;
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        const line = std.mem.trim(u8, data[2..@min(nl, 256)], " \t\r");
        if (line.len == 0) return -E.ENOEXEC;
        const sp = std.mem.indexOfAny(u8, line, " \t");
        const interp = if (sp) |s| line[0..s] else line;
        const iarg = if (sp) |s| std.mem.trim(u8, line[s..], " \t") else "";
        var nargv: std.ArrayListUnmanaged([]const u8) = .{};
        defer freeStrList(&nargv);
        nargv.append(alloc, alloc.dupe(u8, interp) catch return -E.ENOMEM) catch return -E.ENOMEM;
        if (iarg.len > 0) nargv.append(alloc, alloc.dupe(u8, iarg) catch return -E.ENOMEM) catch return -E.ENOMEM;
        nargv.append(alloc, alloc.dupe(u8, path) catch return -E.ENOMEM) catch return -E.ENOMEM;
        if (argv.items.len > 1) for (argv.items[1..]) |a| nargv.append(alloc, alloc.dupe(u8, a) catch return -E.ENOMEM) catch return -E.ENOMEM;
        var ibuf: [256]u8 = undefined;
        const ipath = std.fmt.bufPrint(&ibuf, "{s}", .{interp}) catch return -E.ENAMETOOLONG;
        return execPath(f, ipath, &nargv, envp, depth + 1);
    }
    proc.execImage(p, data, argv.items, envp, f, path) catch |e| return switch (e) {
        error.NotElf, error.Unsupported => -E.ENOEXEC,
        error.OutOfMemory => -E.ENOMEM,
        error.TooBig => -E.E2BIG,
        else => -E.EFAULT,
    };
    // close-on-exec descriptors, reset caught signals
    for (0..proc.MAX_FDS) |i| {
        if (p.cloexec.isSet(i)) {
            if (p.fds[i]) |x| vfs.release(x);
            p.fds[i] = null;
            p.cloexec.unset(i);
        }
    }
    for (&p.sig.actions) |*a| {
        if (a.handler > signal.SIG_IGN) a.* = .{};
    }
    return 0;
}

const WNOHANG = 1;

fn sysWait4(pid: i32, status_addr: u64, options: u64) isize {
    const p = proc.current();
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    while (true) {
        var found = false;
        for (proc.procs.items) |c| {
            if (c.parent != p) continue;
            const match = if (pid > 0) c.pid == pid else if (pid == 0) c.pgid == p.pgid else if (pid == -1) true else c.pgid == -pid;
            if (!match) continue;
            found = true;
            if (c.zombie and c.thread.state == .zombie) {
                const cpid = c.pid;
                const st = c.exit_status;
                proc.reap(c);
                if (status_addr != 0) proc.writeUser(i32, status_addr, @bitCast(st)) catch return -E.EFAULT;
                return cpid;
            }
        }
        if (!found) return -E.ECHILD;
        if (options & WNOHANG != 0) return 0;
        if (signal.hasPending()) return -E.EINTR;
        p.child_wait.waitLocked();
    }
}

fn sysKill(pid: i32, sig64: u64) isize {
    const sig: u32 = @truncate(sig64);
    if (sig >= signal.NSIG) return -E.EINVAL;
    const p = proc.current();
    if (pid > 0) {
        const t = proc.byPid(pid) orelse return -E.ESRCH;
        if (t.zombie) return if (sig == 0) 0 else 0;
        signal.sendSignal(t, sig);
        return 0;
    }
    const grp: i32 = if (pid == 0) p.pgid else if (pid == -1) 0 else -pid;
    var n: usize = 0;
    for (proc.procs.items) |t| {
        if (t.zombie) continue;
        if (pid == -1) {
            if (t.pid == 1 or t == p) continue;
        } else if (t.pgid != grp) continue;
        signal.sendSignal(t, sig);
        n += 1;
    }
    return if (n == 0 and pid != -1) -E.ESRCH else 0;
}

fn sysSetpgid(pid_in: i32, pgid_in: i32) isize {
    const p = proc.current();
    const target = if (pid_in == 0) p else (proc.byPid(pid_in) orelse return -E.ESRCH);
    if (target != p and target.parent != p) return -E.ESRCH;
    const pgid = if (pgid_in == 0) target.pid else pgid_in;
    if (pgid < 0) return -E.EINVAL;
    target.pgid = pgid;
    return 0;
}

fn sysGetpgid(pid: i32) isize {
    const t = if (pid == 0) proc.current() else (proc.byPid(pid) orelse return -E.ESRCH);
    return t.pgid;
}

fn sysGetsid(pid: i32) isize {
    const t = if (pid == 0) proc.current() else (proc.byPid(pid) orelse return -E.ESRCH);
    return t.sid;
}

fn sysSetsid() isize {
    const p = proc.current();
    if (p.pgid == p.pid and p.pid != 1) return -E.EPERM;
    p.sid = p.pid;
    p.pgid = p.pid;
    return p.pid;
}

fn sysGetres(a: u64, b: u64, c: u64) isize {
    proc.writeUser(u32, a, 0) catch return -E.EFAULT;
    proc.writeUser(u32, b, 0) catch return -E.EFAULT;
    proc.writeUser(u32, c, 0) catch return -E.EFAULT;
    return 0;
}

// ------------------------------------------------------------------
// signals
// ------------------------------------------------------------------
fn sysSigaction(sig: u64, act: u64, oact: u64) isize {
    if (sig == 0 or sig >= signal.NSIG or sig == signal.SIGKILL or sig == signal.SIGSTOP) return -E.EINVAL;
    const p = proc.current();
    if (oact != 0) proc.writeUser(signal.Action, oact, p.sig.actions[sig]) catch return -E.EFAULT;
    if (act != 0) {
        const a = proc.readUser(signal.Action, act) catch return -E.EFAULT;
        p.sig.actions[sig] = a;
        if (a.handler == signal.SIG_IGN) p.sig.pending &= ~(@as(u64, 1) << @intCast(sig - 1));
    }
    return 0;
}

fn sysSigprocmask(how: u64, set: u64, oset: u64) isize {
    const p = proc.current();
    if (oset != 0) proc.writeUser(u64, oset, p.sig.blocked) catch return -E.EFAULT;
    if (set != 0) {
        const s = proc.readUser(u64, set) catch return -E.EFAULT;
        switch (how) {
            0 => p.sig.blocked |= s,
            1 => p.sig.blocked &= ~s,
            2 => p.sig.blocked = s,
            else => return -E.EINVAL,
        }
        p.sig.blocked &= ~((@as(u64, 1) << (signal.SIGKILL - 1)) | (@as(u64, 1) << (signal.SIGSTOP - 1)));
    }
    return 0;
}

fn sysSigpending(set: u64) isize {
    const p = proc.current();
    proc.writeUser(u64, set, p.sig.pending & p.sig.blocked) catch return -E.EFAULT;
    return 0;
}

fn sysSigsuspend(mask_addr: u64) isize {
    const p = proc.current();
    const m = proc.readUser(u64, mask_addr) catch return -E.EFAULT;
    p.sig.saved_mask = p.sig.blocked;
    p.sig.blocked = m;
    while (!signal.hasPending()) sched.sleepTicks(1);
    return -E.EINTR;
}

fn sysPause() isize {
    while (!signal.hasPending()) sched.sleepTicks(1);
    return -E.EINTR;
}

fn sysSigaltstack(old: u64) isize {
    if (old != 0) proc.writeUser([3]u64, old, .{ 0, 2, 0 }) catch return -E.EFAULT;
    return 0;
}

// ------------------------------------------------------------------
// time
// ------------------------------------------------------------------
fn sysNanosleep(req: u64, rem: u64) isize {
    const ts = proc.readUser([2]i64, req) catch return -E.EFAULT;
    if (ts[0] < 0 or ts[1] < 0 or ts[1] >= 1_000_000_000) return -E.EINVAL;
    const ns: u64 = @as(u64, @intCast(ts[0])) * 1_000_000_000 + @as(u64, @intCast(ts[1]));
    const end_ns = time.nanos() + ns;
    while (time.nanos() < end_ns) {
        if (signal.hasPending()) {
            if (rem != 0) {
                const left = end_ns -| time.nanos();
                proc.writeUser([2]i64, rem, .{ @intCast(left / 1_000_000_000), @intCast(left % 1_000_000_000) }) catch {};
            }
            return -E.EINTR;
        }
        const left = end_ns -| time.nanos();
        if (left < 1_000_000_000 / time.HZ) {
            sched.yield();
        } else sched.sleepTicks(left * time.HZ / 1_000_000_000);
    }
    return 0;
}

fn sysClockGettime(clk: u64, ts: u64) isize {
    const ns = time.nanos();
    var v: [2]i64 = undefined;
    if (clk == 0 or clk == 5 or clk == 8) { // REALTIME, *_COARSE, BOOTTIME-ish
        v = .{ time.boot_epoch + @as(i64, @intCast(ns / 1_000_000_000)), @intCast(ns % 1_000_000_000) };
    } else {
        v = .{ @intCast(ns / 1_000_000_000), @intCast(ns % 1_000_000_000) };
    }
    proc.writeUser([2]i64, ts, v) catch return -E.EFAULT;
    return 0;
}

fn sysGettimeofday(tv: u64) isize {
    if (tv == 0) return 0;
    const ns = time.nanos();
    proc.writeUser([2]i64, tv, .{ time.boot_epoch + @as(i64, @intCast(ns / 1_000_000_000)), @intCast((ns % 1_000_000_000) / 1000) }) catch return -E.EFAULT;
    return 0;
}

fn sysTimes(buf: u64) isize {
    const p = proc.current();
    const el = time.now() - p.start_tick;
    if (buf != 0) proc.writeUser([4]i64, buf, .{ @intCast(el), 0, @intCast(p.reaped_children_ticks), 0 }) catch return -E.EFAULT;
    return @intCast(time.now());
}

fn sysGetrusage(buf: u64) isize {
    var z = [_]u8{0} ** 144;
    proc.copyToUser(buf, &z) catch return -E.EFAULT;
    return 0;
}

// ------------------------------------------------------------------
// misc
// ------------------------------------------------------------------
fn sysUname(buf: u64) isize {
    var u = [_]u8{0} ** (65 * 6);
    const fields = [_][]const u8{ "yos", "yos", "0.1.0", "#1 yos hobby kernel (zig)", "x86_64", "(none)" };
    for (fields, 0..) |s, i| @memcpy(u[i * 65 .. i * 65 + s.len], s);
    proc.copyToUser(buf, &u) catch return -E.EFAULT;
    return 0;
}

fn sysSysinfo(buf: u64) isize {
    var s = [_]u64{0} ** 14;
    s[0] = time.now() / time.HZ;
    s[4] = pmm.total_pages * pmm.PAGE_SIZE;
    s[5] = pmm.free_pages * pmm.PAGE_SIZE;
    s[10] = proc.procs.items.len; // procs (u16 in low bits)
    var bytes = std.mem.sliceAsBytes(&s);
    std.mem.writeInt(u32, bytes[104..108], 1, .little); // mem_unit
    proc.copyToUser(buf, bytes[0..112]) catch return -E.EFAULT;
    return 0;
}

fn sysPrlimit(_: u64, res: u64, new: u64, old: u64) isize {
    _ = new;
    if (old != 0) {
        const inf: u64 = std.math.maxInt(u64);
        const v: [2]u64 = switch (res) {
            3 => .{ proc.STACK_SIZE, proc.STACK_SIZE }, // STACK
            7 => .{ proc.MAX_FDS, proc.MAX_FDS }, // NOFILE
            else => .{ inf, inf },
        };
        proc.writeUser([2]u64, old, v) catch return -E.EFAULT;
    }
    return 0;
}

fn sysArchPrctl(code: u64, addr: u64) isize {
    switch (code) {
        0x1002 => { // ARCH_SET_FS
            if (addr >= vmm.USER_TOP) return -E.EPERM;
            sched.current.fs_base = addr;
            cpu.wrmsr(cpu.MSR_FS_BASE, addr);
            return 0;
        },
        0x1003 => {
            proc.writeUser(u64, addr, sched.current.fs_base) catch return -E.EFAULT;
            return 0;
        },
        0x1001 => {
            cpu.wrmsr(cpu.MSR_KERNEL_GS_BASE, addr);
            return 0;
        },
        else => return -E.EINVAL,
    }
}

fn sysFutex(addr: u64, op: u64, val: u64) isize {
    switch (op & 0x7f) {
        0, 9 => { // WAIT, WAIT_BITSET
            const cur = proc.readUser(u32, addr) catch return -E.EFAULT;
            if (cur != @as(u32, @truncate(val))) return -E.EAGAIN;
            sched.sleepTicks(1);
            return 0;
        },
        1, 10 => return 0, // WAKE
        else => return -E.ENOSYS,
    }
}

fn sysGetrandom(buf: u64, len: u64) isize {
    const b = proc.userSlice(buf, len, true) catch return -E.EFAULT;
    vfs.randomBytes(b);
    return @intCast(len);
}

fn sysReboot(m1: u64, m2: u64, cmd: u64) isize {
    if (m1 != 0xfee1dead) return -E.EINVAL;
    _ = m2;
    switch (@as(u32, @truncate(cmd))) {
        0x4321FEDC, 0xCDEF0123 => {
            log.print("\n[yos] system power off\n", .{});
            acpi.poweroff();
        },
        0x01234567 => {
            log.print("\n[yos] system reboot\n", .{});
            acpi.reboot();
        },
        else => return 0,
    }
}
