// Dependencies
const std = @import("std");
const sokol = @import("sokol");
const ig = @import("cimgui");

const hmm = @cImport({
    @cInclude("HandmadeMath.h");
});

// Aliases
const slog = sokol.log; // Default logging callback for sokol internal APIs.
const sg = sokol.gfx; // 3D-API abstraction, doesn't handle windowing or presentation.
const sapp = sokol.app; // Cross-platform application abstraction, handles windowing and framebuffer.
const sglue = sokol.glue; // Glues *gfx and *app together.
const simgui = sokol.imgui; // cimgui interop.

const Mat4 = hmm.HMM_Mat4;
const Vec4 = hmm.HMM_Vec4;

// Shaders
// const shd = @import("shaders/build/shader.glsl.zig"); // Offline cross-compiled shader.

// Allocator
var alloc = std.heap.DebugAllocator(.{}).init;

// Program State
const state = struct {
    // Resource bindings (buffers, images, shaders, etc.).
    var bind: sg.Bindings = .{};
    // Rendering pipeline.
    var pip: sg.Pipeline = .{};
    // Pass action.
    var pass_action: sg.PassAction = .{};

    // Cube's rotation.
    var r: struct { f32, f32, f32 } = .{ 0.0, 0.0, 0.0 };
    var zoom: f32 = 1.0;

    // View matrix.
    // const view = Mat4.createLookAt(zlm.vec3(0.0, 1.5, 6.0), Vec3.zero, Vec3.unitY);
};

// Initialization
export fn onInit() void {
    sg.setup(.{
        // Configure sokol to use sapp's environment via sglue.
        .environment = sglue.environment(),
        // Assign slog to be the logging callback.
        .logger = .{ .func = slog.func },
    });
    simgui.setup(.{ .logger = .{ .func = slog.func } });

    // Create a vertex buffer with verticies corresponding to a triangle.
    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        // zig fmt: off
        .data = sg.asRange(&[_]f32{
            // positions.....colors
             0.0,  0.5, 1.0, 1.0, 0.0, 0.0,
             0.5, -0.5, 1.0, 0.0, 0.0, 1.0,
            -0.5, -0.5, 1.0, 0.0, 1.0, 0.0,
            // -0.0, -1.0, -1.0, 1.0, 0.0, 0.0, 1.0,
            // 1.0,  -1.0, -1.0, 1.0, 0.0, 0.0, 1.0,
            // 1.0,  1.0,  -1.0, 1.0, 0.0, 0.0, 1.0,
            // -1.0, 1.0,  -1.0, 1.0, 0.0, 0.0, 1.0,

            // -1.0, -1.0, 1.0,  0.0, 1.0, 0.0, 1.0,
            // 1.0,  -1.0, 1.0,  0.0, 1.0, 0.0, 1.0,
            // 1.0,  1.0,  1.0,  0.0, 1.0, 0.0, 1.0,
            // -1.0, 1.0,  1.0,  0.0, 1.0, 0.0, 1.0,

            // -1.0, -1.0, -1.0, 0.0, 0.0, 1.0, 1.0,
            // -1.0, 1.0,  -1.0, 0.0, 0.0, 1.0, 1.0,
            // -1.0, 1.0,  1.0,  0.0, 0.0, 1.0, 1.0,
            // -1.0, -1.0, 1.0,  0.0, 0.0, 1.0, 1.0,

            // 1.0,  -1.0, -1.0, 1.0, 0.5, 0.0, 1.0,
            // 1.0,  1.0,  -1.0, 1.0, 0.5, 0.0, 1.0,
            // 1.0,  1.0,  1.0,  1.0, 0.5, 0.0, 1.0,
            // 1.0,  -1.0, 1.0,  1.0, 0.5, 0.0, 1.0,

            // -1.0, -1.0, -1.0, 0.0, 0.5, 1.0, 1.0,
            // -1.0, -1.0, 1.0,  0.0, 0.5, 1.0, 1.0,
            // 1.0,  -1.0, 1.0,  0.0, 0.5, 1.0, 1.0,
            // 1.0,  -1.0, -1.0, 0.0, 0.5, 1.0, 1.0,

            // -1.0, 1.0,  -1.0, 1.0, 0.0, 0.5, 1.0,
            // -1.0, 1.0,  1.0,  1.0, 0.0, 0.5, 1.0,
            // 1.0,  1.0,  1.0,  1.0, 0.0, 0.5, 1.0,
            // 1.0,  1.0,  -1.0, 1.0, 0.0, 0.5, 1.0,
        }),
        // zig fmt: on
    });

    // Create the index buffer for the cube's verticies.
    // state.bind.index_buffer = sg.makeBuffer(.{
    //     .type = .INDEXBUFFER,
    //     .data = sg.asRange(&[_]u16{
    //         0,  1,  2,  0,  2,  3,
    //         6,  5,  4,  7,  6,  4,
    //         8,  9,  10, 8,  10, 11,
    //         14, 13, 12, 15, 14, 12,
    //         16, 17, 18, 16, 18, 19,
    //         22, 21, 20, 23, 22, 20,
    //     }),
    // });

    // Create a pass action to clear the background to black.
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    // Load the pipeline.
    loadPipeline();
}

