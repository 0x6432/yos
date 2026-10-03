const std = @import("std");
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    var parents = false;
    var status: u8 = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-p")) {
            parents = true;
            continue;
        }
        const r = if (parents) std.fs.cwd().makePath(a) else std.fs.cwd().makeDir(a);
        r catch |e| {
            std.io.getStdErr().writer().print("mkdir: {s}: {s}\n", .{ a, @errorName(e) }) catch {};
            status = 1;
        };
    }
    std.process.exit(status);
}
