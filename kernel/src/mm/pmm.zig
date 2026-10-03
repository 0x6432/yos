//! Buddy physical page allocator.
//!
//! Every physical page frame has a `Page` descriptor. Free blocks of 2^order
//! pages are kept on per-order doubly linked lists threaded through the
//! descriptors of their first page.
const std = @import("std");
const limine = @import("../limine.zig");
const log = @import("../log.zig");
const SpinLock = @import("../sync.zig").SpinLock;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_ORDER: u8 = 10; // largest block: 2^10 pages = 4 MiB
const NONE: u32 = std.math.maxInt(u32);

pub const PageFlags = packed struct(u16) {
    free: bool = false, // head of a free buddy block
    reserved: bool = false, // not managed (firmware, kernel, holes)
    slab: bool = false, // owned by the slab allocator
    head: bool = false, // head of an allocated multi-page block
    _pad: u12 = 0,
};

pub const Page = extern struct {
    flags: PageFlags = .{ .reserved = true },
    order: u8 = 0,
    _pad: u8 = 0,
    refcount: u32 = 0,
    next: u32 = NONE,
    prev: u32 = NONE,
};

var pages: []Page = &.{};
var free_heads: [MAX_ORDER + 1]u32 = [_]u32{NONE} ** (MAX_ORDER + 1);
var free_counts: [MAX_ORDER + 1]usize = [_]usize{0} ** (MAX_ORDER + 1);
var lock: SpinLock = .{};
pub var hhdm: u64 = 0;
pub var total_pages: usize = 0;
pub var free_pages: usize = 0;

pub inline fn physToVirt(p: u64) u64 {
    return p + hhdm;
}
pub inline fn virtToPhys(v: u64) u64 {
    return v - hhdm;
}
pub inline fn ptr(comptime T: type, phys: u64) T {
    return @ptrFromInt(phys + hhdm);
}

pub fn pageOf(phys: u64) *Page {
    return &pages[phys / PAGE_SIZE];
}
pub fn pfnOf(p: *const Page) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(pages.ptr)) / @sizeOf(Page));
}

fn listPush(order: u8, pfn: u32) void {
    const p = &pages[pfn];
    p.flags = .{ .free = true };
    p.order = order;
    p.prev = NONE;
    p.next = free_heads[order];
    if (free_heads[order] != NONE) pages[free_heads[order]].prev = pfn;
    free_heads[order] = pfn;
    free_counts[order] += 1;
}

fn listRemove(order: u8, pfn: u32) void {
    const p = &pages[pfn];
    if (p.prev != NONE) pages[p.prev].next = p.next else free_heads[order] = p.next;
    if (p.next != NONE) pages[p.next].prev = p.prev;
    p.next = NONE;
    p.prev = NONE;
    p.flags = .{};
    free_counts[order] -= 1;
}

fn freeBlockLocked(pfn_in: u32, order_in: u8) void {
    var pfn = pfn_in;
    var order = order_in;
    free_pages += @as(usize, 1) << @intCast(order);
    while (order < MAX_ORDER) {
        const buddy = pfn ^ (@as(u32, 1) << @intCast(order));
        if (buddy >= pages.len) break;
        const b = &pages[buddy];
        if (!b.flags.free or b.order != order) break;
        listRemove(order, buddy);
        pfn = @min(pfn, buddy);
        order += 1;
    }
    listPush(order, pfn);
}

