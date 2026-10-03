//! USTAR archive reader for the Limine-provided initrd module.
const std = @import("std");
const limine = @import("limine.zig");

pub const Entry = struct {
    name: []const u8, // without leading "./" or "/"
    kind: u8, // '0' file, '5' dir, '2' symlink
    mode: u32,
    data: []const u8,
    link: []const u8,
    mtime: u64,
};

pub var image: []const u8 = &.{};

pub fn init() bool {
    const mods = limine.modules() orelse return false;
    for (mods.modules[0..mods.module_count]) |m| {
        image = m.address[0..m.size];
        return true;
    }
    return false;
}

fn octal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

pub const Iterator = struct {
    off: usize = 0,
    name_buf: [256]u8 = undefined,

    pub fn next(self: *Iterator) ?Entry {
        while (self.off + 512 <= image.len) {
            const h = image[self.off .. self.off + 512];
            if (h[0] == 0) return null;
            const size = octal(h[124..136]);
            const data_off = self.off + 512;
            self.off = data_off + std.mem.alignForward(usize, size, 512);
            const name = std.mem.sliceTo(h[0..100], 0);
            const prefix = std.mem.sliceTo(h[345..500], 0);
            var full: []const u8 = name;
            if (prefix.len > 0) {
                full = std.fmt.bufPrint(&self.name_buf, "{s}/{s}", .{ prefix, name }) catch name;
            }
            while (std.mem.startsWith(u8, full, "./")) full = full[2..];
            while (std.mem.startsWith(u8, full, "/")) full = full[1..];
            while (full.len > 0 and full[full.len - 1] == '/') full = full[0 .. full.len - 1];
            if (full.len == 0 or std.mem.eql(u8, full, ".")) continue;
            const kind = if (h[156] == 0) '0' else h[156];
            return .{
                .name = full,
                .kind = kind,
                .mode = @intCast(octal(h[100..108])),
                .data = image[data_off .. data_off + size],
                .link = std.mem.sliceTo(h[157..257], 0),
                .mtime = octal(h[136..148]),
            };
        }
        return null;
    }
};

pub fn find(path: []const u8) ?Entry {
    var p = path;
    while (std.mem.startsWith(u8, p, "/")) p = p[1..];
    var it = Iterator{};
    while (it.next()) |e| if (std.mem.eql(u8, e.name, p)) return e;
    return null;
}
