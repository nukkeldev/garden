const std = @import("std");

// -- Private Options -- //

const SLANG_SHADER_DIR: []const u8 = "src/assets/shaders";
const SLANG_SPIRV_PROFILE: []const u8 = "spirv_1_3";

// -- Options -- //

/// Non-standard options specified by the user when invoking `zig build`.
const RawBuildOptions = struct {
    enable_tracy: bool,
    enable_tracy_callstack: bool,
};

// Standard Build Options
var target: std.Build.ResolvedTarget = undefined;
var optimize: std.builtin.OptimizeMode = undefined;

var raw_build_opts: RawBuildOptions = undefined;
var build_opts_mod: *std.Build.Module = undefined;

// -- Functions -- //

/// Turns the raw build options to an import-able module.
pub fn createBuildOptions(b: *std.Build) void {
    const options = b.addOptions();

    options.addOption(bool, "enable_tracy", raw_build_opts.enable_tracy);
    options.addOption(bool, "enable_tracy_callstack", raw_build_opts.enable_tracy_callstack);

    build_opts_mod = options.createModule();
}

/// Creates our primary executable.
pub fn createExecutable(
    b: *std.Build,
    install_artifact: bool,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add build options.
    mod.addImport("build-opts", build_opts_mod);

    // Add C dependencies.
    mod.linkLibrary(b.dependency("sdl", .{
        .target = target,
        .optimize = .ReleaseFast,
    }).artifact("SDL3"));

    mod.linkLibrary(b.dependency("cimgui_zig", .{
        .target = target,
        .optimize = .ReleaseFast,
        .platform = .SDLGPU3,
        .renderer = .Vulkan,
    }).artifact("cimgui"));

    {
        const tinyobjloader_c = b.dependency("tinyobjloader_c", .{});
        const tinyobjloader_c_wrapper_wf = b.addWriteFiles();
        const @"wrapper.c" = tinyobjloader_c_wrapper_wf.add("wrapper.c",
            \\#define TINYOBJ_LOADER_C_IMPLEMENTATION
            \\#include <tinyobj_loader_c.h>
        );

        const mod_ = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });

        mod_.addCSourceFile(.{ .file = @"wrapper.c" });
        mod_.addIncludePath(tinyobjloader_c.path("."));

        const tinyobjloader_c_lib = b.addLibrary(.{
            .name = "tinyobjloader-c",
            .root_module = mod_,
            .linkage = .static,
        });
        tinyobjloader_c_lib.installHeadersDirectory(tinyobjloader_c.path("."), "", .{ .include_extensions = &.{".h"} });

        mod.linkLibrary(tinyobjloader_c_lib);
    }

    if (raw_build_opts.enable_tracy) {
        const src = b.dependency("tracy", .{}).path(".");
        const mod_ = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        });

        mod_.addCMacro("TRACY_ENABLE", "");
        mod_.addIncludePath(src.path(b, "public"));
        mod_.addCSourceFile(.{ .file = src.path(b, "public/TracyClient.cpp") });

        if (target.result.os.tag == .windows) {
            mod_.linkSystemLibrary("dbghelp", .{ .needed = true });
            mod_.linkSystemLibrary("ws2_32", .{ .needed = true });
        }

        const lib = b.addLibrary(.{
            .name = "tracy",
            .root_module = mod_,
            .linkage = .static,
        });
        lib.installHeadersDirectory(src.path(b, "public"), "", .{ .include_extensions = &.{".h"} });

        mod.linkLibrary(lib);
    }

    // TODO: Option this in the future, when reimplementing offline shader compilation.
    mod.addImport("slang", b.dependency("slang", .{
        .optimize = .ReleaseFast,
    }).module("slang"));

    // Add zig dependencies.
    mod.addImport("zm", b.dependency("zm", .{}).module("zm"));
    mod.addImport("img", b.dependency("zigimg", .{}).module("zigimg"));

    const exe = b.addExecutable(.{
        .name = "garden",
        .root_module = mod,
    });
    if (install_artifact) b.installArtifact(exe);

    return exe;
}

// -- Build -- //

pub fn build(b: *std.Build) !void {
    // Options

    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});

    raw_build_opts = RawBuildOptions{
        .enable_tracy = b.option(
            bool,
            "enable-tracy",
            "Whether to enable tracy profiling (low overhead) [default = false]",
        ) orelse false,
        .enable_tracy_callstack = b.option(
            bool,
            "enable-tracy-callstack",
            "Enforce callstack collection for tracy regions [default = false]",
        ) orelse false,
    };
    createBuildOptions(b);

    // Executable

    const exe = createExecutable(b, true);

    // Commands

    // const build_shaders_step = createBuildShadersStep(b, &.{
    //     "phong",
    // });
    // exe.step.dependOn(build_shaders_step);

    // --

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    // --

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = b.args orelse &.{},
    });
    const run_exe_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // --

    const check_step = b.step("check", "Compiles without installation");
    check_step.dependOn(&exe.step);

    // --

    const clean_step = b.step("clean", "Deletes `zig-out`");
    clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
}

// TODO: Deprecated Offline Shader Compilation
// /// Creates a step that invokes `slangc` for all supplied shader paths that are
// /// relative to `src/assets/shaders` WITHOUT their `.slang` file extension.
// fn createBuildShadersStep(b: *std.Build, rel_slang_paths: []const []const u8) *std.Build.Step {
//     const step = b.step("build-shaders", "Builds the pre-defined shaders");
//     step.* = .init(.{
//         .id = .custom,
//         .name = "build-shaders",
//         .owner = b,
//     });

//     // Make sure the directory exists.
//     // TODO: Replace this with something not system-specific.
//     const mkdir = b.addSystemCommand(&.{ "mkdir", "-p" });
//     mkdir.addDirectoryArg(b.path(SLANG_SHADER_DIR ++ "/compiled"));

//     for (rel_slang_paths) |path| {
//         const compile = b.addSystemCommand(&.{
//             "slangc",
//             b.fmt(SLANG_SHADER_DIR ++ "/{s}.slang", .{path}),
//             "-profile",
//             SLANG_SPIRV_PROFILE,
//             "-o",
//             SLANG_SHADER_DIR ++ "/compiled/phong.spv",
//             "-reflection-json",
//             SLANG_SHADER_DIR ++ "/compiled/phong.slang.layout",
//             "-fvk-use-entrypoint-name", // Allows for multiple entrypoints in a single file.
//             "-matrix-layout-row-major", // `slangc` legacy default, changed with online API iirc.
//         });
//         compile.step.dependOn(&mkdir.step);
//         step.dependOn(&compile.step);
//     }

//     return step;
// }
