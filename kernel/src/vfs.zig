//! Virtual file system: an in-memory tree (ramfs) populated from the initrd,
//! device nodes, pipes and the open-file layer.
const std = @import("std");
const heap = @import("mm/heap.zig");
const initrd = @import("initrd.zig");
const log = @import("log.zig");
const time = @import("time.zig");
const sched = @import("sched.zig");
const cpu = @import("arch/cpu.zig");
const E = @import("errno.zig");
const proc = @import("proc.zig");
const signal = @import("signal.zig");

const alloc = heap.allocator;

pub const S_IFMT = 0o170000;
pub const S_IFREG = 0o100000;
pub const S_IFDIR = 0o040000;
pub const S_IFLNK = 0o120000;
pub const S_IFCHR = 0o020000;
pub const S_IFIFO = 0o010000;

pub const O_ACCMODE = 3;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_CREAT = 0o100;
pub const O_EXCL = 0o200;
pub const O_NOCTTY = 0o400;
pub const O_TRUNC = 0o1000;
pub const O_APPEND = 0o2000;
pub const O_NONBLOCK = 0o4000;
pub const O_DIRECTORY = 0o200000;
pub const O_NOFOLLOW = 0o400000;
pub const O_CLOEXEC = 0o2000000;
pub const O_PATH = 0o10000000;

pub const Kind = enum { file, dir, symlink, chardev, fifo };

/// Device driver vtable for character devices.
pub const DevOps = struct {
    read: *const fn (f: *File, buf: []u8) isize,
    write: *const fn (f: *File, buf: []const u8) isize,
    ioctl: ?*const fn (f: *File, req: u64, arg: u64) isize = null,
    poll: ?*const fn (f: *File, events: u16) u16 = null,
};

pub const Node = struct {
    kind: Kind,
    mode: u32, // permission bits only
    ino: u64,
    uid: u32 = 0,
    gid: u32 = 0,
    mtime: i64 = 0,
    nlink: u32 = 1,
    parent: ?*Node = null,
    name: []u8 = &.{},
    children: std.ArrayListUnmanaged(*Node) = .{},
    data: std.ArrayListUnmanaged(u8) = .{},
    /// initrd-backed content until first write (copy on write)
    ro_data: ?[]const u8 = null,
    link: []u8 = &.{},
    dev: ?*const DevOps = null,
    rdev: u32 = 0,
    open_count: u32 = 0,
    unlinked: bool = false,

    pub fn size(self: *const Node) u64 {
        return switch (self.kind) {
            .file => if (self.ro_data) |r| r.len else self.data.items.len,
            .symlink => self.link.len,
            .dir => 4096,
            else => 0,
        };
    }
    pub fn contents(self: *const Node) []const u8 {
        return if (self.ro_data) |r| r else self.data.items;
    }
    fn makeWritable(self: *Node) !void {
        if (self.ro_data) |r| {
            try self.data.appendSlice(alloc, r);
            self.ro_data = null;
        }
    }
    pub fn fullMode(self: *const Node) u32 {
        const t: u32 = switch (self.kind) {
            .file => S_IFREG,
            .dir => S_IFDIR,
            .symlink => S_IFLNK,
            .chardev => S_IFCHR,
            .fifo => S_IFIFO,
        };
        return t | (self.mode & 0o7777);
    }
    pub fn lookup(self: *Node, name: []const u8) ?*Node {
        for (self.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
    pub fn truncate(self: *Node, len: u64) !void {
        try self.makeWritable();
        const old = self.data.items.len;
        try self.data.resize(alloc, len);
        if (len > old) @memset(self.data.items[old..], 0);
        self.mtime = now();
    }
};

var next_ino: u64 = 1;
pub var root: *Node = undefined;

pub fn now() i64 {
    return time.boot_epoch + @as(i64, @intCast(time.now() / time.HZ));
}

pub fn newNode(kind: Kind, mode: u32) !*Node {
    const n = try alloc.create(Node);
    n.* = .{ .kind = kind, .mode = mode, .ino = next_ino, .mtime = now() };
    next_ino += 1;
    if (kind == .dir) n.nlink = 2;
    return n;
}

pub fn addChild(dir: *Node, name: []const u8, child: *Node) !void {
    child.name = try alloc.dupe(u8, name);
    child.parent = dir;
    try dir.children.append(alloc, child);
    dir.mtime = now();
}

pub fn removeChild(dir: *Node, child: *Node) void {
    for (dir.children.items, 0..) |c, i| if (c == child) {
        _ = dir.children.orderedRemove(i);
        break;
    };
    child.unlinked = true;
    dir.mtime = now();
}

// ---------------- path resolution ----------------
pub const Error = error{ NotFound, NotDir, Loop, NameTooLong, Exists, IsDir, NoMem, Inval, NotEmpty, Access, Fault, Busy };

pub fn errno(e: anyerror) isize {
    return -@as(isize, switch (e) {
        error.NotFound => E.ENOENT,
        error.NotDir => E.ENOTDIR,
        error.Loop => E.ELOOP,
        error.NameTooLong => E.ENAMETOOLONG,
        error.Exists => E.EEXIST,
        error.IsDir => E.EISDIR,
        error.NoMem, error.OutOfMemory => E.ENOMEM,
        error.NotEmpty => E.ENOTEMPTY,
        error.Access => E.EACCES,
        error.Fault => E.EFAULT,
        error.Busy => E.EBUSY,
        else => E.EINVAL,
    });
}

fn resolveInner(start: *Node, path: []const u8, follow_last: bool, depth: u32) Error!*Node {
    if (depth > 8) return error.Loop;
    var cur: *Node = if (path.len > 0 and path[0] == '/') root else start;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        const last = it.peek() == null;
        if (cur.kind != .dir) return error.NotDir;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            cur = cur.parent orelse root;
            continue;
        }
        if (comp.len > 255) return error.NameTooLong;
        var nxt = cur.lookup(comp) orelse return error.NotFound;
        if (nxt.kind == .symlink and (!last or follow_last)) {
            nxt = try resolveInner(cur, nxt.link, true, depth + 1);
        }
        cur = nxt;
    }
    // trailing slash requires a directory
    if (path.len > 1 and path[path.len - 1] == '/' and cur.kind != .dir) return error.NotDir;
    return cur;
}

