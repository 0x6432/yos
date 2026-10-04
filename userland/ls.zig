const std = @import("std");
const sys = @import("lib/sys.zig");

fn modeStr(m: u32, buf: *[10]u8) []const u8 {
    buf[0] = switch (m & sys.S.IFMT) {
        sys.S.IFDIR => 'd',
        sys.S.IFLNK => 'l',
        sys.S.IFCHR => 'c',
        sys.S.IFIFO => 'p',
        else => '-',
    };
    const chars = "rwxrwxrwx";
    for (0..9) |i| buf[1 + i] = if (m & (@as(u32, 1) << @intCast(8 - i)) != 0) chars[i] else '-';
    return buf;
}

var name_store: [64 * 1024]u8 = undefined;
var names: [2048][]const u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = sys.args(init);
    args.skip();
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
        var st: sys.Stat = undefined;
        if (sys.stat(path, &st) < 0) {
            sys.eprint("ls: cannot access '{s}': No such file or directory\n", .{path});
            status = 2;
            continue;
        }
        if (!sys.S.isDir(st.mode)) {
            sys.bprint("{s}\n", .{path});
            continue;
        }
        var dir = sys.Dir.open(path) catch {
            sys.eprint("ls: cannot open '{s}'\n", .{path});
            status = 2;
            continue;
        };
        defer dir.close();
        if (np > 1) sys.bprint("{s}:\n", .{path});
        var nn: usize = 0;
        var used: usize = 0;
        while (try dir.next()) |e| {
            if (!all and e.name[0] == '.') continue;
            if (nn == names.len or used + e.name.len > name_store.len) break;
            @memcpy(name_store[used..][0..e.name.len], e.name);
            names[nn] = name_store[used..][0..e.name.len];
            used += e.name.len;
            nn += 1;
        }
        std.mem.sort([]const u8, names[0..nn], {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names[0..nn]) |n| {
            if (long) {
                var pbuf: [512]u8 = undefined;
                const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ path, n }) catch continue;
                var ls: sys.Stat = std.mem.zeroes(sys.Stat);
                _ = sys.lstat(full, &ls);
                var mb: [10]u8 = undefined;
                sys.bprint("{s} {d:>3} root root {d:>8} {s}", .{ modeStr(ls.mode, &mb), ls.nlink, ls.size, n });
                if (ls.mode & sys.S.IFMT == sys.S.IFLNK) {
                    var lb: [256]u8 = undefined;
                    if (sys.readlink(full, &lb)) |l| sys.bprint(" -> {s}", .{l}) else |_| {}
                }
                sys.bprint("\n", .{});
            } else {
                sys.bprint("{s}\n", .{n});
            }
        }
    }
    sys.flush();
    sys.exit(status);
}
