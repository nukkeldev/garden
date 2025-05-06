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

/// Builds all GLSL shaders in the `src/shaders` directory.
fn buildShaders(b: *std.Build, dep_sokol: *std.Build.Dependency, dependent: *std.Build.Step) !void {
    // Open shaders directory.
    var dir = try std.fs.cwd().openDir("src/shaders", .{ .iterate = true });
    defer dir.close();

    // Iterate through all of the items in the directory.
    var iter = dir.iterate();
    while (try iter.next()) |item| {
        // Filter only for shader files.
        if (item.kind != std.fs.File.Kind.file or !std.mem.endsWith(u8, item.name, ".glsl")) continue;

        // Set the input and output file paths.
        const input_path = b.fmt("src/shaders/{s}", .{item.name});
        const output_path = b.fmt("src/shaders/build/{s}.zig", .{item.name});

        // Create the compilation command and bind it to the dependent step.
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
