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

    const mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .omit_frame_pointer = false,
        .pic = false,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = mod,
    });
    kernel.lto = .none;
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    mod.addAssemblyFile(b.path("kernel/src/arch/entry.S"));

    // uACPI
    mod.addIncludePath(b.path("third_party/uacpi/include"));
    mod.addCSourceFiles(.{
        .root = b.path("third_party/uacpi/source"),
        .files = &.{
            "default_handlers.c", "event.c",    "interpreter.c", "io.c",
            "mutex.c",            "namespace.c", "notify.c",     "opcodes.c",
            "opregion.c",         "osi.c",       "registers.c",  "resources.c",
            "shareable.c",        "sleep.c",     "stdlib.c",     "tables.c",
            "types.c",            "uacpi.c",     "utilities.c",
        },
        .flags = &.{
            "-ffreestanding",
            "-fno-stack-protector",
            "-fno-sanitize=undefined",
            "-mno-red-zone",
            "-DUACPI_SIZED_FREES",
            "-DUACPI_USE_BUILTIN_STRING",
        },
    });

    b.installArtifact(kernel);
}
