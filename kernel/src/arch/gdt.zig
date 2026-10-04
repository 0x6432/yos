const std = @import("std");

pub const KCODE: u16 = 0x08;
pub const KDATA: u16 = 0x10;
pub const UDATA: u16 = 0x18 | 3;
pub const UCODE: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1) = [_]u64{0} ** 7,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb: u16 align(1) = @sizeOf(Tss),
};

const GdtPtr = extern struct { limit: u16 align(1), base: u64 align(1) };

const percpu = @import("../percpu.zig");

const gdt_template: [7]u64 = .{
    0,
    0x00AF9A000000FFFF, // kernel code
    0x00CF92000000FFFF, // kernel data
    0x00CFF2000000FFFF, // user data
    0x00AFFA000000FFFF, // user code
    0, 0, // TSS
};
var gdts: [percpu.MAX_CPUS][7]u64 = undefined;
var tsss: [percpu.MAX_CPUS]Tss = [_]Tss{.{}} ** percpu.MAX_CPUS;
var df_stacks: [percpu.MAX_CPUS][16384]u8 align(16) = undefined;
var nmi_stacks: [percpu.MAX_CPUS][8192]u8 align(16) = undefined;

extern fn gdt_load(ptr: *const GdtPtr) callconv(.c) void;

/// Load a GDT + TSS for CPU `i`. Note: reloading segments zeroes GS_BASE.
pub fn initCpu(i: usize) void {
    const tss = &tsss[i];
    tss.* = .{};
    tss.ist[0] = @intFromPtr(&df_stacks[i]) + df_stacks[i].len;
    tss.ist[1] = @intFromPtr(&nmi_stacks[i]) + nmi_stacks[i].len;
    const g = &gdts[i];
    g.* = gdt_template;
    const base = @intFromPtr(tss);
    const limit: u64 = @sizeOf(Tss) - 1;
    g[5] = limit | ((base & 0xFFFFFF) << 16) | (0x89 << 40) | (((base >> 24) & 0xFF) << 56);
    g[6] = base >> 32;
    const ptr = GdtPtr{ .limit = @sizeOf([7]u64) - 1, .base = @intFromPtr(g) };
    gdt_load(&ptr);
    asm volatile ("ltr %[s]"
        :
        : [s] "r" (TSS_SEL),
    );
    percpu.cpus[i].tss = base;
}

pub fn init() void {
    initCpu(0);
}

pub fn setKernelStack(top: u64) void {
    const t: *Tss = @ptrFromInt(percpu.get().tss);
    t.rsp0 = top;
}
