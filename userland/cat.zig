const std = @import("std");
const sys = @import("lib/sys.zig");

fn copy(fd: sys.fd_t) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try sys.check(sys.read(fd, &buf));
        if (n == 0) return;
        try sys.writeAll(1, buf[0..n]);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = sys.args(init);
    args.skip();
    var any = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        any = true;
        if (std.mem.eql(u8, a, "-")) {
            try copy(0);
            continue;
        }
        const fd = sys.open(a, sys.O.RDONLY, 0) catch {
            sys.eprint("cat: {s}: {s}\n", .{ a, sys.strerror(sys.last_errno) });
            status = 1;
            continue;
        };
        defer sys.close(fd);
        copy(fd) catch {
            sys.eprint("cat: {s}: {s}\n", .{ a, sys.strerror(sys.last_errno) });
            status = 1;
        };
    }
    if (!any) try copy(0);
    sys.exit(status);
}
