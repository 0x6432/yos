const std = @import("std");
const posix = std.posix;
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var file: ?[]const u8 = null;
    var only_lines = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-l")) only_lines = true else file = a;
    }
    const fd = if (file) |f| try posix.open(f, .{}, 0) else 0;
    var buf: [4096]u8 = undefined;
    var l: usize = 0;
    var w: usize = 0;
    var c: usize = 0;
    var in_word = false;
    while (true) {
        const r = try posix.read(fd, &buf);
        if (r == 0) break;
        c += r;
        for (buf[0..r]) |ch| {
            if (ch == '\n') l += 1;
            const ws = ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
            if (!ws and !in_word) w += 1;
            in_word = !ws;
        }
    }
    const out = std.io.getStdOut().writer();
    if (only_lines) try out.print("{d}\n", .{l}) else try out.print("{d:>7} {d:>7} {d:>7}\n", .{ l, w, c });
}
