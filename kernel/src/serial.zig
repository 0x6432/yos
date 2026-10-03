//! 16550 UART on COM1.
const cpu = @import("arch/cpu.zig");

pub const COM1: u16 = 0x3F8;

pub fn init() void {
    cpu.outb(COM1 + 1, 0x00); // disable interrupts
    cpu.outb(COM1 + 3, 0x80); // DLAB
    cpu.outb(COM1 + 0, 0x01); // 115200 baud
    cpu.outb(COM1 + 1, 0x00);
    cpu.outb(COM1 + 3, 0x03); // 8n1
    cpu.outb(COM1 + 2, 0xC7); // FIFO
    cpu.outb(COM1 + 4, 0x0B); // RTS/DSR, OUT2
}

/// Enable "received data available" interrupt.
pub fn enableRxInterrupt() void {
    cpu.outb(COM1 + 1, 0x01);
}

pub fn putc(c: u8) void {
    var spins: usize = 0;
    while (cpu.inb(COM1 + 5) & 0x20 == 0 and spins < 100000) : (spins += 1) cpu.pause();
    cpu.outb(COM1, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

/// Raw write (no newline translation) used by the tty layer.
pub fn writeRaw(s: []const u8) void {
    for (s) |c| putc(c);
}

pub fn hasData() bool {
    return cpu.inb(COM1 + 5) & 1 != 0;
}
pub fn getc() u8 {
    return cpu.inb(COM1);
}
