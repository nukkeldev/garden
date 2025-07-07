const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "How to build the library") orelse .static;

    const mod = b.addModule("slang", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        // .sanitize_c = true,
    });

    c_mod.addCSourceFile(.{ .file = b.path("src/root.cpp") });
    c_mod.linkSystemLibrary("shader-slang", .{ .needed = true, .use_pkg_config = .force });

    const c_lib = b.addLibrary(.{
        .name = "c",
        .root_module = c_mod,
        .linkage = .static,
    });
    c_lib.installHeadersDirectory(b.path("src"), "", .{ .include_extensions = &.{".h"} });
    mod.linkLibrary(c_lib);

    const lib = b.addLibrary(.{
        .name = "slang",
        .root_module = mod,
        .linkage = linkage,
    });
    b.installArtifact(lib);
}
