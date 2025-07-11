const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // ---

    mod.addObjectFile(b.path("bin/NRI/NRI.lib"));
    // TODO: error: lld-link: D:\Development\Zig\garden\demos\NRI\bin\NRI\amd_ags_x64.dll: bad file type. Did you specify a DLL instead of an import library?
    // mod.addObjectFile(b.path("bin/NRI/amd_ags_x64.dll"));

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
