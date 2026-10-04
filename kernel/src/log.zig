const std = @import("std");
const serial = @import("serial.zig");
const cpu = @import("arch/cpu.zig");

/// Unbuffered std.Io.Writer that goes straight to the serial port.
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    if (w.end > 0) {
        serial.write(w.buffer[0..w.end]);
        w.end = 0;
    }
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        serial.write(d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| serial.write(last);
    return n + last.len * splat;
}

const vtable: std.Io.Writer.VTable = .{ .drain = drain };
var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .{ .vtable = &vtable, .buffer = &buf };

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    writer.print(fmt, args) catch {};
    writer.flush() catch {};
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    print("[yos] " ++ fmt ++ "\n", args);
}
