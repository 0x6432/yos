const std = @import("std");
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var recursive = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        if (a.len > 1 and a[0] == '-') {
            if (std.mem.indexOfScalar(u8, a, 'r') != null) recursive = true;
            continue;
        }
        const r = if (recursive) std.fs.cwd().deleteTree(a) else std.fs.cwd().deleteFile(a);
        r catch |e| {
            std.io.getStdErr().writer().print("rm: {s}: {s}\n", .{ a, @errorName(e) }) catch {};
            status = 1;
        };
    }
    std.process.exit(status);
}
