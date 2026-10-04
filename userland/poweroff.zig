const sys = @import("lib/sys.zig");
pub fn main() void {
    sys.print("Powering off...\n", .{});
    _ = sys.sys(.reboot, .{ @as(u32, 0xfee1dead), @as(u32, 672274793), @as(u32, 0x4321fedc), @as(usize, 0) });
}
