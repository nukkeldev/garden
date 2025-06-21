const std = @import("std");

const zm = @import("zm");

const gpu = @import("gpu.zig");
const ffi = @import("ffi.zig");
const log = @import("log.zig");
const transform = @import("transform.zig");

const Model = @import("object.zig").Model;
const Mesh = @import("object.zig").Mesh;
const Window = @import("window.zig").Window;

const gdn = log.gdn;
const sdl = log.sdl;
const gui = log.gui;

const c = ffi.c;
const cstr = ffi.cstr;

pub const std_options: std.Options = .{ .log_level = .debug };

// Configuration

const INITIAL_WINDOW_SIZE = .{ .width = 1024, .height = 1024 };
const WINDOW_FLAGS = c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_VULKAN;

const TARGET_FRAMERATE: f32 = 60.0;
const TARGET_FRAMETIME_NS: u64 = @intFromFloat(1e9 / 60.0);

const FRAMES_IN_FLIGHT = 3;

var MOVEMENT_SPEED: f32 = 4.0;
const ZOOM_SPEED: f32 = 2;

const MIN_FOV = 30.0;
const INITIAL_FOV = 120.0;
const MAX_FOV = 150.0;

const PAN_SPEED: f32 = 2;

// State

var shader_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var ecs_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var model_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var debug_allocator = std.heap.DebugAllocator(.{}).init;

var window: Window = undefined;
var im_context: *c.ImGuiContext = undefined;

var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var depth_texture: *c.SDL_GPUTexture = undefined;

var camera: transform.O012 = .{
    .o0 = .{
        .translation = .{ 0, 3, -5 },
        .rotation = .{ 0, std.math.degreesToRadians(90), 0 },
    },
};
var player: Model = .{
    .meshes = undefined,
    .o012 = .{
        .o0 = .{
            .translation = .{ 0, 3, 0 },
            .scale = @splat(0.5),
        },
        .o1 = .{ .rotation = .{ 1, 1, 1 } },
    },
};
var compass: Model = .{
    .meshes = undefined,
    .o012 = .{
        .o0 = .{
            .translation = .{ 0, -0.25, 0 },
            .scale = @splat(0.25),
        },
        .o1 = .{ .rotation = .{ 0, 0.25, 0 } },
    },
};

var o012s = [_]*transform.O012{ &camera, &player.o012, &compass.o012 };
var models = [_]*Model{ &player, &compass };

var fov: f32 = INITIAL_FOV;
var proj_matrix: zm.Mat4f = zm.Mat4f.perspective(std.math.degreesToRadians(INITIAL_FOV), 1.0, 0.05, 100.0);

var last_update_ns: u64 = 0;
var should_exit = false;

var debug = true;
var wireframe = false;

var right_mouse_pressed: bool = false;
var keyboard_state: [*c]const bool = undefined;

// Functions

fn init() !void {
    c.SDL_SetMainReady();

    // Initialize SDL.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) sdl.fatal("SDL_Init(c.SDL_INIT_VIDEO)");

    // Create the window.
    window = Window.init(
        debug_allocator.allocator(),
        .{
            .name = "Garden Demo",
            .initial_size = .{ 1024, 1024 },
        },
        .{
            .close_window = &should_exit,
        },
    ) catch |e| gdn.fatal("Failed to create window: {}!", .{e});

    depth_texture = c.SDL_CreateGPUTexture(window.device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .width = window.size[0],
        .height = window.size[1],
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    }) orelse sdl.fatal("SDL_CreateGPUTexture");

    // Create an ImGui context.
    im_context = c.ImGui_CreateContext(null) orelse gui.fatal("igCreateContext");

    const io = c.ImGui_GetIO();
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls

    // Configure ImGui styling.
    const style = c.ImGui_GetStyle();
    c.ImGui_StyleColorsDark(style);
    c.ImGuiStyle_ScaleAllSizes(style, window.content_scale);

    // Setup ImGui rendering.
    if (!c.cImGui_ImplSDL3_InitForSDLGPU(window.window)) gui.fatal("cImGui_ImplSDL3_InitForSDLGPU");
    var imgui_init = c.ImGui_ImplSDLGPU3_InitInfo{
        .Device = window.device,
        .ColorTargetFormat = window.getSwapchainTextureFormat(),
        .MSAASamples = c.SDL_GPU_SAMPLECOUNT_1,
    };
    if (!c.cImGui_ImplSDLGPU3_Init(&imgui_init)) gui.fatal("cImGui_ImplSDLGPU3_Init");

    // Create the rendering pipeline.
    try load_pipeline(false);

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();

    // Get a pointer to the keyboard state.
    keyboard_state = c.SDL_GetKeyboardState(null);

    // Create the initial models.
    compass.meshes = try Mesh.initFromOBJLeaky(
        model_arena.allocator(),
        window.device,
        @embedFile("assets/models/Compass.obj"),
        @embedFile("assets/models/Compass.mtl"),
    );

    player.meshes = try Mesh.initFromOBJLeaky(
        model_arena.allocator(),
        window.device,
        @embedFile("assets/models/Player.obj"),
        @embedFile("assets/models/Player.mtl"),
    );
}

