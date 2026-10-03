//! Minimal Limine boot protocol bindings (base revision 3).
const COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
const COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

fn id(a: u64, b: u64) [4]u64 {
    return .{ COMMON_MAGIC_0, COMMON_MAGIC_1, a, b };
}

pub fn Request(comptime Response: type, comptime a: u64, comptime b: u64) type {
    return extern struct {
        id: [4]u64 = id(a, b),
        revision: u64 = 0,
        response: ?*volatile Response = null,
    };
}

pub const HhdmResponse = extern struct { revision: u64, offset: u64 };

pub const MemmapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    _,
};
pub const MemmapEntry = extern struct { base: u64, length: u64, kind: MemmapType };
pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};

pub const Uuid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const File = extern struct {
    revision: u64,
    address: [*]u8,
    size: u64,
    path: [*:0]u8,
    string: [*:0]u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};
pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]*File,
};
pub const RsdpResponse = extern struct { revision: u64, address: u64 };
pub const KernelAddressResponse = extern struct { revision: u64, physical_base: u64, virtual_base: u64 };
pub const StackSizeResponse = extern struct { revision: u64 };
pub const StackSizeRequest = extern struct {
    id: [4]u64 = id(0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d),
    revision: u64 = 0,
    response: ?*volatile StackSizeResponse = null,
    stack_size: u64,
};
pub const BootTimeResponse = extern struct { revision: u64, boot_time: i64 };

pub const HhdmRequest = Request(HhdmResponse, 0x48dcf1cb8ad2b852, 0x63984e959a98244b);
pub const MemmapRequest = Request(MemmapResponse, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62);
pub const ModuleRequest = Request(ModuleResponse, 0x3e7e279702be32af, 0xca1c4f3bd1280cee);
pub const RsdpRequest = Request(RsdpResponse, 0xc5e77b6b397e7b43, 0x27637845accdcf3c);
pub const KernelAddressRequest = Request(KernelAddressResponse, 0x71ba76863cc55f63, 0xb2644a48c516a487);
pub const BootTimeRequest = Request(BootTimeResponse, 0x502746e184c088aa, 0xfbc5ec83e6327893);

// ---- the actual requests, placed in the section Limine scans ----
export var limine_start_marker linksection(".limine_requests_start") = [4]u64{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
export var limine_base_revision linksection(".limine_requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };
export var limine_hhdm linksection(".limine_requests") = HhdmRequest{};
export var limine_memmap linksection(".limine_requests") = MemmapRequest{};
export var limine_modules linksection(".limine_requests") = ModuleRequest{};
export var limine_rsdp linksection(".limine_requests") = RsdpRequest{};
export var limine_kaddr linksection(".limine_requests") = KernelAddressRequest{};
export var limine_boottime linksection(".limine_requests") = BootTimeRequest{};
export var limine_stack linksection(".limine_requests") = StackSizeRequest{ .stack_size = 128 * 1024 };
export var limine_end_marker linksection(".limine_requests_end") = [2]u64{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

pub fn baseRevisionSupported() bool {
    return @as(*volatile u64, &limine_base_revision[2]).* == 0;
}

pub fn hhdm() *volatile HhdmResponse {
    return limine_hhdm.response.?;
}
pub fn memmap() *volatile MemmapResponse {
    return limine_memmap.response.?;
}
pub fn modules() ?*volatile ModuleResponse {
    return limine_modules.response;
}
pub fn rsdp() ?*volatile RsdpResponse {
    return limine_rsdp.response;
}
pub fn kernelAddress() *volatile KernelAddressResponse {
    return limine_kaddr.response.?;
}
pub fn bootTime() i64 {
    return if (limine_boottime.response) |r| r.boot_time else 0;
}