export fn onFrame() void {
    // UI
    {
        simgui.newFrame(.{
            .width = sapp.width(),
            .height = sapp.height(),
            .delta_time = sapp.frameDuration(),
            .dpi_scale = sapp.dpiScale(),
        });

        ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_Once);
        ig.igSetNextWindowSize(.{ .x = 350, .y = 125 }, ig.ImGuiCond_Once);

        _ = ig.igBegin("Controls", 0, ig.ImGuiWindowFlags_None);
        _ = ig.igDragFloat3Ex("Rotation (Deg)", &state.r[0], 1, 0, 360, "%0.3f", ig.ImGuiSliderFlags_WrapAround);
        _ = ig.igDragFloatEx("Zoom", &state.zoom, 0.025, 0.1, 10, "%0.3f", ig.ImGuiSliderFlags_None);
        _ = ig.igSeparator();

        ig.igEnd();
    }
    // UI end

    // Rendering
    {
        // const dt: f32 = @floatCast(sapp.frameDuration());
        // state.r[2] += std.math.pi * dt;
        // state.r[0] += dt;
        // state.r[1] += dt;
        // const vertexParams = b: {
        //     const zm = Mat4.createUniformScale(state.zoom);
        //     const rx = Mat4.createAngleAxis(Vec3.unitX, zlm.toRadians(state.r[0]));
        //     const ry = Mat4.createAngleAxis(Vec3.unitY, zlm.toRadians(state.r[1]));
        //     const rz = Mat4.createAngleAxis(Vec3.unitZ, zlm.toRadians(state.r[2]));
        //     const model = Mat4.batchMul(&[_]Mat4{ rx, ry, rz, zm });

        //     const aspect = sapp.widthf() / sapp.heightf();
        //     const proj = Mat4.createPerspective(zlm.toRadians(60.0), aspect, 0.01, 10.0);

        //     break :b shd.VsParams{ .mvp = Mat4.batchMul(&[_]Mat4{ proj, state.view, model }) };
        // };

        // Render.
        sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
        {
            sg.applyPipeline(state.pip);
            sg.applyBindings(state.bind);
            sg.draw(0, 3, 1);
            simgui.render();
        }
        sg.endPass();
        sg.commit();
    }
    // Rendering end
}

export fn onEvent(event_ptr: [*c]const sapp.Event) void {
    const event: sapp.Event = event_ptr.*;

    if (event.key_code == .Q) {
        sapp.quit();
        return;
    }

    _ = simgui.handleEvent(event);
}

export fn onCleanup() void {
    simgui.shutdown();
    sg.shutdown();
}

fn loadPipeline() void {
    const backend = sg.queryBackend();
    std.log.info("Creating pipeline for backend: {}", .{backend});

    const shader = outer: switch (backend) {
        .GLCORE => {
            // TODO: Load from file.
            const vert_shader = @embedFile("shaders/shader.vert.glsl");
            const frag_shader = @embedFile("shaders/shader.frag.glsl");

            var desc = sg.ShaderDesc{
                .label = "Shader",
                .vertex_func = .{
                    .source = vert_shader,
                    .entry = "vertexMain",
                },
                .fragment_func = .{
                    .source = frag_shader,
                    .entry = "fragmentMain",
                },
            };

            desc.attrs[0].base_type = .FLOAT;
            desc.attrs[0].glsl_name = "assembledVertex_position_0";
            desc.attrs[1].base_type = .FLOAT;
            desc.attrs[1].glsl_name = "assembledVertex_color_0";

            break :outer sg.makeShader(desc);
        },
        else => std.debug.panic("Unsupported backend: {}!", .{backend}),
    };

    state.pip = sg.makePipeline(.{
        .shader = shader,
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[0].format = .FLOAT3;
            l.attrs[1].format = .FLOAT3;
            break :init l;
        },
        .depth = .{
            .compare = .LESS_EQUAL,
            .write_enabled = true,
        },
        .cull_mode = .BACK,
    });
}

// -- Main --

pub fn main() void {
    sapp.run(.{
        .init_cb = onInit,
        .frame_cb = onFrame,
        .event_cb = onEvent,
        .cleanup_cb = onCleanup,
        .width = 720,
        .height = 720,
        .sample_count = 4,
        .icon = .{ .sokol_default = true },
        .window_title = "game engine",
        .logger = .{ .func = slog.func },
    });
}
