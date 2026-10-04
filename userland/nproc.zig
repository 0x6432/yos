const sys = @import("lib/sys.zig");
pub fn main() void {
    var m: u64 = 0;
    _ = sys.sys(.sched_getaffinity, .{ @as(usize, 0), @as(usize, 8), &m });
    sys.print("{d}\n", .{@popCount(m)});
}
