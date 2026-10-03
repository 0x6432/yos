const std = @import("std");
pub fn main() !void {
    const linux = std.os.linux;
    std.io.getStdOut().writer().print("Powering off...\n", .{}) catch {};
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
}
