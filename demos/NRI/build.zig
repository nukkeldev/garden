const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --

    if (target.result.os.tag == .windows and target.result.abi != .msvc) {
        @panic("Cannot compile on windows without MSVC! Please specify -Dtarget=*-window-msvc");
    }

    // ---

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "NRI",
        .root_module = mod,
    });
    b.installArtifact(exe);

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
