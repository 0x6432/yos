//! Tiny raw-syscall runtime for the yos userland.
//! Depends only on `std.os.linux.syscallN` + `std.mem`/`std.fmt`, so it
//! is insulated from churn in std.fs / std.Io / std.posix.
const std = @import("std");
pub const linux = std.os.linux;

pub const fd_t = i32;
pub const AT_FDCWD: isize = -100;

fn u(x: anytype) usize {
    return switch (@typeInfo(@TypeOf(x))) {
        .pointer => @intFromPtr(x),
        .optional => if (x) |v| u(v) else 0,
        .comptime_int => @bitCast(@as(isize, x)),
        .int => |i| if (i.signedness == .signed) @bitCast(@as(isize, x)) else @intCast(x),
        .bool => @intFromBool(x),
        else => @compileError("bad syscall arg"),
    };
}

/// Raw syscall; returns the kernel result as a signed value (-errno on error).
pub inline fn sys(nr: linux.SYS, argv_: anytype) isize {
    const a = argv_;
    const r = switch (a.len) {
        0 => linux.syscall0(nr),
        1 => linux.syscall1(nr, u(a[0])),
        2 => linux.syscall2(nr, u(a[0]), u(a[1])),
        3 => linux.syscall3(nr, u(a[0]), u(a[1]), u(a[2])),
        4 => linux.syscall4(nr, u(a[0]), u(a[1]), u(a[2]), u(a[3])),
        5 => linux.syscall5(nr, u(a[0]), u(a[1]), u(a[2]), u(a[3]), u(a[4])),
        6 => linux.syscall6(nr, u(a[0]), u(a[1]), u(a[2]), u(a[3]), u(a[4]), u(a[5])),
        else => @compileError("too many args"),
    };
    return @bitCast(r);
}

pub const Error = error{SyscallFailed};
pub var last_errno: u16 = 0;

/// Turn a raw result into an error union (remembering errno).
pub fn check(r: isize) Error!usize {
    if (r < 0 and r > -4096) {
        last_errno = @intCast(-r);
        return error.SyscallFailed;
    }
    return @intCast(r);
}

pub fn strerror(e: u16) []const u8 {
    return switch (e) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        9 => "Bad file descriptor",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        17 => "File exists",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        28 => "No space left on device",
        39 => "Directory not empty",
        else => "Error",
    };
}

// ---------------- strings ----------------
pub const PathBuf = [4096]u8;

/// Copy `s` into `buf` with a NUL terminator.
pub fn cstr(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

// ---------------- process / args ----------------
pub const Args = struct {
    v: []const [*:0]const u8,
    i: usize = 0,
    pub fn next(self: *Args) ?[]const u8 {
        if (self.i >= self.v.len) return null;
        defer self.i += 1;
        return std.mem.sliceTo(self.v[self.i], 0);
    }
    pub fn skip(self: *Args) void {
        _ = self.next();
    }
};

pub fn args(init: std.process.Init.Minimal) Args {
    return .{ .v = init.args.vector };
}

pub fn exit(code: u8) noreturn {
    _ = sys(.exit_group, .{code});
    unreachable;
}
pub fn getpid() i32 {
    return @intCast(sys(.getpid, .{}));
}
pub fn getppid() i32 {
    return @intCast(sys(.getppid, .{}));
}
pub fn fork() Error!i32 {
    return @intCast(try check(sys(.fork, .{})));
}
pub fn kill(pid: i32, sig: u32) isize {
    return sys(.kill, .{ pid, sig });
}
pub fn wait4(pid: i32, status: ?*u32, opts: u32) isize {
    return sys(.wait4, .{ pid, status, opts, @as(usize, 0) });
}
pub const WaitResult = struct { pid: i32, status: u32 };
pub fn waitpid(pid: i32, opts: u32) WaitResult {
    var st: u32 = 0;
    while (true) {
        const r = wait4(pid, &st, opts);
        if (r == -4) continue; // EINTR
        return .{ .pid = @intCast(if (r < 0) -1 else r), .status = st };
    }
}
pub const W = struct {
    pub fn EXITSTATUS(s: u32) u8 {
        return @truncate((s >> 8) & 0xff);
    }
    pub fn TERMSIG(s: u32) u32 {
        return s & 0x7f;
    }
    pub fn STOPSIG(s: u32) u32 {
        return EXITSTATUS(s);
    }
    pub fn IFEXITED(s: u32) bool {
        return TERMSIG(s) == 0;
    }
    pub fn IFSTOPPED(s: u32) bool {
        return (s & 0xff) == 0x7f;
    }
    pub fn IFSIGNALED(s: u32) bool {
        return (s & 0x7f) != 0 and (s & 0x7f) != 0x7f;
    }
};
pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) isize {
    return sys(.execve, .{ path, argv, envp });
}
pub fn pause() isize {
    return sys(.pause, .{});
}

