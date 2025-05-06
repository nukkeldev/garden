// Dependencies
const std = @import("std");
const sokol = @import("sokol");

// Aliases
const slog = sokol.log; // Default logging callback for sokol internal APIs.
const sg = sokol.gfx; // 3D-API abstraction, doesn't handle windowing or presentation.
const sapp = sokol.app; // Cross-platform application abstraction, handles windowing and framebuffer.
const sglue = sokol.glue; // Glues *gfx and *app together.

// Shaders
const shd = @import("shaders/build/triangle.glsl.zig"); // Offline cross-compiled shader.

fn makePipelineFromShader(comptime shader: type) sg.Pipeline {
    // var layout: sg.VertexLayoutState = .{};

    // Store the shader description.
    const desc = b: {
        var desc: sg.ShaderDesc = undefined;
        // Iterate through all of the shader struct's declarations.
        inline for (@typeInfo(shader).@"struct".decls) |decl| {
            // Filter for attribute indicies.
            if (std.mem.endsWith(u8, decl.name, "ShaderDesc")) {
                desc = @call(.auto, @field(shader, decl.name), .{sg.queryBackend()});
                break;
            }
        }
        break :b desc;
    };
    _ = desc;

    return sg.makePipeline(.{
        .shader = sg.makeShader(shd.triangleShaderDesc(sg.queryBackend())),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_triangle_position].format = .FLOAT3;
            l.attrs[shd.ATTR_triangle_color0].format = .FLOAT4;
            break :init l;
        },
    });
}

// Program State
const state = struct {
    // Resource bindings (buffers, images, shaders, etc.).
    var bind: sg.Bindings = .{};
    // Rendering pipeline.
    var pip: sg.Pipeline = .{};
    // Pass action.
    var pass_action: sg.PassAction = .{};
};

// Initialization
export fn init() void {
    sg.setup(.{
        // Configure sokol to use sapp's environment via sglue.
        .environment = sglue.environment(),
        // Assign slog to be the logging callback.
        .logger = .{ .func = slog.func },
    });

    // Create a vertex buffer with verticies corresponding to a triangle.
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            // positions.....colors
            -0.5,  0.5,  0.5, 1.0, 0.0, 0.0, 1.0,
            -0.05, -0.5, 0.5, 0.0, 1.0, 0.0, 1.0,
            -0.95, -0.5, 0.5, 0.0, 0.0, 1.0, 1.0,
        }),
    });

    // Create the shader and pipeline objects.
    state.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shd.triangleShaderDesc(sg.queryBackend())),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_triangle_position].format = .FLOAT3;
            l.attrs[shd.ATTR_triangle_color0].format = .FLOAT4;
            break :init l;
        },
    });

    // Create a pass action to clear the background to black.
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
}

export fn frame() void {
    // default pass-action clears to grey
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.draw(0, 3, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}

// -- Main --

pub fn main() void {
    _ = makePipelineFromShader(shd);
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 1280,
        .height = 720,
        .icon = .{ .sokol_default = true },
        .window_title = "triangle.zig",
        .logger = .{ .func = slog.func },
    });
}
