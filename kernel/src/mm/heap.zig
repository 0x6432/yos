//! Slab-based kernel heap.
//!
//! Small objects (<= 2048 bytes) come from per-size-class caches. Each slab
//! is a naturally aligned buddy block whose first bytes hold a `Slab` header;
//! every page of the slab is tagged `slab` in its descriptor, so `free` can
//! find the header by aligning the address down. Larger requests go straight
//! to the buddy allocator.
const std = @import("std");
const pmm = @import("pmm.zig");
const log = @import("../log.zig");
const SpinLock = @import("../sync.zig").SpinLock;

const FreeObj = struct { next: ?*FreeObj };

const Slab = struct {
    cache: *Cache,
    free: ?*FreeObj,
    inuse: u32,
    total: u32,
    next: ?*Slab,
    prev: ?*Slab,
};

pub const Cache = struct {
    name: []const u8,
    obj_size: usize,
    order: u8,
    partial: ?*Slab = null, // slabs with at least one free object
    full: ?*Slab = null,
    nslabs: usize = 0,
    lock: SpinLock = .{},

    fn slabBytes(self: *const Cache) usize {
        return pmm.PAGE_SIZE << @intCast(self.order);
    }
    fn firstOffset(self: *const Cache) usize {
        return std.mem.alignForward(usize, @sizeOf(Slab), @min(self.obj_size, 64));
    }

    fn unlink(list: *?*Slab, s: *Slab) void {
        if (s.prev) |p| p.next = s.next else list.* = s.next;
        if (s.next) |n| n.prev = s.prev;
        s.next = null;
        s.prev = null;
    }
    fn push(list: *?*Slab, s: *Slab) void {
        s.prev = null;
        s.next = list.*;
        if (list.*) |h| h.prev = s;
        list.* = s;
    }

    fn grow(self: *Cache) ?*Slab {
        const phys = pmm.allocPages(self.order) orelse return null;
        const npages = @as(usize, 1) << @intCast(self.order);
        for (0..npages) |i| {
            const pg = pmm.pageOf(phys + i * pmm.PAGE_SIZE);
            pg.flags = .{ .slab = true };
            pg.order = self.order;
        }
        const base = pmm.physToVirt(phys);
        const s: *Slab = @ptrFromInt(base);
        s.* = .{ .cache = self, .free = null, .inuse = 0, .total = 0, .next = null, .prev = null };
        var off = self.firstOffset();
        while (off + self.obj_size <= self.slabBytes()) : (off += self.obj_size) {
            const o: *FreeObj = @ptrFromInt(base + off);
            o.next = s.free;
            s.free = o;
            s.total += 1;
        }
        self.nslabs += 1;
        return s;
    }

    pub fn alloc(self: *Cache) ?[*]u8 {
        const e = self.lock.lock();
        defer self.lock.unlock(e);
        const s = self.partial orelse blk: {
            const ns = self.grow() orelse return null;
            push(&self.partial, ns);
            break :blk ns;
        };
        const o = s.free.?;
        s.free = o.next;
        s.inuse += 1;
        if (s.free == null) {
            unlink(&self.partial, s);
            push(&self.full, s);
        }
        return @ptrCast(o);
    }

    fn freeObj(self: *Cache, s: *Slab, p: [*]u8) void {
        const e = self.lock.lock();
        defer self.lock.unlock(e);
        const o: *FreeObj = @ptrCast(@alignCast(p));
        const was_full = s.free == null;
        o.next = s.free;
        s.free = o;
        s.inuse -= 1;
        if (was_full) {
            unlink(&self.full, s);
            push(&self.partial, s);
        }
        // Give empty slabs back to the buddy allocator (keep one around).
        if (s.inuse == 0 and !(self.partial == s and s.next == null)) {
            unlink(&self.partial, s);
            const phys = pmm.virtToPhys(@intFromPtr(s));
            const npages = @as(usize, 1) << @intCast(self.order);
            for (0..npages) |i| pmm.pageOf(phys + i * pmm.PAGE_SIZE).flags = .{};
            pmm.freePages(phys, self.order);
            self.nslabs -= 1;
        }
    }
};

