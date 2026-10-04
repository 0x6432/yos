//! 4-level paging. The upper half (PML4 slots 256..511) is shared by all
//! address spaces; those PML4 entries are pre-populated at boot so later
//! kernel mappings are visible everywhere.
const std = @import("std");
const cpu = @import("../arch/cpu.zig");
const pmm = @import("pmm.zig");
const log = @import("../log.zig");

pub const P: u64 = 1 << 0;
pub const W: u64 = 1 << 1;
pub const U: u64 = 1 << 2;
pub const PWT: u64 = 1 << 3;
pub const PCD: u64 = 1 << 4;
pub const PS: u64 = 1 << 7;
pub const G: u64 = 1 << 8;
pub const NX: u64 = 1 << 63;
/// Software bit: page is shared copy-on-write (hardware W is clear).
pub const COW: u64 = 1 << 9;
pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub const USER_TOP: u64 = 0x0000_8000_0000_0000;

pub const AddressSpace = struct {
    pml4: u64, // physical

    pub fn table(phys: u64) *[512]u64 {
        return pmm.ptr(*[512]u64, phys);
    }

    /// Walk to the PTE for `virt`, optionally allocating intermediate tables.
    /// Returns null if a level is missing (and !create) or a huge page is hit.
    pub fn walk(self: AddressSpace, virt: u64, create: bool) ?*u64 {
        var tbl = table(self.pml4);
        const user = virt < USER_TOP;
        var level: u6 = 39;
        while (level > 12) : (level -= 9) {
            const idx = (virt >> level) & 0x1FF;
            var e = tbl[idx];
            if (e & P == 0) {
                if (!create) return null;
                const np = pmm.allocPage() orelse return null;
                e = np | P | W | (if (user) U else 0);
                tbl[idx] = e;
            } else if (e & PS != 0) {
                return null;
            }
            tbl = table(e & ADDR_MASK);
        }
        return &tbl[(virt >> 12) & 0x1FF];
    }

    pub fn map(self: AddressSpace, virt: u64, phys: u64, flags: u64) !void {
        const pte = self.walk(virt, true) orelse return error.OutOfMemory;
        pte.* = (phys & ADDR_MASK) | flags | P;
        cpu.invlpg(virt);
    }

    /// Unmap and return the physical frame that was mapped (if any).
    pub fn unmap(self: AddressSpace, virt: u64) ?u64 {
        const pte = self.walk(virt, false) orelse return null;
        if (pte.* & P == 0) return null;
        const phys = pte.* & ADDR_MASK;
        pte.* = 0;
        cpu.invlpg(virt);
        return phys;
    }

    pub fn translate(self: AddressSpace, virt: u64) ?u64 {
        const pte = self.walk(virt, false) orelse return null;
        if (pte.* & P == 0) return null;
        return (pte.* & ADDR_MASK) | (virt & 0xFFF);
    }

    pub fn pteFlags(self: AddressSpace, virt: u64) ?u64 {
        const pte = self.walk(virt, false) orelse return null;
        if (pte.* & P == 0) return null;
        return pte.* & ~ADDR_MASK;
    }

    pub fn activate(self: AddressSpace) void {
        if (cpu.readCr3() & ADDR_MASK != self.pml4) cpu.writeCr3(self.pml4);
    }

    /// Fresh user address space sharing the kernel half.
    pub fn createUser() !AddressSpace {
        const p = pmm.allocPage() orelse return error.OutOfMemory;
        const k = table(kernel_space.pml4);
        const n = table(p);
        @memcpy(n[256..512], k[256..512]);
        return .{ .pml4 = p };
    }

    fn freeLevel(phys: u64, depth: u8) void {
        const t = table(phys);
        for (t) |e| {
            if (e & P == 0) continue;
            if (depth == 3) {
                pmm.pageUnref(e & ADDR_MASK);
            } else {
                freeLevel(e & ADDR_MASK, depth + 1);
            }
        }
        pmm.freePage(phys);
    }

    /// Free every user page and page table, keep the PML4 itself.
    pub fn clearUser(self: AddressSpace) void {
        const t = table(self.pml4);
        for (t[0..256]) |*e| {
            if (e.* & P != 0) freeLevel(e.* & ADDR_MASK, 1);
            e.* = 0;
        }
        if (cpu.readCr3() & ADDR_MASK == self.pml4) cpu.writeCr3(self.pml4);
    }

    pub fn destroy(self: AddressSpace) void {
        self.clearUser();
        pmm.freePage(self.pml4);
    }

    /// Copy a page-table level. Leaf frames are shared copy-on-write:
    /// both PTEs lose W and gain COW, and the frame's refcount goes up.
    fn copyLevel(src: u64, depth: u8) !u64 {
        const dst = pmm.allocPage() orelse return error.OutOfMemory;
        const s = table(src);
        const d = table(dst);
        for (s, 0..) |*e, i| {
            if (e.* & P == 0) continue;
            if (depth == 3) {
                if (e.* & W != 0) e.* = (e.* & ~W) | COW;
                pmm.pageRef(e.* & ADDR_MASK);
                d[i] = e.*;
            } else {
                d[i] = (try copyLevel(e.* & ADDR_MASK, depth + 1)) | (e.* & ~ADDR_MASK);
            }
        }
        return dst;
    }

    /// Duplicate the user half for fork (copy-on-write).
    pub fn cloneUser(self: AddressSpace) !AddressSpace {
        const child = try createUser();
        const s = table(self.pml4);
        const d = table(child.pml4);
        for (0..256) |i| {
            if (s[i] & P == 0) continue;
            d[i] = (try copyLevel(s[i] & ADDR_MASK, 1)) | (s[i] & ~ADDR_MASK);
        }
        // parent PTEs were write-protected: flush if this space is live
        if (cpu.readCr3() & ADDR_MASK == self.pml4) cpu.writeCr3(self.pml4);
        return child;
    }
};