pub fn resolve(start: *Node, path: []const u8, follow_last: bool) Error!*Node {
    if (path.len == 0) return error.NotFound;
    return resolveInner(start, path, follow_last, 0);
}

pub const ParentRes = struct { dir: *Node, name: []const u8 };
pub fn resolveParent(start: *Node, path: []const u8) Error!ParentRes {
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return error.NotFound;
    const slash = std.mem.lastIndexOfScalar(u8, p, '/');
    const name = if (slash) |s| p[s + 1 ..] else p;
    const dir_path = if (slash) |s| (if (s == 0) "/" else p[0..s]) else ".";
    const dir = try resolve(start, dir_path, true);
    if (dir.kind != .dir) return error.NotDir;
    if (name.len > 255) return error.NameTooLong;
    return .{ .dir = dir, .name = name };
}

/// Absolute path of a node (for getcwd).
pub fn pathOf(n: *Node, buf: []u8) []const u8 {
    if (n == root) {
        buf[0] = '/';
        return buf[0..1];
    }
    var end = buf.len;
    var cur: ?*Node = n;
    while (cur) |c| : (cur = c.parent) {
        if (c == root) break;
        if (end < c.name.len + 1) break;
        end -= c.name.len;
        @memcpy(buf[end .. end + c.name.len], c.name);
        end -= 1;
        buf[end] = '/';
    }
    return buf[end..];
}

pub fn mkdirP(path: []const u8, mode: u32) !*Node {
    var cur = root;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (cur.lookup(comp)) |c| {
            cur = c;
        } else {
            const d = try newNode(.dir, mode);
            try addChild(cur, comp, d);
            cur = d;
        }
    }
    return cur;
}

// ---------------- open files ----------------
pub const Pipe = struct {
    buf: [16384]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    readers: u32 = 0,
    writers: u32 = 0,
    wq: sched.WaitQueue = .{},
};

pub const File = struct {
    refs: u32 = 1,
    flags: u32,
    off: u64 = 0,
    node: ?*Node = null,
    pipe: ?*Pipe = null,
    pipe_write: bool = false,

    pub fn readable(self: *const File) bool {
        return self.flags & O_ACCMODE != O_WRONLY;
    }
    pub fn writable(self: *const File) bool {
        const m = self.flags & O_ACCMODE;
        return m == O_WRONLY or m == O_RDWR;
    }
};

