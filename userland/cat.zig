const std = @import("std");
const posix = std.posix;

fn copy(fd: posix.fd_t) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) return;
        var off: usize = 0;
        while (off < n) off += try posix.write(1, buf[off..n]);
    }
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var any = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        any = true;
        if (std.mem.eql(u8, a, "-")) {
            try copy(0);
            continue;
        }
        const fd = posix.open(a, .{}, 0) catch {
            std.io.getStdErr().writer().print("cat: {s}: No such file or directory\n", .{a}) catch {};
            status = 1;
            continue;
        };
        defer posix.close(fd);
        try copy(fd);
    }
    if (!any) try copy(0);
    std.process.exit(status);
}
