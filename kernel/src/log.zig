const std = @import("std");
const serial = @import("serial.zig");
const cpu = @import("arch/cpu.zig");

fn writeFn(_: void, bytes: []const u8) error{}!usize {
    serial.write(bytes);
    return bytes.len;
}
pub const Writer = std.io.GenericWriter(void, error{}, writeFn);
pub const writer: Writer = .{ .context = {} };

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const e = cpu.saveDisable();
    defer cpu.restore(e);
    std.fmt.format(writer, fmt, args) catch {};
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    print("[yos] " ++ fmt ++ "\n", args);
}
