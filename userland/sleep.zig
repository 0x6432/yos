const std = @import("std");
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const a = args.next() orelse return;
    const secs = std.fmt.parseFloat(f64, a) catch 0;
    const ns: u64 = @intFromFloat(secs * 1e9);
    std.posix.nanosleep(ns / 1_000_000_000, ns % 1_000_000_000);
}
