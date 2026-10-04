const std = @import("std");
const sys = @import("lib/sys.zig");

fn removeTree(path: []const u8) isize {
    var st: sys.Stat = undefined;
    const r = sys.lstat(path, &st);
    if (r < 0) return r;
    if (!sys.S.isDir(st.mode)) return sys.unlink(path);
    {
        var dir = sys.Dir.open(path) catch return -@as(isize, sys.last_errno);
        defer dir.close();
        while (dir.next() catch null) |e| {
            var buf: [1024]u8 = undefined;
            const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, e.name }) catch return -36;
            const cr = removeTree(child);
            if (cr < 0) return cr;
            // the directory changed under us: restart the listing
            dir.close();
            dir = sys.Dir.open(path) catch return -@as(isize, sys.last_errno);
        }
    }
    return sys.rmdir(path);
}

pub fn main(init: std.process.Init.Minimal) void {
    var args = sys.args(init);
    args.skip();
    var recursive = false;
    var force = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        if (a.len > 1 and a[0] == '-') {
            if (std.mem.indexOfScalar(u8, a, 'r') != null or std.mem.indexOfScalar(u8, a, 'R') != null) recursive = true;
            if (std.mem.indexOfScalar(u8, a, 'f') != null) force = true;
            continue;
        }
        const r = if (recursive) removeTree(a) else sys.unlink(a);
        if (r < 0 and !(force and r == -2)) {
            sys.eprint("rm: {s}: {s}\n", .{ a, sys.strerror(@intCast(-r)) });
            status = 1;
        }
    }
    sys.exit(status);
}
