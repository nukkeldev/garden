const std = @import("std");

const c = @cImport({
    // GLFW
    @cDefine("GLFW_DLL", {});
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");

    // NRI
    @cInclude("NRI/NRI.h");
    @cInclude("NRI/Extensions/NRIDeviceCreation.h");
});

var window: *c.GLFWwindow = undefined;

export fn glfwErrorCallback(err: c_int, description: [*c]const u8) void {
    std.log.err("GLFW Error: {s}", .{description});
    std.process.exit(@intCast(err));
}

pub extern fn glfwInit() callconv(.c) c_int;

pub fn main() !void {
    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    if (glfwInit() == c.GLFW_FALSE) return error.GLFWInitFailure;
    defer c.glfwTerminate();

    std.log.info("Using NRI Version: {}", .{c.NRI_VERSION});

    window = c.glfwCreateWindow(1024, 1024, "NRI Demo", null, null) orelse return error.GLFWCreateWindowFailure;
    defer c.glfwDestroyWindow(window);

    // setup your graphics context here

    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        c.glfwPollEvents();
    }

    var result: c.NriResult = undefined;

    var adapters: [2]c.NriAdapterDesc = undefined;
    result = c.nriEnumerateAdapters(&adapters, null);
    if (result != c.NriResult_SUCCESS) {
        std.log.err("nriEnumerateAdapters(): {}", .{result});
        return error.NriError;
    }

    for (adapters, 0..) |adapter, i| std.log.info("Adapter {}: {}", .{ i, adapter });
}
