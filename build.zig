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
    });

    const exe = b.addExecutable(.{
        .name = "graphics",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Dependencies

    dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dynamic_linkage = false,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    exe_mod.addImport("sokol", dep_sokol.module("sokol"));
    exe_mod.addImport("cimgui", dep_cimgui.module("cimgui"));

    const zm = b.dependency("zm", .{});
    exe_mod.addImport("zm", zm.module("zm"));

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
}

/// Builds all GLSL shaders in the `src/shaders` directory.
fn buildShaders(b: *std.Build) !*std.Build.Step {
    const step = try b.allocator.create(std.Build.Step);
    step.* = .init(.{
        .id = .custom,
        .name = "compile shaders",
        .owner = b,
    });

    const vert = b.addSystemCommand(&.{
        "slangc",
        "src/shaders/shader.slang",
        "-entry",
        "vertexMain",
        "-stage",
        "vertex",
        "-target",
        "glsl",
        "-profile",
        "glsl_410",
        "-o",
        "src/shaders/shader.vert.glsl",
        "-reflection-json",
        "src/shaders/shader.layout.json",
    });
    step.dependOn(&vert.step);

    const frag = b.addSystemCommand(&.{
        "slangc",
        "src/shaders/shader.slang",
        "-entry",
        "fragmentMain",
        "-stage",
        "fragment",
        "-target",
        "glsl",
        "-profile",
        "glsl_410",
        "-o",
        "src/shaders/shader.frag.glsl",
    });
    step.dependOn(&frag.step);

    return step;
}
