const std = @import("std");

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

pub fn build(b: *std.Build) void {
    // --

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

    // --

    if (target.result.os.tag == .windows and target.result.abi != .msvc) {
        std.log.err("Cannot compile on windows without MSVC! Please specify -Dtarget=*-window-msvc", .{});
        target.result.abi = .msvc;
    }

    // ---

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("build-opts", build_opts_mod);

    const exe = b.addExecutable(.{
        .name = "NRI",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // ---

    if (raw_build_opts.enable_tracy) {
        const src = b.dependency("tracy", .{}).path(".");
        const mod_ = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });

        mod_.addCMacro("TRACY_ENABLE", "");
        mod_.addIncludePath(src.path(b, "public"));
        mod_.addCSourceFile(.{ .file = src.path(b, "public/TracyClient.cpp"), .flags = &.{"-std=c++17"} });

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

    // ---

    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(.{ .cwd_relative = "C:/VulkanSDK/1.4.313.2/Include/" });

    // ---

    mod.addLibraryPath(.{ .cwd_relative = "C:/VulkanSDK/1.4.313.2/Lib" });
    mod.addLibraryPath(b.path("bin/NRI/"));
    mod.addLibraryPath(b.path("bin/GLFW/"));

    mod.addObjectFile(b.path("bin/NRI/NRI.lib"));
    mod.linkSystemLibrary("vulkan-1", .{});

    // ---

    mod.addObjectFile(b.path("bin/GLFW/glfw3.lib"));

    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("ole32");
    exe.linkSystemLibrary("shell32");
    exe.linkSystemLibrary("uuid");
    exe.linkSystemLibrary("winmm");
    exe.linkSystemLibrary("dinput8");
    exe.linkSystemLibrary("dxguid");

    // ---

    const check = b.step("check", "checks");
    check.dependOn(&exe.step);

    // ---

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
