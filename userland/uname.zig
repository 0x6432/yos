const std = @import("std");
const sys = @import("lib/sys.zig");
pub fn main(init: std.process.Init.Minimal) void {
    var un: sys.Utsname = undefined;
    _ = sys.uname(&un);
    var args = sys.args(init);
    args.skip();
    const all = if (args.next()) |a| std.mem.eql(u8, a, "-a") else false;
    const z = std.mem.sliceTo;
    if (all) {
        sys.print("{s} {s} {s} {s} {s}\n", .{ z(&un.sysname, 0), z(&un.nodename, 0), z(&un.release, 0), z(&un.version, 0), z(&un.machine, 0) });
    } else sys.print("{s}\n", .{z(&un.sysname, 0)});
}