const class_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const class_orders = [_]u8{ 0, 0, 0, 0, 0, 0, 1, 2 };
var caches: [class_sizes.len]Cache = blk: {
    var c: [class_sizes.len]Cache = undefined;
    for (class_sizes, class_orders, 0..) |sz, o, i| c[i] = .{ .name = "kmalloc", .obj_size = sz, .order = o };
    break :blk c;
};

fn classFor(size: usize) ?usize {
    for (class_sizes, 0..) |sz, i| if (size <= sz) return i;
    return null;
}

pub fn kmalloc(size: usize, alignment: usize) ?[*]u8 {
    const want = @max(size, alignment, 1);
    if (alignment <= 64 or alignment <= want) {
        if (classFor(want)) |ci| {
            // class objects are aligned to min(obj_size, 64); that is enough
            // as long as alignment <= 64 or alignment == size class.
            if (alignment <= @min(class_sizes[ci], 64)) return caches[ci].alloc();
        }
    }
    const order = pmm.orderFor(@max(want, alignment));
    const phys = pmm.allocPages(order) orelse return null;
    return @ptrFromInt(pmm.physToVirt(phys));
}

/// Usable size of an allocation.
pub fn ksize(p: [*]u8) usize {
    const phys = pmm.virtToPhys(@intFromPtr(p));
    const pg = pmm.pageOf(phys);
    if (pg.flags.slab) {
        const base = std.mem.alignBackward(u64, phys, pmm.PAGE_SIZE << @intCast(pg.order));
        const s: *Slab = pmm.ptr(*Slab, base);
        return s.cache.obj_size;
    }
    return pmm.PAGE_SIZE << @intCast(pg.order);
}

pub fn kfree(p: [*]u8) void {
    const phys = pmm.virtToPhys(@intFromPtr(p));
    const pg = pmm.pageOf(phys);
    if (pg.flags.slab) {
        const base = std.mem.alignBackward(u64, phys, pmm.PAGE_SIZE << @intCast(pg.order));
        const s: *Slab = pmm.ptr(*Slab, base);
        s.cache.freeObj(s, p);
    } else if (pg.flags.head) {
        pmm.freePages(phys, pg.order);
    } else {
        log.print("kfree: bad pointer {*}\n", .{p});
        @panic("kfree: pointer not owned by heap");
    }
}

// ---- std.mem.Allocator adapter ----
fn aAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return kmalloc(len, alignment.toByteUnits());
}
fn aResize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len <= ksize(mem.ptr);
}
fn aRemap(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return if (new_len <= ksize(mem.ptr)) mem.ptr else null;
}
fn aFree(_: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
    kfree(mem.ptr);
}

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = aAlloc, .resize = aResize, .remap = aRemap, .free = aFree },
};

pub fn selfTest() void {
    const before = pmm.free_pages;
    var ptrs: [300][*]u8 = undefined;
    for (&ptrs, 0..) |*p, i| {
        const sz = (i * 37) % 5000 + 1;
        p.* = kmalloc(sz, 8) orelse @panic("heap selftest: oom");
        @memset(p.*[0..sz], @truncate(i));
    }
    for (ptrs, 0..) |p, i| {
        const sz = (i * 37) % 5000 + 1;
        for (p[0..sz]) |b| if (b != @as(u8, @truncate(i))) @panic("heap selftest: corruption");
    }
    for (ptrs) |p| kfree(p);
    var list = std.ArrayList(u64).init(allocator);
    for (0..10000) |i| list.append(i) catch @panic("heap selftest: arraylist");
    list.deinit();
    const leaked = @as(isize, @intCast(before)) - @as(isize, @intCast(pmm.free_pages));
    log.info("heap: slab self test passed (residual cached slab pages: {d})", .{leaked});
}
