const std = @import("std");
pub fn main() !void {
    const u = std.posix.uname();
    var args = std.process.args();
    _ = args.next();
    const w = std.io.getStdOut().writer();
    const all = if (args.next()) |a| std.mem.eql(u8, a, "-a") else false;
    if (all) {
        try w.print("{s} {s} {s} {s} {s}\n", .{ std.mem.sliceTo(&u.sysname, 0), std.mem.sliceTo(&u.nodename, 0), std.mem.sliceTo(&u.release, 0), std.mem.sliceTo(&u.version, 0), std.mem.sliceTo(&u.machine, 0) });
    } else try w.print("{s}\n", .{std.mem.sliceTo(&u.sysname, 0)});
}
