//! Serial console TTY with a small POSIX line discipline.
const std = @import("std");
const cpu = @import("../arch/cpu.zig");
const serial = @import("../serial.zig");
const apic = @import("apic.zig");
const vfs = @import("../vfs.zig");
const sched = @import("../sched.zig");
const proc = @import("../proc.zig");
const signal = @import("../signal.zig");
const E = @import("../errno.zig");

// termios bits
const ICRNL: u32 = 0o400;
const IXON: u32 = 0o2000;
const OPOST: u32 = 1;
const ONLCR: u32 = 4;
const ISIG: u32 = 1;
const ICANON: u32 = 2;
const ECHO: u32 = 0o10;
const ECHOE: u32 = 0o20;
const ECHOK: u32 = 0o40;
const ECHOCTL: u32 = 0o1000;
const ECHOKE: u32 = 0o4000;
const IEXTEN: u32 = 0o100000;
const VINTR = 0;
const VQUIT = 1;
const VERASE = 2;
const VKILL = 3;
const VEOF = 4;
const VTIME = 5;
const VMIN = 6;
const VSUSP = 10;
const VWERASE = 14;

pub const Termios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [19]u8,
};

const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

var termios: Termios = .{
    .iflag = ICRNL | IXON,
    .oflag = OPOST | ONLCR,
    .cflag = 0o277, // B38400 | CS8 | CREAD
    .lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN,
    .line = 0,
    .cc = .{ 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0 },
};
var winsize: Winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
pub var fg_pgrp: i32 = 1;
pub var session: i32 = 0;

// cooked input ready for read()
var ready_buf: [4096]u8 = undefined;
var ready_head: usize = 0;
var ready_len: usize = 0;
var eof_pending: u32 = 0;
// line being edited (canonical mode)
var line: [1024]u8 = undefined;
var line_len: usize = 0;
var rq: sched.WaitQueue = .{};

fn out(c: u8) void {
    if (termios.oflag & OPOST != 0 and termios.oflag & ONLCR != 0 and c == '\n') serial.putc('\r');
    serial.putc(c);
}

fn pushReady(c: u8) void {
    if (ready_len == ready_buf.len) return;
    ready_buf[(ready_head + ready_len) % ready_buf.len] = c;
    ready_len += 1;
}

fn echoChar(c: u8) void {
    if (termios.lflag & ECHO == 0) return;
    if (c < 32 and c != '\n' and c != '\t' and termios.lflag & ECHOCTL != 0) {
        serial.putc('^');
        serial.putc(c + 64);
    } else out(c);
}

fn input(c_in: u8) void {
    var c = c_in;
    if (c == '\r' and termios.iflag & ICRNL != 0) c = '\n';
    const cc = termios.cc;
    if (termios.lflag & ISIG != 0) {
        if (c == cc[VINTR] or c == cc[VQUIT] or c == cc[VSUSP]) {
            const sig: u32 = if (c == cc[VINTR]) signal.SIGINT else if (c == cc[VQUIT]) signal.SIGQUIT else signal.SIGTSTP;
            echoChar(c);
            if (termios.lflag & ICANON != 0) line_len = 0;
            _ = signal.sendGroup(fg_pgrp, sig);
            if (termios.lflag & ECHO != 0) out('\n');
            return;
        }
    }
    if (termios.lflag & ICANON != 0) {
        if (c == cc[VERASE] or c == 8) {
            if (line_len > 0) {
                line_len -= 1;
                if (termios.lflag & ECHO != 0) serial.writeRaw("\x08 \x08");
            }
            return;
        }
        if (c == cc[VKILL]) {
            while (line_len > 0) : (line_len -= 1) {
                if (termios.lflag & ECHO != 0) serial.writeRaw("\x08 \x08");
            }
            return;
        }
        if (c == cc[VEOF]) {
            for (line[0..line_len]) |x| pushReady(x);
            if (line_len == 0) eof_pending += 1;
            line_len = 0;
            wakeReaders();
            return;
        }
        if (c == '\n') {
            echoChar(c);
            for (line[0..line_len]) |x| pushReady(x);
            pushReady('\n');
            line_len = 0;
            wakeReaders();
            return;
        }
        if (line_len < line.len) {
            line[line_len] = c;
            line_len += 1;
            echoChar(c);
        }
        return;
    }
    echoChar(c);
    pushReady(c);
    wakeReaders();
}

fn wakeReaders() void {
    rq.wakeAll();
    vfs.poll_wq.wakeAll();
}

fn onIrq(_: ?*anyopaque) void {
    while (serial.hasData()) input(serial.getc());
}

