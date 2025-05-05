const std = @import("std");
const sokol = @import("sokol");
const shdc = @import("shdc");

pub fn build(b: *std.Build) void {
    // Settings

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

    { // Sokol
        const dep_sokol = b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .dynamic_linkage = false,
            .wayland = true,
        });

        exe_mod.addImport("sokol", dep_sokol.module("sokol"));

        buildShaders(b, dep_sokol, &exe.step) catch @panic("Failed to build shaders!");
    }

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

fn buildShaders(b: *std.Build, dep_sokol: *std.Build.Dependency, dependent: *std.Build.Step) !void {
    const shaders = [_][]const u8{
        "triangle",
    };

    for (shaders) |shader| {
        const input_path = b.fmt("src/shaders/{s}.glsl", .{shader});
        const output_path = b.fmt("src/shaders/build/{s}.zig", .{shader});

        dependent.dependOn(&(try sokol.shdc.compile(b, .{
            .dep_shdc = dep_sokol.builder.dependency("shdc", .{}),
            .input = b.path(input_path),
            .output = b.path(output_path),
            .slang = .{
                .glsl430 = false,
                .glsl410 = true,
                .glsl310es = false,
                .glsl300es = true,
                .metal_macos = true,
                .hlsl5 = true,
                .wgsl = true,
            },
            .reflection = true,
        })).step);
    }
}
