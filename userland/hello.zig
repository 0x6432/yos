const sys = @import("lib/sys.zig");

pub fn main() void {
    sys.print("Hello from userspace! pid={d}\n", .{sys.getpid()});
}