pub var kernel_space: AddressSpace = undefined;

pub fn init() void {
    kernel_space = .{ .pml4 = cpu.readCr3() & ADDR_MASK };
    const t = AddressSpace.table(kernel_space.pml4);
    var added: usize = 0;
    for (t[256..512]) |*e| {
        if (e.* & P == 0) {
            e.* = (pmm.allocPage() orelse @panic("vmm: oom")) | P | W;
            added += 1;
        }
    }
    // enable NX + write protect in ring 0
    cpu.wrmsr(cpu.MSR_EFER, cpu.rdmsr(cpu.MSR_EFER) | (1 << 11));
    cpu.writeCr0(cpu.readCr0() | (1 << 16));
    cpu.writeCr3(kernel_space.pml4);
    log.info("vmm: kernel pml4 at 0x{x}, pre-populated {d} upper-half slots", .{ kernel_space.pml4, added });
}

/// Map a physical MMIO range into the HHDM window (uncached) and return its
/// virtual address.
pub fn mapMmio(phys: u64, len: u64) u64 {
    const start = std.mem.alignBackward(u64, phys, 4096);
    const end = std.mem.alignForward(u64, phys + len, 4096);
    var a = start;
    while (a < end) : (a += 4096) {
        const v = a + pmm.hhdm;
        if (kernel_space.translate(v) != null) continue;
        // a huge page may already cover it
        if (kernel_space.walk(v, false) == null and hugeMapped(v)) continue;
        kernel_space.map(v, a, W | PCD | PWT | NX) catch @panic("mapMmio: oom");
    }
    return phys + pmm.hhdm;
}

fn hugeMapped(virt: u64) bool {
    var tbl = AddressSpace.table(kernel_space.pml4);
    var level: u6 = 39;
    while (level > 12) : (level -= 9) {
        const e = tbl[(virt >> level) & 0x1FF];
        if (e & P == 0) return false;
        if (e & PS != 0) return true;
        tbl = AddressSpace.table(e & ADDR_MASK);
    }
    return false;
}
