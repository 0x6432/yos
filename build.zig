const std = @import("std");

pub fn build(b: *std.Build) void {
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const F = std.Target.x86.Feature;
    // The kernel never touches SIMD state; user FPU state is saved on switch.
    query.cpu_features_sub.addFeature(@intFromEnum(F.mmx));
    query.cpu_features_sub.addFeature(@intFromEnum(F.sse));
    query.cpu_features_sub.addFeature(@intFromEnum(F.sse2));
    query.cpu_features_sub.addFeature(@intFromEnum(F.avx));
    query.cpu_features_sub.addFeature(@intFromEnum(F.avx2));
    query.cpu_features_add.addFeature(@intFromEnum(F.soft_float));
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });
    kernel.root_module.red_zone = false;
    kernel.root_module.omit_frame_pointer = false;
    kernel.root_module.pic = false;
    kernel.want_lto = false;
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    kernel.addAssemblyFile(b.path("kernel/src/arch/entry.S"));

    // @@UACPI@@

    b.installArtifact(kernel);
}
