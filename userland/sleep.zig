const std = @import("std");
const sys = @import("lib/sys.zig");
pub fn main(init: std.process.Init.Minimal) void {
    var args = sys.args(init);
    args.skip();
    const a = args.next() orelse return;
    const secs = std.fmt.parseFloat(f64, a) catch 0;
    sys.nanosleepNs(@intFromFloat(secs * 1e9));
}
