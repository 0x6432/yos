const std = @import("std");
const limine = @import("limine.zig");
const cpu = @import("arch/cpu.zig");
const serial = @import("serial.zig");
const log = @import("log.zig");

comptime {
    _ = limine;
}

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    cpu.cli();
    log.print("\n!!! KERNEL PANIC: {s}\n", .{msg});
    if (first_trace_addr) |a| log.print("    at 0x{x}\n", .{a});
    var it = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    var n: usize = 0;
    while (it.next()) |ra| : (n += 1) {
        if (n > 16) break;
        log.print("    #{d}: 0x{x}\n", .{ n, ra });
    }
    cpu.halt();
}

export fn kmain() callconv(.c) noreturn {
    serial.init();
    log.print("\n", .{});
    log.info("yos booting (zig {s})", .{@import("builtin").zig_version_string});
    if (!limine.baseRevisionSupported()) @panic("limine base revision 3 not supported");
    log.info("hhdm offset 0x{x}", .{limine.hhdm().offset});
    const mm = limine.memmap();
    var total: u64 = 0;
    for (mm.entries[0..mm.entry_count]) |e| {
        if (e.kind == .usable) total += e.length;
    }
    log.info("usable memory: {d} MiB in {d} entries", .{ total >> 20, mm.entry_count });
    log.info("M0 ok", .{});
    cpu.halt();
}
