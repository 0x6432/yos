//! Kernel self-test suite run from userspace.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

var failures: u32 = 0;
var passed: u32 = 0;
var got_signal: i32 = 0;

fn out(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch {};
}

fn check(ok: bool, what: []const u8) void {
    if (ok) passed += 1 else failures += 1;
    out("[ktest] {s:<40} {s}\n", .{ what, if (ok) "ok" else "FAIL" });
}

fn freeRam() u64 {
    var si: [14]u64 = undefined;
    _ = linux.syscall1(.sysinfo, @intFromPtr(&si));
    return si[5];
}

fn handler(sig: i32) callconv(.c) void {
    got_signal = sig;
}

pub fn main() !void {
    const cwd = std.fs.cwd();
    // ---- files ----
    {
        const f = try cwd.createFile("/tmp/test.txt", .{ .read = true });
        try f.writeAll("hello file");
        try f.seekTo(0);
        var buf: [64]u8 = undefined;
        const n = try f.readAll(&buf);
        check(std.mem.eql(u8, buf[0..n], "hello file"), "file create/write/seek/read");
        f.close();
        const st = try cwd.statFile("/tmp/test.txt");
        check(st.size == 10, "stat size");
        try cwd.makeDir("/tmp/dir");
        var d = try cwd.openDir("/tmp", .{ .iterate = true });
        var it = d.iterate();
        var seen: u32 = 0;
        while (try it.next()) |e| {
            if (std.mem.eql(u8, e.name, "test.txt") or std.mem.eql(u8, e.name, "dir")) seen += 1;
        }
        d.close();
        check(seen == 2, "getdents64 directory listing");
        try cwd.rename("/tmp/test.txt", "/tmp/dir/moved.txt");
        check(if (cwd.statFile("/tmp/dir/moved.txt")) |_| true else |_| false, "rename");
        try cwd.deleteFile("/tmp/dir/moved.txt");
        try cwd.deleteDir("/tmp/dir");
        check(if (cwd.statFile("/tmp/dir")) |_| false else |_| true, "unlink + rmdir");
        try posix.symlink("/bin/hello", "/tmp/link");
        var lb: [64]u8 = undefined;
        const l = try posix.readlink("/tmp/link", &lb);
        check(std.mem.eql(u8, l, "/bin/hello"), "symlink + readlink");
    }
    // ---- pipe + fork + exec + wait ----
    {
        const fds = try posix.pipe();
        const pid = try posix.fork();
        if (pid == 0) {
            try posix.dup2(fds[1], 1);
            posix.close(fds[0]);
            posix.close(fds[1]);
            const argv = [_:null]?[*:0]const u8{"/tmp/link"};
            const envp = [_:null]?[*:0]const u8{};
            _ = posix.execveZ("/tmp/link", &argv, &envp) catch {};
            linux.exit(127);
        }
        posix.close(fds[1]);
        var buf: [256]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try posix.read(fds[0], buf[total..]);
            if (n == 0) break;
            total += n;
        }
        posix.close(fds[0]);
        check(std.mem.indexOf(u8, buf[0..total], "Hello from userspace") != null, "fork + pipe + dup2 + execve (symlink)");
        const r = posix.waitpid(pid, 0);
        check(r.pid == pid and posix.W.IFEXITED(r.status) and posix.W.EXITSTATUS(r.status) == 0, "wait4 exit status 0");
    }
    {
        const pid = try posix.fork();
        if (pid == 0) linux.exit(42);
        const r = posix.waitpid(pid, 0);
        check(posix.W.EXITSTATUS(r.status) == 42, "exit code propagation (42)");
    }
    // ---- signals ----
    {
        var sa = posix.Sigaction{ .handler = .{ .handler = handler }, .mask = posix.empty_sigset, .flags = 0 };
        posix.sigaction(posix.SIG.USR1, &sa, null);
        try posix.kill(linux.getpid(), posix.SIG.USR1);
        check(got_signal == posix.SIG.USR1, "signal handler + sigreturn");
        const pid = try posix.fork();
        if (pid == 0) {
            while (true) _ = linux.pause();
        }
        posix.nanosleep(0, 30_000_000);
        try posix.kill(pid, posix.SIG.TERM);
        const r = posix.waitpid(pid, 0);
        check(posix.W.IFSIGNALED(r.status) and posix.W.TERMSIG(r.status) == posix.SIG.TERM, "kill child with SIGTERM");
    }
    // ---- memory ----
    {
        const m = try posix.mmap(null, 1 << 20, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        @memset(m, 0xAB);
        var ok = true;
        for (m) |b| if (b != 0xAB) {
            ok = false;
        };
        posix.munmap(m);
        check(ok, "mmap/munmap 1 MiB anonymous");
        const cur = linux.syscall1(.brk, 0);
        const nb = linux.syscall1(.brk, cur + 65536);
        const p: [*]u8 = @ptrFromInt(cur);
        p[65535] = 7;
        check(nb == cur + 65536 and p[65535] == 7, "brk grow");
        const ga = std.heap.page_allocator;
        const big = try ga.alloc(u8, 3 << 20);
        @memset(big, 1);
        ga.free(big);
        check(true, "page allocator 3 MiB");
    }
    // ---- copy-on-write fork ----
    {
        const ga = std.heap.page_allocator;
        const buf = try ga.alloc(u8, 4 << 20);
        defer ga.free(buf);
        @memset(buf, 0x11);
        const free_before = freeRam();
        const pid = try posix.fork();
        if (pid == 0) {
            // child: memory is shared until written
            var ok = true;
            for (buf) |b| if (b != 0x11) {
                ok = false;
            };
            const shared_cost = free_before -| freeRam();
            @memset(buf, 0x22);
            linux.exit(if (ok and shared_cost < (2 << 20)) 0 else 1);
        }
        const r = posix.waitpid(pid, 0);
        var intact = true;
        for (buf) |b| if (b != 0x11) {
            intact = false;
        };
        check(posix.W.EXITSTATUS(r.status) == 0, "cow: child shares pages until write");
        check(intact, "cow: parent unaffected by child writes");
    }
    // ---- time ----
    {
        const t0 = try posix.clock_gettime(.MONOTONIC);
        posix.nanosleep(0, 50_000_000);
        const t1 = try posix.clock_gettime(.MONOTONIC);
        const dt = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
        if (!(dt >= 45 and dt < 1000)) out("[ktest] dt={d}ms\n", .{dt});
        check(dt >= 45 and dt < 1000, "nanosleep 50ms / clock_gettime");
    }
    // ---- many processes ----
    {
        var ok = true;
        for (0..20) |i| {
            const pid = try posix.fork();
            if (pid == 0) linux.exit(@intCast(i));
            const r = posix.waitpid(pid, 0);
            if (posix.W.EXITSTATUS(r.status) != i) ok = false;
        }
        check(ok, "20 sequential fork/wait");
    }
    // ---- full signals (M9) ----
    try signalTests();
    if (failures == 0) {
        out("[ktest] ALL {d} TESTS PASSED\n", .{passed});
    } else {
        out("[ktest] {d} FAILED, {d} passed\n", .{ failures, passed });
    }
}

