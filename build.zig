const std = @import("std");
const sokol = @import("sokol");

var dep_sokol: *std.Build.Dependency = undefined;

pub fn build(b: *std.Build) !void {
    // Options

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "garden",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Dependencies

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    exe_mod.linkSystemLibrary("SDL3", .{});
    exe_mod.addImport("cimgui", dep_cimgui.module("cimgui"));

    const zm = b.dependency("zm", .{});
    exe_mod.addImport("zm", zm.module("zm"));

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
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Command: check

    const check_step = b.step("check", "Checks");
    check_step.dependOn(&exe.step);
}

fn buildShaders(b: *std.Build) !*std.Build.Step {
    const step = try b.allocator.create(std.Build.Step);
    step.* = .init(.{
        .id = .custom,
        .name = "compile shaders",
        .owner = b,
    });
    step.result_cached = false;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
    mkdir.addDirectoryArg(b.path("src/shaders/compiled"));

    const vert = b.addSystemCommand(&.{
        "slangc",
        "src/shaders/shader.slang",
        "-entry",
        "vertexMain",
        "-stage",
        "vertex",
        "-target",
        "spirv",
        "-profile",
        "spirv_1_0",
        "-o",
        "src/shaders/compiled/shader.vert.spv",
        "-fvk-use-entrypoint-name",
        "-reflection-json",
        "src/shaders/compiled/shader.vert.layout",
        "-emit-spirv-via-glsl",
    });
    vert.step.dependOn(&mkdir.step);
    step.dependOn(&vert.step);

    const frag = b.addSystemCommand(&.{
        "slangc",
        "src/shaders/shader.slang",
        "-entry",
        "fragmentMain",
        "-stage",
        "fragment",
        "-target",
        "spirv",
        "-profile",
        "spirv_1_0",
        "-o",
        "src/shaders/compiled/shader.frag.spv",
        "-fvk-use-entrypoint-name",
        "-reflection-json",
        "src/shaders/compiled/shader.frag.layout",
        "-emit-spirv-via-glsl",
    });
    frag.step.dependOn(&mkdir.step);
    step.dependOn(&frag.step);

    return step;
}