// ---------------- files ----------------
pub const O = struct {
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    pub const CREAT = 0o100;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const DIRECTORY = 0o200000;
    pub const CLOEXEC = 0o2000000;
};

pub fn open(path: []const u8, flags: u32, mode: u32) Error!fd_t {
    var b: PathBuf = undefined;
    return @intCast(try check(sys(.openat, .{ AT_FDCWD, cstr(&b, path), flags, mode })));
}
pub fn close(fd: fd_t) void {
    _ = sys(.close, .{fd});
}
pub fn read(fd: fd_t, buf: []u8) isize {
    return sys(.read, .{ fd, buf.ptr, buf.len });
}
pub fn write(fd: fd_t, buf: []const u8) isize {
    return sys(.write, .{ fd, buf.ptr, buf.len });
}
pub fn readAll(fd: fd_t, buf: []u8) Error!usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try check(read(fd, buf[n..]));
        if (r == 0) break;
        n += r;
    }
    return n;
}
pub fn writeAll(fd: fd_t, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) off += try check(write(fd, buf[off..]));
}
pub fn lseek(fd: fd_t, off: i64, whence: u32) isize {
    return sys(.lseek, .{ fd, off, whence });
}
pub fn pipe(fds: *[2]fd_t) isize {
    return sys(.pipe2, .{ fds, @as(usize, 0) });
}
pub fn dup2(old: fd_t, new: fd_t) isize {
    return sys(.dup3, .{ old, new, @as(usize, 0) });
}

fn pathOp(comptime nr: linux.SYS, path: []const u8, extra: anytype) isize {
    var b: PathBuf = undefined;
    return sys(nr, .{ AT_FDCWD, cstr(&b, path) } ++ extra);
}
pub fn mkdir(path: []const u8, mode: u32) isize {
    return pathOp(.mkdirat, path, .{mode});
}
pub fn unlink(path: []const u8) isize {
    return pathOp(.unlinkat, path, .{@as(u32, 0)});
}
pub fn rmdir(path: []const u8) isize {
    return pathOp(.unlinkat, path, .{@as(u32, 0x200)}); // AT_REMOVEDIR
}
pub fn rename(old: []const u8, new: []const u8) isize {
    var a: PathBuf = undefined;
    var b: PathBuf = undefined;
    return sys(.renameat, .{ AT_FDCWD, cstr(&a, old), AT_FDCWD, cstr(&b, new) });
}
pub fn symlink(target: []const u8, path: []const u8) isize {
    var a: PathBuf = undefined;
    var b: PathBuf = undefined;
    return sys(.symlinkat, .{ cstr(&a, target), AT_FDCWD, cstr(&b, path) });
}
pub fn readlink(path: []const u8, buf: []u8) Error![]u8 {
    const n = try check(pathOp(.readlinkat, path, .{ buf.ptr, buf.len }));
    return buf[0..n];
}

pub const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    _pad0: u32,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atime: [2]i64,
    mtime: [2]i64,
    ctime: [2]i64,
    _unused: [3]i64,
};
pub fn stat(path: []const u8, st: *Stat) isize {
    return pathOp(.fstatat64, path, .{ st, @as(u32, 0) });
}
pub fn lstat(path: []const u8, st: *Stat) isize {
    return pathOp(.fstatat64, path, .{ st, @as(u32, 0x100) }); // AT_SYMLINK_NOFOLLOW
}
pub const S = struct {
    pub const IFMT = 0o170000;
    pub const IFDIR = 0o040000;
    pub const IFLNK = 0o120000;
    pub const IFCHR = 0o020000;
    pub const IFIFO = 0o010000;
    pub fn isDir(m: u32) bool {
        return m & IFMT == IFDIR;
    }
};

/// Iterate a directory with getdents64.
pub const Dir = struct {
    fd: fd_t,
    buf: [4096]u8 align(8) = undefined,
    pos: usize = 0,
    len: usize = 0,

    pub const Entry = struct { name: []const u8, kind: u8, ino: u64 };

    pub fn open(path: []const u8) Error!Dir {
        return .{ .fd = try sysOpenDir(path) };
    }
    fn sysOpenDir(path: []const u8) Error!fd_t {
        var b: PathBuf = undefined;
        return @intCast(try check(sys(.openat, .{ AT_FDCWD, cstr(&b, path), @as(u32, O.RDONLY | O.DIRECTORY | O.CLOEXEC), @as(u32, 0) })));
    }
    pub fn close(self: *Dir) void {
        sysClose(self.fd);
    }
    pub fn next(self: *Dir) Error!?Entry {
        while (true) {
            if (self.pos >= self.len) {
                const n = try check(sys(.getdents64, .{ self.fd, &self.buf, self.buf.len }));
                if (n == 0) return null;
                self.len = n;
                self.pos = 0;
            }
            const base = self.buf[self.pos..];
            const ino = std.mem.readInt(u64, base[0..8], .little);
            const reclen = std.mem.readInt(u16, base[16..18], .little);
            const kind = base[18];
            const name = std.mem.sliceTo(base[19..reclen], 0);
            self.pos += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = kind, .ino = ino };
        }
    }
};
fn sysClose(fd: fd_t) void {
    close(fd);
}

