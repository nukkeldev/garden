const std = @import("std");

// Notes
// - SLANG_LIB_TYPE=STATIC in CMake builds a static library.
//  - Corresponds to `#define SLANG_STATIC` I'd assume.
// -

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    mod.addIncludePath(b.path("include"));

    mod.addCSourceFiles(.{
        .root = b.path("source"),
        .files = &.{
            "slangc/main.cpp",
        },
        .language = .cpp,
    });

    const exe = b.addExecutable(.{
        .name = "slangc",
        .root_module = mod,
    });

    b.installArtifact(exe);
}
