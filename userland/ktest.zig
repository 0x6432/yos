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
    if (failures == 0) {
        out("[ktest] ALL {d} TESTS PASSED\n", .{passed});
    } else {
        out("[ktest] {d} FAILED, {d} passed\n", .{ failures, passed });
    }
}
