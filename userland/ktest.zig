//! Kernel self-test suite run from userspace.
const std = @import("std");
const sys = @import("lib/sys.zig");
const SIG = sys.SIG;
const W = sys.W;

var failures: u32 = 0;
var passed: u32 = 0;
var got_signal: i32 = 0;

fn check(ok: bool, what: []const u8) void {
    if (ok) passed += 1 else failures += 1;
    sys.print("[ktest] {s:<40} {s}\n", .{ what, if (ok) "ok" else "FAIL" });
}

fn freeRam() u64 {
    var si: [14]u64 = undefined;
    _ = sys.sys(.sysinfo, .{&si});
    return si[5];
}

fn handler(sig: i32) callconv(.c) void {
    got_signal = sig;
}

fn exists(path: []const u8) bool {
    var st: sys.Stat = undefined;
    return sys.stat(path, &st) == 0;
}

pub fn main() !void {
    // ---- files ----
    {
        const fd = try sys.open("/tmp/test.txt", sys.O.RDWR | sys.O.CREAT | sys.O.TRUNC, 0o644);
        try sys.writeAll(fd, "hello file");
        _ = sys.lseek(fd, 0, 0);
        var buf: [64]u8 = undefined;
        const n = try sys.readAll(fd, &buf);
        check(std.mem.eql(u8, buf[0..n], "hello file"), "file create/write/seek/read");
        sys.close(fd);
        var st: sys.Stat = undefined;
        check(sys.stat("/tmp/test.txt", &st) == 0 and st.size == 10, "stat size");
        _ = try sys.check(sys.mkdir("/tmp/dir", 0o755));
        var d = try sys.Dir.open("/tmp");
        var seen: u32 = 0;
        while (try d.next()) |e| {
            if (std.mem.eql(u8, e.name, "test.txt") or std.mem.eql(u8, e.name, "dir")) seen += 1;
        }
        d.close();
        check(seen == 2, "getdents64 directory listing");
        _ = try sys.check(sys.rename("/tmp/test.txt", "/tmp/dir/moved.txt"));
        check(exists("/tmp/dir/moved.txt"), "rename");
        _ = try sys.check(sys.unlink("/tmp/dir/moved.txt"));
        _ = try sys.check(sys.rmdir("/tmp/dir"));
        check(!exists("/tmp/dir"), "unlink + rmdir");
        _ = try sys.check(sys.symlink("/bin/hello", "/tmp/link"));
        var lb: [64]u8 = undefined;
        const l = try sys.readlink("/tmp/link", &lb);
        check(std.mem.eql(u8, l, "/bin/hello"), "symlink + readlink");
    }
    // ---- pipe + fork + exec + wait ----
    {
        var fds: [2]sys.fd_t = undefined;
        _ = try sys.check(sys.pipe(&fds));
        const pid = try sys.fork();
        if (pid == 0) {
            _ = sys.dup2(fds[1], 1);
            sys.close(fds[0]);
            sys.close(fds[1]);
            const argv = [_:null]?[*:0]const u8{"/tmp/link"};
            const envp = [_:null]?[*:0]const u8{};
            _ = sys.execve("/tmp/link", &argv, &envp);
            sys.exit(127);
        }
        sys.close(fds[1]);
        var buf: [256]u8 = undefined;
        const total = try sys.readAll(fds[0], &buf);
        sys.close(fds[0]);
        check(std.mem.indexOf(u8, buf[0..total], "Hello from userspace") != null, "fork + pipe + dup2 + execve (symlink)");
        const r = sys.waitpid(pid, 0);
        check(r.pid == pid and W.IFEXITED(r.status) and W.EXITSTATUS(r.status) == 0, "wait4 exit status 0");
    }
    {
        const pid = try sys.fork();
        if (pid == 0) sys.exit(42);
        const r = sys.waitpid(pid, 0);
        check(W.EXITSTATUS(r.status) == 42, "exit code propagation (42)");
    }
    // ---- signals ----
    {
        _ = sys.sigaction(SIG.USR1, &handler, 0, 0);
        _ = sys.kill(sys.getpid(), SIG.USR1);
        check(got_signal == SIG.USR1, "signal handler + sigreturn");
        const pid = try sys.fork();
        if (pid == 0) {
            while (true) _ = sys.pause();
        }
        sys.sleepMs(30);
        _ = sys.kill(pid, SIG.TERM);
        const r = sys.waitpid(pid, 0);
        check(W.IFSIGNALED(r.status) and W.TERMSIG(r.status) == SIG.TERM, "kill child with SIGTERM");
    }
    // ---- memory ----
    {
        const m = try sys.mmap(1 << 20, sys.PROT.READ | sys.PROT.WRITE);
        @memset(m, 0xAB);
        var ok = true;
        for (m) |b| if (b != 0xAB) {
            ok = false;
        };
        sys.munmap(m);
        check(ok, "mmap/munmap 1 MiB anonymous");
        const cur = sys.brk(0);
        const nb = sys.brk(cur + 65536);
        const p: [*]volatile u8 = @ptrFromInt(cur);
        p[65535] = 7;
        check(nb == cur + 65536 and p[65535] == 7, "brk grow");
        const big = try sys.mmap(3 << 20, sys.PROT.READ | sys.PROT.WRITE);
        @memset(big, 1);
        sys.munmap(big);
        check(true, "page allocator 3 MiB");
    }
    // ---- copy-on-write fork ----
    {
        const buf = try sys.mmap(4 << 20, sys.PROT.READ | sys.PROT.WRITE);
        defer sys.munmap(buf);
        @memset(buf, 0x11);
        const free_before = freeRam();
        const pid = try sys.fork();
        if (pid == 0) {
            // child: memory is shared until written
            var ok = true;
            for (buf) |b| if (b != 0x11) {
                ok = false;
            };
            const shared_cost = free_before -| freeRam();
            @memset(buf, 0x22);
            sys.exit(if (ok and shared_cost < (2 << 20)) 0 else 1);
        }
        const r = sys.waitpid(pid, 0);
        var intact = true;
        for (buf) |b| if (b != 0x11) {
            intact = false;
        };
        check(W.EXITSTATUS(r.status) == 0, "cow: child shares pages until write");
        check(intact, "cow: parent unaffected by child writes");
    }
    // ---- time ----
    {
        const t0 = sys.clockMonotonic();
        sys.sleepMs(50);
        const t1 = sys.clockMonotonic();
        const dt = (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
        if (!(dt >= 45 and dt < 1000)) sys.print("[ktest] dt={d}ms\n", .{dt});
        check(dt >= 45 and dt < 1000, "nanosleep 50ms / clock_gettime");
    }
    // ---- many processes ----
    {
        var ok = true;
        for (0..20) |i| {
            const pid = try sys.fork();
            if (pid == 0) sys.exit(@intCast(i));
            const r = sys.waitpid(pid, 0);
            if (W.EXITSTATUS(r.status) != i) ok = false;
        }
        check(ok, "20 sequential fork/wait");
    }
    // ---- full signals (M9) ----
    try signalTests();
    // ---- SMP (M11) ----
    try smpTests();
    if (failures == 0) {
        sys.print("[ktest] ALL {d} TESTS PASSED\n", .{passed});
    } else {
        sys.print("[ktest] {d} FAILED, {d} passed\n", .{ failures, passed });
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

fn infoHandler(_: i32, info: *const [32]i32, _: ?*anyopaque) callconv(.c) void {
    si_code = info[2];
    si_pid = info[4];
    si_value = info[6];
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

fn mask(how: u32, sig: u32) void {
    const set: u64 = sys.sigbit(sig);
    _ = sys.sigprocmask(how, &set, null);
}
fn wait4(pid: i32, status: *u32, opts: u32) isize {
    return sys.wait4(pid, status, opts);
}

fn signalTests() !void {
    const me = sys.getpid();
    // SA_SIGINFO: si_code / si_pid from kill()
    {
        _ = sys.sigaction(SIG.USR1, &infoHandler, sys.SA.SIGINFO, 0);
        _ = sys.kill(me, SIG.USR1);
        check(si_code == 0 and si_pid == me, "SA_SIGINFO si_code=SI_USER, si_pid");
        // rt_sigqueueinfo carries a value
        var info = std.mem.zeroes([32]i32);
        info[0] = SIG.USR1;
        info[2] = -1; // SI_QUEUE
        info[4] = me;
        info[6] = 1234;
        _ = sys.sys(.rt_sigqueueinfo, .{ me, @as(u32, SIG.USR1), &info });
        check(si_code == -1 and si_value == 1234, "rt_sigqueueinfo SI_QUEUE + value");
        _ = sys.sigaction(SIG.USR1, &handler, 0, 0);
    }
    // standard signals coalesce, real-time signals queue
    {
        const RT: u32 = 40;
        _ = sys.sigaction(RT, &rtHandler, 0, 0);
        _ = sys.sigaction(SIG.USR2, &usr2Handler, 0, 0);
        mask(0, RT);
        mask(0, SIG.USR2);
        _ = sys.kill(me, RT);
        _ = sys.kill(me, RT);
        _ = sys.kill(me, RT);
        _ = sys.kill(me, SIG.USR2);
        _ = sys.kill(me, SIG.USR2);
        var pend: u64 = 0;
        _ = sys.sys(.rt_sigpending, .{ &pend, @as(usize, 8) });
        const pend_ok = pend & sys.sigbit(RT) != 0 and pend & sys.sigbit(SIG.USR2) != 0;
        mask(1, RT);
        mask(1, SIG.USR2);
        check(pend_ok and rt_count == 3 and usr2_count == 1, "RT signals queue, standard coalesce");
    }
    // sigaltstack + SA_ONSTACK
    {
        const ss = [3]u64{ @intFromPtr(&altstack_buf), 0, altstack_buf.len };
        const rc = sys.sys(.sigaltstack, .{ &ss, @as(usize, 0) });
        _ = sys.sigaction(SIG.USR2, &altHandler, sys.SA.ONSTACK, 0);
        _ = sys.kill(me, SIG.USR2);
        const base = @intFromPtr(&altstack_buf);
        var old: [3]u64 = undefined;
        _ = sys.sys(.sigaltstack, .{ @as(usize, 0), &old });
        check(rc == 0 and alt_addr >= base and alt_addr < base + altstack_buf.len and old[0] == base, "sigaltstack / SA_ONSTACK");
        const dis = [3]u64{ 0, 2, 0 };
        _ = sys.sys(.sigaltstack, .{ &dis, @as(usize, 0) });
        _ = sys.sigaction(SIG.USR2, SIG.DFL, 0, 0);
    }
    // rt_sigtimedwait
    {
        mask(0, SIG.USR1);
        _ = sys.kill(me, SIG.USR1);
        const set: u64 = sys.sigbit(SIG.USR1);
        var info = std.mem.zeroes([32]i32);
        const ts = sys.timespec{ .sec = 1, .nsec = 0 };
        const r1 = sys.sys(.rt_sigtimedwait, .{ &set, &info, &ts, @as(usize, 8) });
        const ts2 = sys.timespec{ .sec = 0, .nsec = 30_000_000 };
        const r2 = sys.sys(.rt_sigtimedwait, .{ &set, @as(usize, 0), &ts2, @as(usize, 8) });
        mask(1, SIG.USR1);
        check(r1 == SIG.USR1 and info[4] == me and r2 == -11, "rt_sigtimedwait (hit + timeout)");
    }
    // alarm / setitimer -> SIGALRM
    {
        _ = sys.sigaction(SIG.ALRM, &alrmHandler, 0, 0);
        const it = [4]i64{ 0, 0, 0, 50_000 };
        _ = sys.sys(.setitimer, .{ @as(u32, 0), &it, @as(usize, 0) });
        _ = sys.pause();
        const a0 = sys.sys(.alarm, .{@as(u32, 5)});
        const a1 = sys.sys(.alarm, .{@as(u32, 0)});
        check(alrm == 1 and a0 == 0 and a1 == 5, "setitimer/alarm -> SIGALRM");
    }
    // SA_RESTART vs EINTR on a blocking pipe read
    {
        var fds: [2]sys.fd_t = undefined;
        _ = sys.pipe(&fds);
        var results: [2]bool = undefined;
        for ([_]u64{ sys.SA.RESTART, 0 }, 0..) |fl, i| {
            got_signal = 0;
            _ = sys.sigaction(SIG.USR1, &handler, fl, 0);
            const pid = try sys.fork();
            if (pid == 0) {
                sys.sleepMs(40);
                _ = sys.kill(sys.getppid(), SIG.USR1);
                sys.sleepMs(40);
                _ = sys.write(fds[1], "x");
                sys.exit(0);
            }
            var b: [1]u8 = undefined;
            const r = sys.read(fds[0], &b);
            if (fl != 0) {
                results[i] = r == 1 and got_signal == SIG.USR1;
            } else {
                results[i] = r == -4 and got_signal == SIG.USR1;
                _ = sys.read(fds[0], &b);
            }
            _ = sys.waitpid(pid, 0);
        }
        sys.close(fds[0]);
        sys.close(fds[1]);
        check(results[0], "SA_RESTART restarts pipe read");
        check(results[1], "no SA_RESTART -> EINTR");
        _ = sys.sigaction(SIG.USR1, &handler, 0, 0);
    }
    // stop / continue with WUNTRACED / WCONTINUED
    {
        const pid = try sys.fork();
        if (pid == 0) {
            while (true) _ = sys.pause();
        }
        sys.sleepMs(20);
        var st: u32 = 0;
        _ = sys.kill(pid, SIG.STOP);
        const r1 = wait4(pid, &st, 2); // WUNTRACED
        const stopped = r1 == pid and W.IFSTOPPED(st) and W.STOPSIG(st) == SIG.STOP;
        _ = sys.kill(pid, SIG.CONT);
        const r2 = wait4(pid, &st, 8); // WCONTINUED
        const cont = r2 == pid and st == 0xffff;
        _ = sys.kill(pid, SIG.TSTP);
        const r3 = wait4(pid, &st, 2);
        const tstp = r3 == pid and W.IFSTOPPED(st) and W.STOPSIG(st) == SIG.TSTP;
        _ = sys.kill(pid, SIG.KILL);
        const r4 = wait4(pid, &st, 0);
        check(stopped and cont, "SIGSTOP/SIGCONT + WUNTRACED/WCONTINUED");
        check(tstp and r4 == pid and W.IFSIGNALED(st) and W.TERMSIG(st) == SIG.KILL, "SIGTSTP stop, SIGKILL while stopped");
    }
    // waitid
    {
        const pid = try sys.fork();
        if (pid == 0) sys.exit(7);
        var info = std.mem.zeroes([32]i32);
        const r = sys.sys(.waitid, .{ @as(u32, 1), pid, &info, @as(u32, 4), @as(usize, 0) }); // P_PID, WEXITED
        check(r == 0 and info[0] == SIG.CHLD and info[2] == 1 and info[4] == pid and info[6] == 7, "waitid(P_PID) siginfo");
    }
    // SIGCHLD = SIG_IGN -> children are auto-reaped
    {
        _ = sys.sigaction(SIG.CHLD, SIG.IGN, 0, 0);
        const pid = try sys.fork();
        if (pid == 0) sys.exit(3);
        var st: u32 = 0;
        const r = wait4(-1, &st, 0);
        _ = sys.sigaction(SIG.CHLD, SIG.DFL, 0, 0);
        check(r == -10, "SIGCHLD SIG_IGN auto-reap (ECHILD)");
    }
}

// ------------------------------------------------------------------
// M11 SMP tests
// ------------------------------------------------------------------
fn spin(iters: u64) u64 {
    var x: u64 = 1;
    var i: u64 = 0;
    while (i < iters) : (i += 1) x = x *% 6364136223846793005 +% 1442695040888963407;
    return x;
}

fn runSpinners(n: usize, iters: u64) !i64 {
    const t0 = sys.clockMonotonic();
    var pids: [8]i32 = undefined;
    for (0..n) |i| {
        const pid = try sys.fork();
        if (pid == 0) {
            std.mem.doNotOptimizeAway(spin(iters));
            sys.exit(0);
        }
        pids[i] = pid;
    }
    for (pids[0..n]) |p| _ = sys.waitpid(p, 0);
    const t1 = sys.clockMonotonic();
    return (t1.sec - t0.sec) * 1000 + @divTrunc(t1.nsec - t0.nsec, 1_000_000);
}

fn smpTests() !void {
    var m: u64 = 0;
    const r = sys.sys(.sched_getaffinity, .{ @as(usize, 0), @as(usize, 8), &m });
    const ncpu = @popCount(m);
    check(r == 8 and ncpu >= 1, "sched_getaffinity reports online CPUs");
    // calibrate ~150ms of work on one CPU, then run 4 copies at once
    var iters: u64 = 2_000_000;
    var t1 = try runSpinners(1, iters);
    while (t1 < 100 and iters < (1 << 34)) {
        iters *= 2;
        t1 = try runSpinners(1, iters);
    }
    const t4 = try runSpinners(4, iters);
    const par = @min(ncpu, 4);
    sys.print("[ktest] smp: {d} cpus, 1 job {d}ms, 4 jobs {d}ms (ideal {d}ms)\n", .{ ncpu, t1, t4, @divTrunc(t1 * 4, @as(i64, @intCast(par))) });
    // all 4 must finish; with >1 CPU they must overlap at least somewhat
    check(t4 > 0 and (ncpu == 1 or t4 < t1 * 4 - @divTrunc(t1, 4)), "parallel jobs overlap across CPUs");
    // fork storm across CPUs: many short-lived children, all reaped
    var ok = true;
    var live: [16]i32 = undefined;
    for (0..8) |_| {
        for (&live, 0..) |*p, i| {
            p.* = try sys.fork();
            if (p.* == 0) {
                std.mem.doNotOptimizeAway(spin(1000 * (i + 1)));
                sys.exit(@intCast(i));
            }
        }
        for (live, 0..) |p, i| {
            const w = sys.waitpid(p, 0);
            if (w.pid != p or W.EXITSTATUS(w.status) != i) ok = false;
        }
    }
    check(ok, "fork storm: 128 children across CPUs");
}
