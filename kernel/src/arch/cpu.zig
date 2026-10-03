//! Low level x86_64 helpers.
pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}
pub inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "N{dx}" (port),
    );
}
pub inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
    );
}
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub inline fn cli() void {
    asm volatile ("cli" ::: "memory");
}
pub inline fn sti() void {
    asm volatile ("sti" ::: "memory");
}
pub inline fn hlt() void {
    asm volatile ("hlt");
}
pub inline fn pause() void {
    asm volatile ("pause");
}

pub inline fn readFlags() u64 {
    return asm volatile ("pushfq; popq %[r]"
        : [r] "=r" (-> u64),
        :
        : "memory"
    );
}
pub inline fn interruptsEnabled() bool {
    return readFlags() & (1 << 9) != 0;
}
/// Disable interrupts and return whether they were enabled.
pub inline fn saveDisable() bool {
    const e = interruptsEnabled();
    cli();
    return e;
}
pub inline fn restore(enabled: bool) void {
    if (enabled) sti();
}

pub fn halt() noreturn {
    while (true) {
        cli();
        hlt();
    }
}

pub inline fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn writeCr3(v: u64) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (v),
        : "memory"
    );
}
pub inline fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn writeCr0(v: u64) void {
    asm volatile ("mov %[v], %%cr0"
        :
        : [v] "r" (v),
        : "memory"
    );
}
pub inline fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn writeCr4(v: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (v),
        : "memory"
    );
}
pub inline fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[a])"
        :
        : [a] "r" (addr),
        : "memory"
    );
}

pub inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}
pub inline fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
          [msr] "{ecx}" (msr),
    );
}

pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
pub inline fn cpuid(leaf: u32, sub: u32) CpuidResult {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

pub const MSR_EFER: u32 = 0xC0000080;
pub const MSR_STAR: u32 = 0xC0000081;
pub const MSR_LSTAR: u32 = 0xC0000082;
pub const MSR_SFMASK: u32 = 0xC0000084;
pub const MSR_FS_BASE: u32 = 0xC0000100;
pub const MSR_GS_BASE: u32 = 0xC0000101;
pub const MSR_KERNEL_GS_BASE: u32 = 0xC0000102;
pub const MSR_APIC_BASE: u32 = 0x1B;
