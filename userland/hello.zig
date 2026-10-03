const std = @import("std");
const linux = std.os.linux;

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try out.print("Hello from userspace! pid={d}\n", .{linux.getpid()});
}
