const std = @import("std");
const posix = std.posix;
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var n: usize = 10;
    var file: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-n")) {
            n = std.fmt.parseInt(usize, args.next() orelse "10", 10) catch 10;
        } else if (a.len > 1 and a[0] == '-') {
            n = std.fmt.parseInt(usize, a[1..], 10) catch 10;
        } else file = a;
    }
    const fd = if (file) |f| try posix.open(f, .{}, 0) else 0;
    var buf: [4096]u8 = undefined;
    var lines: usize = 0;
    while (lines < n) {
        const r = try posix.read(fd, &buf);
        if (r == 0) break;
        var end: usize = 0;
        while (end < r and lines < n) : (end += 1) {
            if (buf[end] == '\n') lines += 1;
        }
        _ = try posix.write(1, buf[0..end]);
    }
}