// ---------------- memory ----------------
pub const PROT = struct {
    pub const READ = 1;
    pub const WRITE = 2;
    pub const EXEC = 4;
};
pub fn mmap(len: usize, prot: u32) Error![]u8 {
    const r = try check(sys(.mmap, .{ @as(usize, 0), len, prot, @as(u32, 0x22), @as(i32, -1), @as(usize, 0) })); // PRIVATE|ANON
    return @as([*]u8, @ptrFromInt(r))[0..len];
}
pub fn munmap(m: []u8) void {
    _ = sys(.munmap, .{ m.ptr, m.len });
}
pub fn brk(addr: usize) usize {
    return @bitCast(sys(.brk, .{addr}));
}

// ---------------- time ----------------
pub const timespec = extern struct { sec: i64, nsec: i64 };
pub fn nanosleepNs(ns: u64) void {
    var req = timespec{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    var rem: timespec = undefined;
    while (sys(.nanosleep, .{ &req, &rem }) == -4) req = rem;
}
pub fn sleepMs(ms: u64) void {
    nanosleepNs(ms * 1_000_000);
}
pub fn clockMonotonic() timespec {
    var t: timespec = undefined;
    _ = sys(.clock_gettime, .{ @as(u32, 1), &t });
    return t;
}

// ---------------- signals ----------------
pub const SIG = struct {
    pub const HUP = 1;
    pub const INT = 2;
    pub const QUIT = 3;
    pub const KILL = 9;
    pub const USR1 = 10;
    pub const SEGV = 11;
    pub const USR2 = 12;
    pub const PIPE = 13;
    pub const ALRM = 14;
    pub const TERM = 15;
    pub const CHLD = 17;
    pub const CONT = 18;
    pub const STOP = 19;
    pub const TSTP = 20;
    pub const DFL: usize = 0;
    pub const IGN: usize = 1;
};
pub const SA = struct {
    pub const NOCLDSTOP = 1;
    pub const SIGINFO = 4;
    pub const RESTORER = 0x04000000;
    pub const ONSTACK = 0x08000000;
    pub const RESTART = 0x10000000;
    pub const NODEFER = 0x40000000;
    pub const RESETHAND = 0x80000000;
};
pub const KSigaction = extern struct { handler: usize, flags: u64, restorer: usize, mask: u64 };

fn restoreRt() callconv(.naked) noreturn {
    asm volatile (
        \\mov $15, %%eax
        \\syscall
    );
}

/// Install a handler (`h` is a function pointer, SIG.DFL or SIG.IGN).
pub fn sigaction(sig: u32, h: anytype, flags: u64, mask: u64) isize {
    const hv: usize = switch (@typeInfo(@TypeOf(h))) {
        .int, .comptime_int => h,
        else => @intFromPtr(h),
    };
    const act = KSigaction{ .handler = hv, .flags = flags | SA.RESTORER, .restorer = @intFromPtr(&restoreRt), .mask = mask };
    return sys(.rt_sigaction, .{ sig, &act, @as(usize, 0), @as(usize, 8) });
}
pub fn sigbit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}
pub fn sigprocmask(how: u32, set: ?*const u64, old: ?*u64) isize {
    return sys(.rt_sigprocmask, .{ how, set, old, @as(usize, 8) });
}

// ---------------- output ----------------
fn fdDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const fd: fd_t = if (w == &stderr_w) 2 else 1;
    if (w.end > 0) {
        writeAll(fd, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
    }
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        writeAll(fd, d) catch return error.WriteFailed;
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| writeAll(fd, last) catch return error.WriteFailed;
    return n + last.len * splat;
}
const fd_vtable: std.Io.Writer.VTable = .{ .drain = fdDrain };
var stdout_buf: [1024]u8 = undefined;
var stderr_buf: [256]u8 = undefined;
pub var stdout_w: std.Io.Writer = .{ .vtable = &fd_vtable, .buffer = &stdout_buf };
pub var stderr_w: std.Io.Writer = .{ .vtable = &fd_vtable, .buffer = &stderr_buf };

/// printf to stdout (flushed immediately).
pub fn print(comptime fmt: []const u8, a: anytype) void {
    stdout_w.print(fmt, a) catch {};
    stdout_w.flush() catch {};
}
/// Buffered stdout print; call `flush()` when done.
pub fn bprint(comptime fmt: []const u8, a: anytype) void {
    stdout_w.print(fmt, a) catch {};
}
pub fn flush() void {
    stdout_w.flush() catch {};
}
pub fn eprint(comptime fmt: []const u8, a: anytype) void {
    stderr_w.print(fmt, a) catch {};
    stderr_w.flush() catch {};
}

// ---------------- misc ----------------
pub const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};
pub fn uname(un: *Utsname) isize {
    return sys(.uname, .{un});
}
