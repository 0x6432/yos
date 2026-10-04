const std = @import("std");
const sys = @import("lib/sys.zig");

fn makePath(p: []const u8) isize {
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i == p.len or p[i] == '/') {
            const r = sys.mkdir(p[0..i], 0o755);
            if (r < 0 and r != -17) return r;
        }
    }
    return 0;
}

pub fn main(init: std.process.Init.Minimal) void {
    var args = sys.args(init);
    args.skip();
    var parents = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-p")) {
            parents = true;
            continue;
        }
        const r = if (parents) makePath(a) else sys.mkdir(a, 0o755);
        if (r < 0) {
            sys.eprint("mkdir: {s}: {s}\n", .{ a, sys.strerror(@intCast(-r)) });
            status = 1;
        }
    }
    sys.exit(status);
}