/// Wakes poll()/select() sleepers on any I/O activity.
pub var poll_wq: sched.WaitQueue = .{};

pub fn openNode(n: *Node, flags: u32) !*File {
    const f = try alloc.create(File);
    f.* = .{ .flags = flags, .node = n };
    n.open_count += 1;
    return f;
}

pub fn ref(f: *File) *File {
    f.refs += 1;
    return f;
}

pub fn release(f: *File) void {
    f.refs -= 1;
    if (f.refs > 0) return;
    if (f.pipe) |p| {
        if (f.pipe_write) p.writers -= 1 else p.readers -= 1;
        p.wq.wakeAll();
        poll_wq.wakeAll();
        if (p.readers == 0 and p.writers == 0) alloc.destroy(p);
    }
    if (f.node) |n| n.open_count -= 1;
    alloc.destroy(f);
}

pub fn makePipe() ![2]*File {
    const p = try alloc.create(Pipe);
    p.* = .{ .readers = 1, .writers = 1 };
    const r = try alloc.create(File);
    r.* = .{ .flags = 0, .pipe = p };
    const w = try alloc.create(File);
    w.* = .{ .flags = O_WRONLY, .pipe = p, .pipe_write = true };
    return .{ r, w };
}

fn pipeRead(f: *File, buf: []u8) isize {
    const p = f.pipe.?;
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    while (p.len == 0) {
        if (p.writers == 0) return 0;
        if (f.flags & O_NONBLOCK != 0) return -E.EAGAIN;
        if (signal.hasPending()) return -signal.ERESTARTSYS;
        p.wq.waitLocked();
    }
    var n: usize = 0;
    while (n < buf.len and p.len > 0) {
        buf[n] = p.buf[p.head];
        p.head = (p.head + 1) % p.buf.len;
        p.len -= 1;
        n += 1;
    }
    p.wq.wakeAll();
    poll_wq.wakeAll();
    return @intCast(n);
}

fn pipeWrite(f: *File, buf: []const u8) isize {
    const p = f.pipe.?;
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    var n: usize = 0;
    while (n < buf.len) {
        if (p.readers == 0) {
            signal.sendSignal(proc.current(), signal.SIGPIPE);
            return if (n > 0) @intCast(n) else -E.EPIPE;
        }
        if (p.len == p.buf.len) {
            if (f.flags & O_NONBLOCK != 0) return if (n > 0) @intCast(n) else -E.EAGAIN;
            if (signal.hasPending()) return if (n > 0) @intCast(n) else -signal.ERESTARTSYS;
            p.wq.wakeAll();
            p.wq.waitLocked();
            continue;
        }
        p.buf[(p.head + p.len) % p.buf.len] = buf[n];
        p.len += 1;
        n += 1;
    }
    p.wq.wakeAll();
    poll_wq.wakeAll();
    return @intCast(n);
}

pub fn read(f: *File, buf: []u8) isize {
    if (!f.readable()) return -E.EBADF;
    if (f.pipe != null) return pipeRead(f, buf);
    const n = f.node orelse return -E.EBADF;
    switch (n.kind) {
        .file => {
            const c = n.contents();
            if (f.off >= c.len) return 0;
            const cnt = @min(buf.len, c.len - f.off);
            @memcpy(buf[0..cnt], c[f.off .. f.off + cnt]);
            f.off += cnt;
            return @intCast(cnt);
        },
        .dir => return -E.EISDIR,
        .chardev => return n.dev.?.read(f, buf),
        else => return -E.EINVAL,
    }
}

pub fn pread(f: *File, buf: []u8, off: u64) isize {
    const saved = f.off;
    f.off = off;
    const r = read(f, buf);
    f.off = saved;
    return r;
}

pub fn write(f: *File, buf: []const u8) isize {
    if (!f.writable()) return -E.EBADF;
    if (f.pipe != null) return pipeWrite(f, buf);
    const n = f.node orelse return -E.EBADF;
    switch (n.kind) {
        .file => {
            n.makeWritable() catch return -E.ENOMEM;
            if (f.flags & O_APPEND != 0) f.off = n.data.items.len;
            const end = f.off + buf.len;
            if (end > n.data.items.len) {
                const old = n.data.items.len;
                n.data.resize(alloc, end) catch return -E.ENOSPC;
                if (f.off > old) @memset(n.data.items[old..f.off], 0);
            }
            @memcpy(n.data.items[f.off..end], buf);
            f.off = end;
            n.mtime = now();
            return @intCast(buf.len);
        },
        .dir => return -E.EISDIR,
        .chardev => return n.dev.?.write(f, buf),
        else => return -E.EINVAL,
    }
}