// ------------------------------------------------------------------
// M9 signal tests (raw syscalls)
// ------------------------------------------------------------------
var si_code: i32 = -100;
var si_pid: i32 = -1;
var si_value: i32 = 0;
var rt_count: u32 = 0;
var usr2_count: u32 = 0;
var alt_addr: usize = 0;
var alrm: u32 = 0;
var altstack_buf: [32768]u8 align(16) = undefined;

fn infoHandler(sig: i32, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = sig;
    const raw: *const [8]i32 = @ptrCast(@alignCast(info));
    si_code = raw[2];
    si_pid = raw[4];
    si_value = raw[6];
}
fn rtHandler(_: i32) callconv(.c) void {
    rt_count += 1;
}
fn usr2Handler(_: i32) callconv(.c) void {
    usr2_count += 1;
}
fn altHandler(_: i32) callconv(.c) void {
    var x: u8 = 0;
    alt_addr = @intFromPtr(&x);
    std.mem.doNotOptimizeAway(&x);
}
fn alrmHandler(_: i32) callconv(.c) void {
    alrm += 1;
}

fn setHandler(sig: u6, h: ?*const fn (i32) callconv(.c) void, flags: u32) void {
    var sa = posix.Sigaction{ .handler = .{ .handler = h }, .mask = posix.empty_sigset, .flags = flags };
    posix.sigaction(sig, &sa, null);
}
fn mask(how: usize, sig: u32) void {
    var set: u64 = @as(u64, 1) << @intCast(sig - 1);
    _ = linux.syscall4(.rt_sigprocmask, how, @intFromPtr(&set), 0, 8);
}
fn errno(rc: usize) linux.E {
    return linux.E.init(rc);
}
fn sleepMs(ms: u64) void {
    posix.nanosleep(0, ms * 1_000_000);
}
fn wait4(pid: i32, status: *u32, opts: u32) isize {
    return @bitCast(linux.syscall4(.wait4, @as(usize, @bitCast(@as(isize, pid))), @intFromPtr(status), opts, 0));
}