fn ttyRead(f: *vfs.File, buf: []u8) isize {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    // background process group reading the terminal: SIGTTIN
    if (proc.currentOrNull()) |p| {
        if (fg_pgrp != 0 and p.pgid != fg_pgrp) {
            const a = p.sig.actions[signal.SIGTTIN];
            if (a.handler == signal.SIG_IGN or p.sig.blocked & signal.bit(signal.SIGTTIN) != 0) return -E.EIO;
            _ = signal.sendGroup(p.pgid, signal.SIGTTIN);
            return -signal.ERESTARTSYS;
        }
    }
    while (ready_len == 0 and eof_pending == 0) {
        if (f.flags & vfs.O_NONBLOCK != 0) return -E.EAGAIN;
        if (signal.hasPending()) return -signal.ERESTARTSYS;
        // poll the UART too, in case an interrupt was lost
        onIrq(null);
        if (ready_len != 0 or eof_pending != 0) break;
        rq.waitLocked();
    }
    if (ready_len == 0 and eof_pending > 0) {
        eof_pending -= 1;
        return 0;
    }
    var n: usize = 0;
    const canon = termios.lflag & ICANON != 0;
    while (n < buf.len and ready_len > 0) {
        const c = ready_buf[ready_head];
        ready_head = (ready_head + 1) % ready_buf.len;
        ready_len -= 1;
        buf[n] = c;
        n += 1;
        if (canon and c == '\n') break;
    }
    return @intCast(n);
}

fn ttyWrite(_: *vfs.File, buf: []const u8) isize {
    for (buf) |c| out(c);
    return @intCast(buf.len);
}

fn ttyPoll(_: *vfs.File, events: u16) u16 {
    var r: u16 = vfs.POLLOUT;
    if (ready_len > 0 or eof_pending > 0) r |= vfs.POLLIN;
    return r & events;
}

fn ttyIoctl(_: *vfs.File, req: u64, arg: u64) isize {
    switch (req) {
        0x5401 => { // TCGETS
            proc.writeUser(Termios, arg, termios) catch return -E.EFAULT;
            return 0;
        },
        0x5402, 0x5403, 0x5404 => { // TCSETS, TCSETSW, TCSETSF
            const t = proc.readUser(Termios, arg) catch return -E.EFAULT;
            const e = cpu.saveDisable();
            defer cpu.restore(e);
            const was_canon = termios.lflag & ICANON != 0;
            termios = t;
            if (req == 0x5404) {
                ready_len = 0;
                line_len = 0;
            }
            // leaving canonical mode: hand the partial line to readers
            if (was_canon and termios.lflag & ICANON == 0 and line_len > 0) {
                for (line[0..line_len]) |x| pushReady(x);
                line_len = 0;
            }
            return 0;
        },
        0x5413 => { // TIOCGWINSZ
            proc.writeUser(Winsize, arg, winsize) catch return -E.EFAULT;
            return 0;
        },
        0x5414 => {
            winsize = proc.readUser(Winsize, arg) catch return -E.EFAULT;
            return 0;
        },
        0x540F => { // TIOCGPGRP
            proc.writeUser(i32, arg, fg_pgrp) catch return -E.EFAULT;
            return 0;
        },
        0x5410 => { // TIOCSPGRP
            fg_pgrp = proc.readUser(i32, arg) catch return -E.EFAULT;
            return 0;
        },
        0x5429 => { // TIOCGSID
            proc.writeUser(i32, arg, if (session != 0) session else 1) catch return -E.EFAULT;
            return 0;
        },
        0x540E => { // TIOCSCTTY
            session = proc.current().sid;
            fg_pgrp = proc.current().pgid;
            return 0;
        },
        0x5422 => return 0, // TIOCNOTTY
        0x541B => { // FIONREAD
            proc.writeUser(i32, arg, @intCast(ready_len)) catch return -E.EFAULT;
            return 0;
        },
        0x5409, 0x540A, 0x540B => return 0, // TCSBRK, TCXONC, TCFLSH
        0x5421 => return 0, // FIONBIO handled by caller
        else => return -E.ENOTTY,
    }
}

pub const ops = vfs.DevOps{ .read = ttyRead, .write = ttyWrite, .ioctl = ttyIoctl, .poll = ttyPoll };

pub fn init() void {
    vfs.addDevice("console", &ops, 0x0501) catch {};
    vfs.addDevice("tty", &ops, 0x0500) catch {};
    vfs.addDevice("ttyS0", &ops, 0x0440) catch {};
    apic.routeIsa(4, onIrq, null);
    serial.enableRxInterrupt();
}

pub fn isTty(f: *vfs.File) bool {
    if (f.node) |n| return n.dev == &ops;
    return false;
}