pub const POLLIN = 1;
pub const POLLOUT = 4;
pub const POLLERR = 8;
pub const POLLHUP = 16;

pub fn poll(f: *File, events: u16) u16 {
    if (f.pipe) |p| {
        var r: u16 = 0;
        if (f.pipe_write) {
            if (p.readers == 0) r |= POLLERR;
            if (p.len < p.buf.len) r |= POLLOUT;
        } else {
            if (p.len > 0) r |= POLLIN;
            if (p.writers == 0) r |= POLLHUP;
        }
        return r & (events | POLLERR | POLLHUP);
    }
    if (f.node) |n| if (n.kind == .chardev) if (n.dev.?.poll) |pf| return pf(f, events);
    return events & (POLLIN | POLLOUT);
}

pub fn closeAll(p: *proc.Process) void {
    for (&p.fds) |*fd| {
        if (fd.*) |f| release(f);
        fd.* = null;
    }
}

// ---------------- simple devices ----------------
fn nullRead(_: *File, _: []u8) isize {
    return 0;
}
fn nullWrite(_: *File, b: []const u8) isize {
    return @intCast(b.len);
}
fn zeroRead(_: *File, b: []u8) isize {
    @memset(b, 0);
    return @intCast(b.len);
}
var rng_state: u64 = 0x9E3779B97F4A7C15;
pub fn randomBytes(b: []u8) void {
    rng_state ^= cpu.rdtsc();
    for (b) |*x| {
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        x.* = @truncate(rng_state);
    }
}
fn randRead(_: *File, b: []u8) isize {
    randomBytes(b);
    return @intCast(b.len);
}
const null_ops = DevOps{ .read = nullRead, .write = nullWrite };
const zero_ops = DevOps{ .read = zeroRead, .write = nullWrite };
const rand_ops = DevOps{ .read = randRead, .write = nullWrite };

pub fn addDevice(name: []const u8, ops: *const DevOps, rdev: u32) !void {
    const dev = try mkdirP("dev", 0o755);
    const n = try newNode(.chardev, 0o666);
    n.dev = ops;
    n.rdev = rdev;
    try addChild(dev, name, n);
}

pub fn init() void {
    root = newNode(.dir, 0o755) catch @panic("vfs");
    var files: usize = 0;
    var it = initrd.Iterator{};
    while (it.next()) |e| {
        const res = resolveParent(root, e.name) catch blk: {
            // create missing parent dirs
            const slash = std.mem.lastIndexOfScalar(u8, e.name, '/') orelse break :blk null;
            _ = mkdirP(e.name[0..slash], 0o755) catch break :blk null;
            break :blk resolveParent(root, e.name) catch null;
        } orelse continue;
        if (res.dir.lookup(res.name)) |existing| {
            if (e.kind == '5' and existing.kind == .dir) existing.mode = e.mode & 0o7777;
            continue;
        }
        const node = switch (e.kind) {
            '5' => newNode(.dir, e.mode & 0o7777),
            '2' => blk: {
                const n = newNode(.symlink, 0o777) catch break :blk error.OutOfMemory;
                n.link = alloc.dupe(u8, e.link) catch break :blk error.OutOfMemory;
                break :blk n;
            },
            else => blk: {
                const n = newNode(.file, e.mode & 0o7777) catch break :blk error.OutOfMemory;
                n.ro_data = e.data;
                files += 1;
                break :blk n;
            },
        } catch @panic("vfs: oom");
        node.mtime = @intCast(e.mtime);
        addChild(res.dir, res.name, node) catch @panic("vfs: oom");
    }
    _ = mkdirP("tmp", 0o1777) catch {};
    _ = mkdirP("root", 0o700) catch {};
    _ = mkdirP("proc", 0o555) catch {};
    addDevice("null", &null_ops, 0x0103) catch {};
    addDevice("zero", &zero_ops, 0x0105) catch {};
    addDevice("random", &rand_ops, 0x0108) catch {};
    addDevice("urandom", &rand_ops, 0x0109) catch {};
    log.info("vfs: ramfs populated from initrd ({d} files, {d} KiB image)", .{ files, initrd.image.len / 1024 });
}