fn update() !void {
    const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());
    const dt = ticks_ns - last_update_ns;

    // TODO: Get rid of conditional.
    // if (dt < TARGET_FRAMETIME_NS) {
    //     c.SDL_DelayNS(@intCast(TARGET_FRAMETIME_NS - (ticks_ns - last_update_ns)));
    // }

    try pollEvents();
    try updateSystems(ticks_ns, dt);
    try render(ticks_ns, dt);

    last_update_ns = ticks_ns;
}

fn pollEvents() !void {
    camera.o1.rotation = .{ 0, 0, 0 };

    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) {
        _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => if (!event.key.repeat) {
                switch (event.key.scancode) {
                    // General
                    c.SDL_SCANCODE_ESCAPE => should_exit = true,
                    // Debug
                    c.SDL_SCANCODE_R => if (event.key.mod & c.SDL_KMOD_LCTRL != 0) try load_pipeline(true),
                    c.SDL_SCANCODE_F => {
                        wireframe = true;
                        try load_pipeline(false);
                    },
                    c.SDL_SCANCODE_GRAVE => {
                        debug = !debug;
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_KEY_UP => {
                switch (event.key.scancode) {
                    c.SDL_SCANCODE_F => {
                        wireframe = false;
                        try load_pipeline(false);
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (right_mouse_pressed) {
                    camera.o1.rotation[1] = event.motion.xrel * PAN_SPEED;
                    camera.o1.rotation[0] = -event.motion.yrel * PAN_SPEED;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                fov = std.math.clamp(fov - event.wheel.y * ZOOM_SPEED, MIN_FOV, MAX_FOV);
                proj_matrix = zm.Mat4f.perspective(std.math.degreesToRadians(fov), 1.0, 0.05, 100.0);
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button == c.SDL_BUTTON_RIGHT) right_mouse_pressed = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_RIGHT) right_mouse_pressed = false;
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                right_mouse_pressed = false;
            },
            c.SDL_EVENT_QUIT => should_exit = true,
            else => {},
        }
    }

    // Free-Cam
    camera.o1.translation =
        zm.vec.scale(camera.o0.right(), inputAxis(c.SDL_SCANCODE_A, c.SDL_SCANCODE_D) * MOVEMENT_SPEED) +
        zm.vec.scale(camera.o0.up(), inputAxis(c.SDL_SCANCODE_E, c.SDL_SCANCODE_Q) * MOVEMENT_SPEED) +
        zm.vec.scale(camera.o0.forward(), inputAxis(c.SDL_SCANCODE_W, c.SDL_SCANCODE_S) * MOVEMENT_SPEED);
}

fn updateSystems(ticks: u64, dt: u64) !void {
    _ = ticks;

    const dt_s = @as(f32, @floatFromInt(dt)) / 1e9;
    for (o012s) |o012| o012.update(dt_s);

    if (!c.SDL_SetWindowRelativeMouseMode(window.window, right_mouse_pressed)) sdl.err("SDL_SetWindowRelativeMouseMode");
}

fn render(ticks: u64, dt: u64) !void {
    _ = ticks;
    const frame_time_ms = @as(f32, @floatFromInt(dt)) / 1e6;

    const cmd = try window.acquireCommandBuffer();
    const swapchain_texture: ?*c.SDL_GPUTexture = try window.waitAndAcquireGPUSwapchainTexture(cmd);
    if (swapchain_texture == null) return;

    const tex = swapchain_texture.?;

    // SDL Rendering

    const color_target_info = c.SDL_GPUColorTargetInfo{
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .texture = tex,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const depth_stencil_target_info = c.SDL_GPUDepthStencilTargetInfo{
        .texture = depth_texture,
        .cycle = true,
        .clear_depth = 1,
        .clear_stencil = 0,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .stencil_load_op = c.SDL_GPU_LOADOP_CLEAR,
        .stencil_store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target_info, 1, &depth_stencil_target_info) orelse sdl.fatal("SDL_BeginGPURenderPass");

    const view_matrix = zm.Mat4f.lookAt(camera.o0.translation, camera.o0.translation + camera.o0.forward(), zm.vec.up(f32));

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline.?);
    c.SDL_PushGPUFragmentUniformData(cmd, 1, @ptrCast(&camera.o0.translation), @sizeOf(zm.Vec3f));

    for (models) |model| {
        const model_matrix = model.o012.o0.modelMatrix();
        const normal = model_matrix.inverse().transpose().data;

        c.SDL_PushGPUFragmentUniformData(cmd, 0, @ptrCast(&normal), @sizeOf([16]f32));
        c.SDL_PushGPUVertexUniformData(cmd, 0, @ptrCast(&gpu.PerFrameData{
            .model = model_matrix.data,
            .view = view_matrix.data,
            .proj = proj_matrix.data,
        }), @sizeOf(gpu.PerFrameData));

        for (model.meshes) |mesh| {
            mesh.draw(render_pass);
        }
    }

    // ImGui Rendering
    if (debug) renderDebug(cmd, render_pass, frame_time_ms);

    // Submit the render pass.
    c.SDL_EndGPURenderPass(render_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
}

fn exit() !void {
    _ = c.SDL_WaitForGPUIdle(window.device);

    c.cImGui_ImplSDLGPU3_Shutdown();
    c.cImGui_ImplSDL3_Shutdown();
    c.ImGui_DestroyContext(null);

    c.SDL_ReleaseGPUTexture(window.device, depth_texture);
    c.SDL_ReleaseGPUGraphicsPipeline(window.device, pipeline);

    for (models) |model| for (model.meshes) |mesh| mesh.deinit();
    window.deinit();

    shader_arena.deinit();
    ecs_arena.deinit();
    model_arena.deinit();

    c.SDL_Quit();
}

fn load_pipeline(recompile: bool) !void {
    if (pipeline != null) c.SDL_ReleaseGPUGraphicsPipeline(window.device, pipeline);

    var compiled_vertex_shader: gpu.compile.CompiledShader = undefined;
    var compiled_fragment_shader: gpu.compile.CompiledShader = undefined;

    if (recompile) {
        compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/assets/shaders/vertex.slang", .Vertex, pipeline == null, true)).?;
        compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/assets/shaders/fragment.slang", .Fragment, pipeline == null, true)).?;
    } else {
        compiled_vertex_shader = .{
            .allocator = shader_arena.allocator(),
            .spv = std.fs.cwd().readFileAlloc(shader_arena.allocator(), "src/assets/shaders/compiled/vertex.spv", std.math.maxInt(usize)) catch {
                log.gdn.err("Failed to read vertex shader!", .{});
                return;
            },
            .layout = std.fs.cwd().readFileAlloc(shader_arena.allocator(), "src/assets/shaders/compiled/vertex.layout", std.math.maxInt(usize)) catch {
                log.gdn.err("Failed to read vertex shader layout!", .{});
                return;
            },
        };

        compiled_fragment_shader = .{
            .allocator = shader_arena.allocator(),
            .spv = std.fs.cwd().readFileAlloc(shader_arena.allocator(), "src/assets/shaders/compiled/fragment.spv", std.math.maxInt(usize)) catch {
                log.gdn.err("Failed to read fragment shader!", .{});
                return;
            },
            .layout = std.fs.cwd().readFileAlloc(shader_arena.allocator(), "src/assets/shaders/compiled/fragment.layout", std.math.maxInt(usize)) catch {
                log.gdn.err("Failed to read fragment shader layout!", .{});
                return;
            },
        };
    }

    const vertex_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_vertex_shader.layout).?;
    const fragment_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_fragment_shader.layout).?;

    pipeline = gpu.slang.ShaderLayout.createPipeline(window.device, window.window, &vertex_layout, &fragment_layout, compiled_vertex_shader.spv, compiled_fragment_shader.spv, wireframe).?;

    if (recompile) gdn.info("Compiled and reloaded shaders!", .{});
}

fn renderDebug(cmd: *c.SDL_GPUCommandBuffer, render_pass: *c.SDL_GPURenderPass, frame_time_ms: f32) void {
    // Begin a new ImGui frame.
    c.cImGui_ImplSDLGPU3_NewFrame();
    c.cImGui_ImplSDL3_NewFrame();
    c.ImGui_NewFrame();

    // Show the ImGui metrics window.
    // c.ImGui_ShowMetricsWindow(null);

    // Show a performance metrics window.
    _ = c.ImGui_Begin("-", null, c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoMove);
    c.ImGui_SetWindowPos(.{ .x = 5.0, .y = 5.0 }, c.ImGuiCond_None);
    c.ImGui_SeparatorText("Performance");
    c.ImGui_Text("FPS: %-6.2f", 1e3 / frame_time_ms);
    c.ImGui_Text("Frame Time (ms): %-6.3f", frame_time_ms);
    c.ImGui_SeparatorText("Camera");
    c.ImGui_Text("Position: (%.2f, %.2f, %.2f)", camera.o0.translation[0], camera.o0.translation[1], camera.o0.translation[2]);
    c.ImGui_Text(
        "Rotation (deg): (%.2f, %.2f, %.2f)",
        @mod(std.math.radiansToDegrees(camera.o0.rotation[0]), 360),
        @mod(std.math.radiansToDegrees(camera.o0.rotation[1]), 360),
        @mod(std.math.radiansToDegrees(camera.o0.rotation[2]), 360),
    );
    c.ImGui_Text("Velocity: (%.2f, %.2f, %.2f)", camera.o1.translation[0], camera.o1.translation[1], camera.o1.translation[2]);
    c.ImGui_Text("FoV (deg): %.2f", fov);
    c.ImGui_SeparatorText("Mouse");
    c.ImGui_Text("Right Pressed: %d", right_mouse_pressed);
    c.ImGui_End();

    // Render ImGui, prepare the draw data and submit the draw calls.
    c.ImGui_Render();
    const draw_data: *c.ImDrawData = c.ImGui_GetDrawData();
    c.cImgui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);
    c.cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, render_pass);
}

// Main

pub fn main() void {
    const args: []const []const u8 = &.{};
    _ = c.SDL_RunApp(@intCast(args.len), @ptrCast(@constCast(&args)), &sdlMainWrapper, null);
}

fn sdlMainWrapper(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    sdlMain() catch |e| gdn.fatal("Fatal Error: {}", .{e});
    return 1;
}

pub fn sdlMain() !void {
    try init();
    while (!should_exit) try update();
    try exit();
}

// Helpers

fn inputAxis(pos: usize, neg: usize) f32 {
    return @as(f32, @floatFromInt(@intFromBool(keyboard_state[pos]))) -
        @as(f32, @floatFromInt(@intFromBool(keyboard_state[neg])));
}

// Tests

test {
    std.testing.log_level = .debug;
    std.testing.refAllDeclsRecursive(gpu);
}
