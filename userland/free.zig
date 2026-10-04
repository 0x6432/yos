const sys = @import("lib/sys.zig");
const SysInfo = extern struct {
    uptime: i64,
    loads: [3]u64,
    totalram: u64,
    freeram: u64,
    sharedram: u64,
    bufferram: u64,
    totalswap: u64,
    freeswap: u64,
    procs: u16,
    pad: u16,
    pad2: u32,
    totalhigh: u64,
    freehigh: u64,
    mem_unit: u32,
    _f: [4]u8,
};
pub fn main() void {
    var si: SysInfo = undefined;
    _ = sys.sys(.sysinfo, .{&si});
    sys.print("              total        used        free\n", .{});
    sys.print("Mem:   {d:>12} {d:>11} {d:>11}  (KiB)\n", .{ si.totalram / 1024, (si.totalram - si.freeram) / 1024, si.freeram / 1024 });
    sys.print("uptime: {d}s, processes: {d}\n", .{ si.uptime, si.procs });
}
