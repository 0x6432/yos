//! Static ELF64 loader (ET_EXEC and static-PIE ET_DYN without interpreter).
const std = @import("std");
const vmm = @import("mm/vmm.zig");

pub const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};
pub const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};
pub const PT_LOAD = 1;
pub const PT_INTERP = 3;
pub const PT_PHDR = 6;
pub const PF_X = 1;
pub const PF_W = 2;
pub const PF_R = 4;

pub const Loaded = struct {
    entry: u64,
    phdr: u64,
    phent: u64,
    phnum: u64,
    base: u64,
    brk: u64,
};

pub const Segment = struct { vaddr: u64, memsz: u64, data: []const u8, flags: u32 };

pub const Error = error{ NotElf, Unsupported, OutOfMemory, Fault };

/// Parse and hand each PT_LOAD to `mapper.segment(seg)`.
pub fn load(data: []const u8, mapper: anytype) Error!Loaded {
    if (data.len < @sizeOf(Ehdr)) return error.NotElf;
    const eh: *align(1) const Ehdr = @ptrCast(data.ptr);
    if (!std.mem.eql(u8, eh.ident[0..4], "\x7fELF") or eh.ident[4] != 2) return error.NotElf;
    if (eh.machine != 62) return error.Unsupported;
    if (eh.type != 2 and eh.type != 3) return error.Unsupported;
    const bias: u64 = if (eh.type == 3) 0x0000_5555_5555_4000 else 0;
    if (eh.phoff + @as(u64, eh.phnum) * @sizeOf(Phdr) > data.len) return error.NotElf;
    var phdr_addr: u64 = 0;
    var top: u64 = 0;
    var first_load: ?u64 = null;
    var first_off: u64 = 0;
    for (0..eh.phnum) |i| {
        const ph: *align(1) const Phdr = @ptrCast(data.ptr + eh.phoff + i * eh.phentsize);
        switch (ph.type) {
            PT_INTERP => return error.Unsupported,
            PT_PHDR => phdr_addr = ph.vaddr + bias,
            PT_LOAD => {
                if (ph.offset + ph.filesz > data.len) return error.NotElf;
                if (first_load == null) {
                    first_load = ph.vaddr;
                    first_off = ph.offset;
                }
                try mapper.segment(.{
                    .vaddr = ph.vaddr + bias,
                    .memsz = ph.memsz,
                    .data = data[ph.offset .. ph.offset + ph.filesz],
                    .flags = ph.flags,
                });
                top = @max(top, ph.vaddr + bias + ph.memsz);
            },
            else => {},
        }
    }
    if (phdr_addr == 0) if (first_load) |fl| {
        phdr_addr = fl - first_off + eh.phoff + bias;
    };
    return .{
        .entry = eh.entry + bias,
        .phdr = phdr_addr,
        .phent = eh.phentsize,
        .phnum = eh.phnum,
        .base = 0,
        .brk = std.mem.alignForward(u64, top, 4096),
    };
}
