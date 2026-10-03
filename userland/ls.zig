const std = @import("std");
const posix = std.posix;

fn modeStr(m: u32, buf: *[10]u8) []const u8 {
    buf[0] = switch (m & 0o170000) {
        0o040000 => 'd',
        0o120000 => 'l',
        0o020000 => 'c',
        0o010000 => 'p',
        else => '-',
    };
    const chars = "rwxrwxrwx";
    for (0..9) |i| buf[1 + i] = if (m & (@as(u32, 1) << @intCast(8 - i)) != 0) chars[i] else '-';
    return buf;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const w = std.io.getStdOut().writer();
    var long = false;
    var all = false;
    var paths: [16][]const u8 = undefined;
    var np: usize = 0;
    while (args.next()) |a| {
        if (a.len > 1 and a[0] == '-') {
            for (a[1..]) |c| switch (c) {
                'l' => long = true,
                'a' => all = true,
                else => {},
            };
        } else if (np < paths.len) {
            paths[np] = a;
            np += 1;
        }
    }
    if (np == 0) {
        paths[0] = ".";
        np = 1;
    }
    var status: u8 = 0;
    for (paths[0..np]) |path| {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
            // maybe a file
            if (std.fs.cwd().statFile(path)) |_| {
                try w.print("{s}\n", .{path});
            } else |_| {
                std.io.getStdErr().writer().print("ls: cannot access '{s}': No such file or directory\n", .{path}) catch {};
                status = 2;
            }
            continue;
        };
        defer dir.close();
        if (np > 1) try w.print("{s}:\n", .{path});
        var names = std.ArrayList([]const u8).init(std.heap.page_allocator);
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (!all and e.name[0] == '.') continue;
            try names.append(try std.heap.page_allocator.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |n| {
            if (long) {
                var st: std.os.linux.Stat = undefined;
                var pbuf: [512]u8 = undefined;
                const full = try std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ path, n });
                _ = std.os.linux.lstat(full, &st);
                var mb: [10]u8 = undefined;
                try w.print("{s} {d:>3} root root {d:>8} {s}", .{ modeStr(st.mode, &mb), st.nlink, st.size, n });
                if (st.mode & 0o170000 == 0o120000) {
                    var lb: [256]u8 = undefined;
                    if (posix.readlink(full, &lb)) |l| try w.print(" -> {s}", .{l}) else |_| {}
                }
                try w.print("\n", .{});
            } else {
                try w.print("{s}\n", .{n});
            }
        }
    }
    std.process.exit(status);
}
