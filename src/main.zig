// Dependencies
const std = @import("std");
const sokol = @import("sokol");
const m = @import("math.zig");

// Aliases
const slog = sokol.log; // Default logging callback for sokol internal APIs.
const sg = sokol.gfx; // 3D-API abstraction, doesn't handle windowing or presentation.
const sapp = sokol.app; // Cross-platform application abstraction, handles windowing and framebuffer.
const sglue = sokol.glue; // Glues *gfx and *app together.

const mat4 = m.Mat4;

// Shaders
const shd = @import("shaders/build/shader.glsl.zig"); // Offline cross-compiled shader.

// Program State
const state = struct {
    // Resource bindings (buffers, images, shaders, etc.).
    var bind: sg.Bindings = .{};
    // Rendering pipeline.
    var pip: sg.Pipeline = .{};
    // Pass action.
    var pass_action: sg.PassAction = .{};

    // Cube's rotation.
    var r: struct { f32, f32 } = .{ 0.0, 0.0 };
    // View matrix.
    const view: mat4 = mat4.lookat(.{ .x = 0.0, .y = 1.5, .z = 6.0 }, m.Vec3.zero(), m.Vec3.up());
};

// Initialization
export fn onInit() void {
    sg.setup(.{
        // Configure sokol to use sapp's environment via sglue.
        .environment = sglue.environment(),
        // Assign slog to be the logging callback.
        .logger = .{ .func = slog.func },
    });

    // Create a vertex buffer with verticies corresponding to a cube.
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            // positions......colors
            -1.0, -1.0, -1.0, 1.0, 0.0, 0.0, 1.0,
            1.0,  -1.0, -1.0, 1.0, 0.0, 0.0, 1.0,
            1.0,  1.0,  -1.0, 1.0, 0.0, 0.0, 1.0,
            -1.0, 1.0,  -1.0, 1.0, 0.0, 0.0, 1.0,

            -1.0, -1.0, 1.0,  0.0, 1.0, 0.0, 1.0,
            1.0,  -1.0, 1.0,  0.0, 1.0, 0.0, 1.0,
            1.0,  1.0,  1.0,  0.0, 1.0, 0.0, 1.0,
            -1.0, 1.0,  1.0,  0.0, 1.0, 0.0, 1.0,

            -1.0, -1.0, -1.0, 0.0, 0.0, 1.0, 1.0,
            -1.0, 1.0,  -1.0, 0.0, 0.0, 1.0, 1.0,
            -1.0, 1.0,  1.0,  0.0, 0.0, 1.0, 1.0,
            -1.0, -1.0, 1.0,  0.0, 0.0, 1.0, 1.0,

            1.0,  -1.0, -1.0, 1.0, 0.5, 0.0, 1.0,
            1.0,  1.0,  -1.0, 1.0, 0.5, 0.0, 1.0,
            1.0,  1.0,  1.0,  1.0, 0.5, 0.0, 1.0,
            1.0,  -1.0, 1.0,  1.0, 0.5, 0.0, 1.0,

            -1.0, -1.0, -1.0, 0.0, 0.5, 1.0, 1.0,
            -1.0, -1.0, 1.0,  0.0, 0.5, 1.0, 1.0,
            1.0,  -1.0, 1.0,  0.0, 0.5, 1.0, 1.0,
            1.0,  -1.0, -1.0, 0.0, 0.5, 1.0, 1.0,

            -1.0, 1.0,  -1.0, 1.0, 0.0, 0.5, 1.0,
            -1.0, 1.0,  1.0,  1.0, 0.0, 0.5, 1.0,
            1.0,  1.0,  1.0,  1.0, 0.0, 0.5, 1.0,
            1.0,  1.0,  -1.0, 1.0, 0.0, 0.5, 1.0,
        }),
    });

    // Create the index buffer for the cube's verticies.
    state.bind.index_buffer = sg.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = sg.asRange(&[_]u16{
            0,  1,  2,  0,  2,  3,
            6,  5,  4,  7,  6,  4,
            8,  9,  10, 8,  10, 11,
            14, 13, 12, 15, 14, 12,
            16, 17, 18, 16, 18, 19,
            22, 21, 20, 23, 22, 20,
        }),
    });

    // Create the pipeline.
    state.pip = sg.makePipeline(shd.shaderGetPipelineDesc(.{
        .index_type = .UINT16,
        .depth = .{
            .compare = .LESS_EQUAL,
            .write_enabled = true,
        },
        .cull_mode = .BACK,
    }));

    // Create a pass action to clear the background to black.
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
}

export fn onFrame() void {
    const dt: f32 = @floatCast(sapp.frameDuration() * 60);
    state.r[0] += dt;
    state.r[1] += dt;
    const vertexParams = b: {
        const rxm = mat4.rotate(state.r[0], .{ .x = 1.0, .y = 0.0, .z = 0.0 });
        const rym = mat4.rotate(state.r[1], .{ .x = 0.0, .y = 1.0, .z = 0.0 });
        const model = mat4.mul(rxm, rym);
        const aspect = sapp.widthf() / sapp.heightf();
        const proj = mat4.persp(60.0, aspect, 0.01, 10.0);
        break :b shd.VsParams{ .mvp = mat4.mul(mat4.mul(proj, state.view), model) };
    };

    // Render.
    defer sg.commit();
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    {
        sg.applyPipeline(state.pip);
        sg.applyBindings(state.bind);
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vertexParams));
        sg.draw(0, 36, 1);
    }
    sg.endPass();
}

export fn onEvent(event_ptr: [*c]const sapp.Event) void {
    const event: sapp.Event = event_ptr.*;
    _ = event;
    // std.debug.print("Event: {}\n", .{event});
}

export fn onCleanup() void {
    sg.shutdown();
}

// -- Main --

pub fn main() void {
    sapp.run(.{
        .init_cb = onInit,
        .frame_cb = onFrame,
        .event_cb = onEvent,
        .cleanup_cb = onCleanup,
        .width = 1280,
        .height = 720,
        .sample_count = 4,
        .icon = .{ .sokol_default = true },
        .window_title = "game engine",
        .logger = .{ .func = slog.func },
    });
}