pub fn init() void {
    hhdm = limine.hhdm().offset;
    const mm = limine.memmap();
    const entries = mm.entries[0..mm.entry_count];

    var top: u64 = 0;
    for (entries) |e| {
        switch (e.kind) {
            .usable, .bootloader_reclaimable, .executable_and_modules, .acpi_reclaimable, .acpi_nvs => top = @max(top, e.base + e.length),
            else => {},
        }
    }
    const npages: usize = @intCast(std.math.divCeil(u64, top, PAGE_SIZE) catch unreachable);
    const array_bytes = std.mem.alignForward(usize, npages * @sizeOf(Page), PAGE_SIZE);

    // Carve the descriptor array out of the first big-enough usable region.
    var array_phys: u64 = 0;
    for (entries) |e| {
        if (e.kind == .usable and e.length >= array_bytes) {
            array_phys = e.base;
            break;
        }
    }
    if (array_phys == 0) @panic("pmm: no room for page array");
    pages = @as([*]Page, @ptrFromInt(phys_to_virt_early(array_phys)))[0..npages];
    for (pages) |*p| p.* = .{};

    for (entries) |e| {
        if (e.kind != .usable) continue;
        var start = std.mem.alignForward(u64, e.base, PAGE_SIZE);
        const end = std.mem.alignBackward(u64, e.base + e.length, PAGE_SIZE);
        if (start == array_phys) start += array_bytes;
        var pfn: u64 = start / PAGE_SIZE;
        const end_pfn = end / PAGE_SIZE;
        while (pfn < end_pfn) {
            var order: u8 = MAX_ORDER;
            while (order > 0) : (order -= 1) {
                const n = @as(u64, 1) << @intCast(order);
                if (pfn % n == 0 and pfn + n <= end_pfn) break;
            }
            total_pages += @as(usize, 1) << @intCast(order);
            freeBlockLocked(@intCast(pfn), order);
            pfn += @as(u64, 1) << @intCast(order);
        }
    }
    log.info("pmm: buddy allocator up, {d} MiB free, {d} page descriptors", .{ free_pages * PAGE_SIZE >> 20, npages });
}

fn phys_to_virt_early(p: u64) u64 {
    return p + hhdm;
}

/// Allocate 2^order contiguous pages. Returns the physical address.
pub fn allocPages(order: u8) ?u64 {
    const e = lock.lock();
    defer lock.unlock(e);
    var o = order;
    while (o <= MAX_ORDER and free_heads[o] == NONE) o += 1;
    if (o > MAX_ORDER) return null;
    const pfn = free_heads[o];
    listRemove(o, pfn);
    while (o > order) {
        o -= 1;
        listPush(o, pfn + (@as(u32, 1) << @intCast(o)));
    }
    const p = &pages[pfn];
    p.flags = .{ .head = true };
    p.order = order;
    p.refcount = 1;
    free_pages -= @as(usize, 1) << @intCast(order);
    return @as(u64, pfn) * PAGE_SIZE;
}

pub fn freePages(phys: u64, order: u8) void {
    const e = lock.lock();
    defer lock.unlock(e);
    const pfn: u32 = @intCast(phys / PAGE_SIZE);
    pages[pfn].refcount = 0;
    freeBlockLocked(pfn, order);
}

/// Allocate one zeroed page.
pub fn allocPage() ?u64 {
    const p = allocPages(0) orelse return null;
    @memset(ptr([*]u8, p)[0..PAGE_SIZE], 0);
    return p;
}
pub fn freePage(phys: u64) void {
    freePages(phys, 0);
}

pub fn orderFor(bytes: usize) u8 {
    var order: u8 = 0;
    while ((PAGE_SIZE << @intCast(order)) < bytes) order += 1;
    return order;
}

pub fn dumpStats() void {
    log.print("[yos] pmm free lists:", .{});
    for (free_counts, 0..) |c, i| log.print(" o{d}={d}", .{ i, c });
    log.print("\n", .{});
}

/// Self test: allocate a pile of blocks of mixed orders, free them, and check
/// that everything coalesces back.
pub fn selfTest() void {
    const before = free_pages;
    const heads_before = free_counts;
    var blocks: [64]struct { p: u64, o: u8 } = undefined;
    for (&blocks, 0..) |*b, i| {
        const o: u8 = @intCast(i % 5);
        b.* = .{ .p = allocPages(o) orelse @panic("pmm selftest: oom"), .o = o };
        std.debug.assert(b.p % (PAGE_SIZE << @intCast(o)) == 0);
    }
    var i: usize = blocks.len;
    while (i > 0) {
        i -= 1;
        freePages(blocks[i].p, blocks[i].o);
    }
    if (free_pages != before) @panic("pmm selftest: page leak");
    if (!std.mem.eql(usize, &heads_before, &free_counts)) @panic("pmm selftest: did not coalesce");
    log.info("pmm: self test passed (64 mixed-order allocs coalesced)", .{});
}
