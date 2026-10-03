const std = @import("std");
const cpu = @import("cpu.zig");
const log = @import("../log.zig");

pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    pub fn fromUser(self: *const TrapFrame) bool {
        return self.cs & 3 == 3;
    }
};

const Entry = extern struct {
    off_lo: u16,
    sel: u16,
    ist: u8,
    attr: u8,
    off_mid: u16,
    off_hi: u32,
    zero: u32 = 0,
};

var idt: [256]Entry = undefined;
extern const isr_table: [256]u64;

pub const Handler = *const fn (frame: *TrapFrame) void;
var handlers: [256]?Handler = [_]?Handler{null} ** 256;

/// Called on every exception that is not handled by a registered handler.
pub var exception_hook: ?*const fn (frame: *TrapFrame) bool = null;
/// Called after an interrupt from user mode is handled (signals, rescheduling).
pub var return_to_user_hook: ?*const fn (frame: *TrapFrame) void = null;

fn set(vec: usize, handler: u64, ist: u8, dpl: u8) void {
    idt[vec] = .{
        .off_lo = @truncate(handler),
        .sel = 0x08,
        .ist = ist,
        .attr = 0x8E | (dpl << 5),
        .off_mid = @truncate(handler >> 16),
        .off_hi = @truncate(handler >> 32),
    };
}

pub fn init() void {
    for (0..256) |i| set(i, isr_table[i], 0, 0);
    set(8, isr_table[8], 1, 0); // double fault on IST1
    set(2, isr_table[2], 2, 0); // NMI on IST2
    const Ptr = extern struct { limit: u16 align(1), base: u64 align(1) };
    const p = Ptr{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&p),
    );
}

pub fn register(vec: u8, h: Handler) void {
    handlers[vec] = h;
}

const names = [_][]const u8{
    "#DE divide error",       "#DB debug",               "NMI",                  "#BP breakpoint",
    "#OF overflow",           "#BR bound range",         "#UD invalid opcode",   "#NM device not available",
    "#DF double fault",       "coproc overrun",          "#TS invalid TSS",      "#NP segment not present",
    "#SS stack fault",        "#GP general protection",  "#PF page fault",       "reserved",
    "#MF x87 fp",             "#AC alignment check",     "#MC machine check",    "#XM simd fp",
    "#VE virtualization",     "#CP control protection",
};

pub fn dumpFrame(f: *const TrapFrame) void {
    log.print("  rip={x:0>16} cs={x} rflags={x} rsp={x:0>16} ss={x}\n", .{ f.rip, f.cs, f.rflags, f.rsp, f.ss });
    log.print("  rax={x:0>16} rbx={x:0>16} rcx={x:0>16} rdx={x:0>16}\n", .{ f.rax, f.rbx, f.rcx, f.rdx });
    log.print("  rsi={x:0>16} rdi={x:0>16} rbp={x:0>16} r8 ={x:0>16}\n", .{ f.rsi, f.rdi, f.rbp, f.r8 });
    log.print("  r9 ={x:0>16} r10={x:0>16} r11={x:0>16} r12={x:0>16}\n", .{ f.r9, f.r10, f.r11, f.r12 });
    log.print("  r13={x:0>16} r14={x:0>16} r15={x:0>16} cr2={x:0>16}\n", .{ f.r13, f.r14, f.r15, cpu.readCr2() });
}

export fn interrupt_dispatch(frame: *TrapFrame) callconv(.c) void {
    const v = frame.vector;
    if (handlers[v]) |h| {
        h(frame);
    } else if (v < 32) {
        if (exception_hook) |hook| {
            if (hook(frame)) {
                if (frame.fromUser()) if (return_to_user_hook) |r| r(frame);
                return;
            }
        }
        const name = if (v < names.len) names[v] else "exception";
        log.print("\n*** CPU exception {d} ({s}) err={x}\n", .{ v, name, frame.error_code });
        dumpFrame(frame);
        @panic("unhandled CPU exception");
    } else {
        log.print("[yos] spurious interrupt {d}\n", .{v});
    }
    if (frame.fromUser()) if (return_to_user_hook) |r| r(frame);
}
