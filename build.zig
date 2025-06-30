const std = @import("std");
const cimgui = @import("cimgui_zig");

pub fn build(b: *std.Build) !void {
    // Options

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_ztracy = b.option(bool, "enable_ztracy", "Enable Tracy profile markers") orelse false;
    const enable_fibers = b.option(bool, "enable_fibers", "Enable Tracy fiber support") orelse false;
    const on_demand = b.option(bool, "on_demand", "Build tracy with TRACY_ON_DEMAND") orelse false;

    // Executable

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "garden",
        .root_module = exe_mod,
        // .use_llvm = false,
    });
    b.installArtifact(exe);

    // Dependencies

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .sanitize_c = .full,
    });
    exe.linkLibrary(sdl_dep.artifact("SDL3"));

    const cimgui_dep = b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
        .platform = cimgui.Platform.SDLGPU3,
        .renderer = cimgui.Renderer.Vulkan,
    });
    exe.linkLibrary(cimgui_dep.artifact("cimgui"));

    const zm = b.dependency("zm", .{});
    exe_mod.addImport("zm", zm.module("zm"));

    const entt = b.dependency("entt", .{});
    exe_mod.addImport("ecs", entt.module("zig-ecs"));

    const obj_mod = b.dependency("obj", .{ .target = target, .optimize = optimize }).module("obj");
    exe_mod.addImport("obj", obj_mod);

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = enable_ztracy,
        .enable_fibers = enable_fibers,
        .on_demand = on_demand,
    });
    exe_mod.addImport("ztracy", ztracy.module("root"));
    exe.linkLibrary(ztracy.artifact("tracy"));

    {
        const tinyobjloader = b.dependency("tinyobjloader", .{});
        const wf = b.addWriteFile(
            "tinyobj_loader_c_wrapper.c",
            "#define TINYOBJ_LOADER_C_IMPLEMENTATION\n#include <tinyobj_loader_c.h>",
        );

        exe_mod.addCSourceFile(.{ .file = wf.getDirectory().path(b, "tinyobj_loader_c_wrapper.c") });
        exe_mod.addIncludePath(tinyobjloader.path("."));
    }

    // Command: build-shaders

    const build_shaders = b.step("build-shaders", "Builds all of the shaders.");
    build_shaders.dependOn(try buildShaders(b));

    exe.step.dependOn(build_shaders);

    // Command: run

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Command: test

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = b.args orelse &.{},
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Command: check

    const check_step = b.step("check", "Checks");
    check_step.dependOn(&exe.step);

    // Command: clean

    const clean_step = b.step("clean", "Cleans");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
}

fn buildShaders(b: *std.Build) !*std.Build.Step {
    const step = try b.allocator.create(std.Build.Step);
    step.* = .init(.{
        .id = .custom,
        .name = "compile shaders",
        .owner = b,
    });

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir.addDirectoryArg(b.path("src/assets/shaders/compiled"));

    const vert = b.addSystemCommand(&.{
        "slangc",
        "src/assets/shaders/vertex.slang",
        "-entry",
        "vertexMain",
        "-stage",
        "vertex",
        "-profile",
        "spirv_1_3",
        "-o",
        "src/assets/shaders/compiled/vertex.spv",
        "-fvk-use-entrypoint-name",
        "-reflection-json",
        "src/assets/shaders/compiled/vertex.layout",
        "-matrix-layout-row-major",
    });
    vert.step.dependOn(&mkdir.step);
    step.dependOn(&vert.step);

    const frag = b.addSystemCommand(&.{
        "slangc",
        "src/assets/shaders/fragment.slang",
        "-entry",
        "fragmentMain",
        "-stage",
        "fragment",
        "-profile",
        "spirv_1_3",
        "-o",
        "src/assets/shaders/compiled/fragment.spv",
        "-fvk-use-entrypoint-name",
        "-reflection-json",
        "src/assets/shaders/compiled/fragment.layout",
        "-matrix-layout-row-major",
    });
    frag.step.dependOn(&mkdir.step);
    step.dependOn(&frag.step);

    return step;
}