fn signalTests() !void {
    const me = linux.getpid();
    // SA_SIGINFO: si_code / si_pid from kill()
    {
        var sa = posix.Sigaction{ .handler = .{ .sigaction = infoHandler }, .mask = posix.empty_sigset, .flags = posix.SA.SIGINFO };
        posix.sigaction(posix.SIG.USR1, &sa, null);
        _ = linux.kill(me, posix.SIG.USR1);
        check(si_code == 0 and si_pid == me, "SA_SIGINFO si_code=SI_USER, si_pid");
        // rt_sigqueueinfo carries a value
        var info = std.mem.zeroes([32]i32);
        info[0] = posix.SIG.USR1;
        info[2] = -1; // SI_QUEUE
        info[4] = me;
        info[6] = 1234;
        _ = linux.syscall3(.rt_sigqueueinfo, @intCast(me), posix.SIG.USR1, @intFromPtr(&info));
        check(si_code == -1 and si_value == 1234, "rt_sigqueueinfo SI_QUEUE + value");
        setHandler(posix.SIG.USR1, handler, 0);
    }
    // standard signals coalesce, real-time signals queue
    {
        const RT: u6 = 40;
        setHandler(RT, rtHandler, 0);
        setHandler(posix.SIG.USR2, usr2Handler, 0);
        mask(0, RT);
        mask(0, posix.SIG.USR2);
        _ = linux.kill(me, RT);
        _ = linux.kill(me, RT);
        _ = linux.kill(me, RT);
        _ = linux.kill(me, posix.SIG.USR2);
        _ = linux.kill(me, posix.SIG.USR2);
        var pend: u64 = 0;
        _ = linux.syscall2(.rt_sigpending, @intFromPtr(&pend), 8);
        const pend_ok = pend & (1 << (RT - 1)) != 0 and pend & (1 << (posix.SIG.USR2 - 1)) != 0;
        mask(1, RT);
        mask(1, posix.SIG.USR2);
        check(pend_ok and rt_count == 3 and usr2_count == 1, "RT signals queue, standard coalesce");
    }
    // sigaltstack + SA_ONSTACK
    {
        const ss = [3]u64{ @intFromPtr(&altstack_buf), 0, altstack_buf.len };
        const rc = linux.syscall2(.sigaltstack, @intFromPtr(&ss), 0);
        setHandler(posix.SIG.USR2, altHandler, posix.SA.ONSTACK);
        _ = linux.kill(me, posix.SIG.USR2);
        const base = @intFromPtr(&altstack_buf);
        var old: [3]u64 = undefined;
        _ = linux.syscall2(.sigaltstack, 0, @intFromPtr(&old));
        check(rc == 0 and alt_addr >= base and alt_addr < base + altstack_buf.len and old[0] == base, "sigaltstack / SA_ONSTACK");
        const dis = [3]u64{ 0, 2, 0 };
        _ = linux.syscall2(.sigaltstack, @intFromPtr(&dis), 0);
        setHandler(posix.SIG.USR2, posix.SIG.DFL, 0);
    }
    // rt_sigtimedwait
    {
        mask(0, posix.SIG.USR1);
        _ = linux.kill(me, posix.SIG.USR1);
        var set: u64 = 1 << (posix.SIG.USR1 - 1);
        var info = std.mem.zeroes([32]i32);
        const ts = linux.timespec{ .sec = 1, .nsec = 0 };
        const r1 = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&set), @intFromPtr(&info), @intFromPtr(&ts), 8);
        const ts2 = linux.timespec{ .sec = 0, .nsec = 30_000_000 };
        const r2 = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&set), 0, @intFromPtr(&ts2), 8);
        mask(1, posix.SIG.USR1);
        check(r1 == posix.SIG.USR1 and info[4] == me and errno(r2) == .AGAIN, "rt_sigtimedwait (hit + timeout)");
    }
    // alarm / setitimer -> SIGALRM
    {
        setHandler(posix.SIG.ALRM, alrmHandler, 0);
        const it = [4]i64{ 0, 0, 0, 50_000 };
        _ = linux.syscall3(.setitimer, 0, @intFromPtr(&it), 0);
        _ = linux.pause();
        const a0 = linux.syscall1(.alarm, 5);
        const a1 = linux.syscall1(.alarm, 0);
        check(alrm == 1 and a0 == 0 and a1 == 5, "setitimer/alarm -> SIGALRM");
    }
    // SA_RESTART vs EINTR on a blocking pipe read
    {
        var fds: [2]i32 = undefined;
        _ = linux.pipe(&fds);
        var results: [2]bool = undefined;
        for ([_]u32{ posix.SA.RESTART, 0 }, 0..) |fl, i| {
            got_signal = 0;
            setHandler(posix.SIG.USR1, handler, fl);
            const pid = try posix.fork();
            if (pid == 0) {
                sleepMs(40);
                _ = linux.kill(linux.getppid(), posix.SIG.USR1);
                sleepMs(40);
                _ = linux.write(fds[1], "x", 1);
                linux.exit(0);
            }
            var b: [1]u8 = undefined;
            const r = linux.read(fds[0], &b, 1);
            if (fl != 0) {
                results[i] = r == 1 and got_signal == posix.SIG.USR1;
            } else {
                results[i] = errno(r) == .INTR and got_signal == posix.SIG.USR1;
                _ = linux.read(fds[0], &b, 1);
            }
            _ = posix.waitpid(pid, 0);
        }
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        check(results[0], "SA_RESTART restarts pipe read");
        check(results[1], "no SA_RESTART -> EINTR");
        setHandler(posix.SIG.USR1, handler, 0);
    }
    // stop / continue with WUNTRACED / WCONTINUED
    {
        const pid = try posix.fork();
        if (pid == 0) {
            while (true) _ = linux.pause();
        }
        sleepMs(20);
        var st: u32 = 0;
        _ = linux.kill(pid, posix.SIG.STOP);
        const r1 = wait4(pid, &st, 2); // WUNTRACED
        const stopped = r1 == pid and posix.W.IFSTOPPED(st) and posix.W.STOPSIG(st) == posix.SIG.STOP;
        _ = linux.kill(pid, posix.SIG.CONT);
        const r2 = wait4(pid, &st, 8); // WCONTINUED
        const cont = r2 == pid and st == 0xffff;
        _ = linux.kill(pid, posix.SIG.TSTP);
        const r3 = wait4(pid, &st, 2);
        const tstp = r3 == pid and posix.W.IFSTOPPED(st) and posix.W.STOPSIG(st) == posix.SIG.TSTP;
        _ = linux.kill(pid, posix.SIG.KILL);
        const r4 = wait4(pid, &st, 0);
        check(stopped and cont, "SIGSTOP/SIGCONT + WUNTRACED/WCONTINUED");
        check(tstp and r4 == pid and posix.W.IFSIGNALED(st) and posix.W.TERMSIG(st) == posix.SIG.KILL, "SIGTSTP stop, SIGKILL while stopped");
    }
    // waitid
    {
        const pid = try posix.fork();
        if (pid == 0) linux.exit(7);
        var info = std.mem.zeroes([32]i32);
        const r = linux.syscall5(.waitid, 1, @intCast(pid), @intFromPtr(&info), 4, 0); // P_PID, WEXITED
        check(r == 0 and info[0] == posix.SIG.CHLD and info[2] == 1 and info[4] == pid and info[6] == 7, "waitid(P_PID) siginfo");
    }
    // SIGCHLD = SIG_IGN -> children are auto-reaped
    {
        setHandler(posix.SIG.CHLD, posix.SIG.IGN, 0);
        const pid = try posix.fork();
        if (pid == 0) linux.exit(3);
        var st: u32 = 0;
        const r = wait4(-1, &st, 0);
        setHandler(posix.SIG.CHLD, posix.SIG.DFL, 0);
        check(r == -@as(isize, @intFromEnum(linux.E.CHILD)), "SIGCHLD SIG_IGN auto-reap (ECHILD)");
    }
}
