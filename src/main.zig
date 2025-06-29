const std = @import("std");

const zm = @import("zm");

const trace = @import("trace.zig");
const gpu = @import("gpu.zig");
const ffi = @import("ffi.zig");
const log = @import("log.zig");

const DynamicTransfrom = @import("transform.zig").DynamicTransform;
const Model = @import("object.zig").Model;
const Mesh = @import("object.zig").Mesh;

const log_gdn = std.log.scoped(.garden);
const log_imgui = std.log.scoped(.imgui);

const c = ffi.c;
const SDL = ffi.SDL;
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

var debug_allocator = std.heap.DebugAllocator(.{}).init;
var arena: trace.TracingArenaAllocator = .init(debug_allocator.allocator());
var allocator = arena.allocator();

var window: SDL.Window = undefined;
var device: SDL.GPUDevice = undefined;

var im_context: *c.ImGuiContext = undefined;

var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var depth_texture: *c.SDL_GPUTexture = undefined;

var camera: DynamicTransfrom = .{
    .translation = .{ 0, 3, -5 },
    .rotation = .{ 0, std.math.degreesToRadians(90), 0 },
};
var car: Model = undefined;

var dynamic_transforms = [_]*DynamicTransfrom{ &camera, &car.transform };
var models = [_]*Model{&car};

var fov: f32 = INITIAL_FOV;
var proj_matrix: zm.Mat4f = zm.Mat4f.perspective(std.math.degreesToRadians(INITIAL_FOV), 1.0, 0.05, 100.0);

var last_update_ns: u64 = 0;
var should_exit = false;

var debug = true;
var wireframe = false;

var right_mouse_pressed: bool = false;
var mouse_delta_x: f32 = 0;
var mouse_delta_y: f32 = 0;
var keyboard_state: [*c]const bool = undefined;

// Functions

fn init() !void {
    // Initialize SDL.
    try SDL.initialize(c.SDL_INIT_VIDEO);

    // Create the window and device.
    window = try SDL.Window.create(allocator, "Garden Demo", 1024, 1024, WINDOW_FLAGS);
    try window.setPosition(c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
    try window.show();

    device = try SDL.GPUDevice.createAndClaimForWindow(allocator, c.SDL_GPU_SHADERFORMAT_SPIRV, false, null, &window);
    try device.setSwapchainParameters(&window, .{ .present_mode = .MAILBOX });
    try device.setAllowedFramesInFlight(3);

    // Create the depth texture.
    const px_size = try window.getSizeInPixels();
    depth_texture = try device.createTexture(.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .width = px_size[0],
        .height = px_size[1],
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    });

    // Create an ImGui context.
    im_context = c.ImGui_CreateContext(null) orelse {
        log_imgui.err("Failed to create ImGui context!", .{});
        return error.ImGuiError;
    };

    const io = c.ImGui_GetIO();
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls

    // Configure ImGui styling.
    const style = c.ImGui_GetStyle();
    c.ImGui_StyleColorsDark(style);

    // Setup ImGui rendering.
    if (!c.cImGui_ImplSDL3_InitForSDLGPU(window.handle)) {
        log_imgui.err("Failed to initialize SDL3's implementation for SDLGPU!", .{});
        return error.ImGuiError;
    }
    var imgui_init = c.ImGui_ImplSDLGPU3_InitInfo{
        .Device = device.handle,
        .ColorTargetFormat = try device.getSwapchainTextureFormat(&window),
        .MSAASamples = c.SDL_GPU_SAMPLECOUNT_1,
    };
    if (!c.cImGui_ImplSDLGPU3_Init(&imgui_init)) {
        log_imgui.err("Failed to initialize SDLGPU3!", .{});
        return error.ImGuiError;
    }

    // Create the rendering pipeline.
    try loadPipeline(false);

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();

    // Get a pointer to the keyboard state.
    keyboard_state = c.SDL_GetKeyboardState(null);

    // Create the initial models.
    car = try Model.initFromEmbeddedObj(
        allocator,
        &device,
        "Car",
        .{},
        @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.obj"),
        @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.mtl"),
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
    camera.rotational_velocity = @splat(0);
    mouse_delta_x = 0;
    mouse_delta_y = 0;

    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) {
        _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => if (!event.key.repeat) {
                switch (event.key.scancode) {
                    // General
                    c.SDL_SCANCODE_ESCAPE => should_exit = true,
                    // Debug
                    c.SDL_SCANCODE_R => if (event.key.mod & c.SDL_KMOD_LCTRL != 0) try loadPipeline(true),
                    c.SDL_SCANCODE_F => {
                        wireframe = true;
                        try loadPipeline(false);
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
                        try loadPipeline(false);
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (right_mouse_pressed) {
                    mouse_delta_x = event.motion.xrel;
                    mouse_delta_y = -event.motion.yrel;
                    camera.rotational_velocity[1] = mouse_delta_x * PAN_SPEED;
                    camera.rotational_velocity[0] = mouse_delta_y * PAN_SPEED;
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
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
                // TODO: While not currently an issue, we should make sure to update all textures to the proper size.
                _ = try window.syncSizeToDisplayScale();
            },
            c.SDL_EVENT_QUIT => should_exit = true,
            else => {},
        }
    }

    // Free-Cam
    camera.translational_velocity =
        zm.vec.scale(camera.right(), inputAxis(c.SDL_SCANCODE_A, c.SDL_SCANCODE_D) * MOVEMENT_SPEED) +
        zm.vec.scale(zm.vec.up(f32), inputAxis(c.SDL_SCANCODE_E, c.SDL_SCANCODE_Q) * MOVEMENT_SPEED) +
        zm.vec.scale(camera.forward(), inputAxis(c.SDL_SCANCODE_W, c.SDL_SCANCODE_S) * MOVEMENT_SPEED);
}

fn updateSystems(ticks: u64, dt: u64) !void {
    _ = ticks;

    const dt_s = @as(f32, @floatFromInt(dt)) / 1e9;
    for (dynamic_transforms) |t| t.update(dt_s);

    if (!c.SDL_SetWindowRelativeMouseMode(
        window.handle,
        right_mouse_pressed,
    )) SDL.err("SetWindowRelativeMouseMode", "", .{});
}

fn render(ticks: u64, dt: u64) !void {
    _ = ticks;
    const frame_time_ms = @as(f32, @floatFromInt(dt)) / 1e6;

    const cmd = try SDL.GPUCommandBuffer.acquire(&device);
    const swapchain_texture: ?*c.SDL_GPUTexture = try cmd.waitAndAcquireSwapchainTexture(&window);
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

    const rpass = try SDL.GPURenderPass.begin(&cmd, &.{color_target_info}, depth_stencil_target_info);

    const view_matrix = zm.Mat4f.lookAt(camera.translation, camera.translation + camera.forward(), zm.vec.up(f32));
    const pfd = gpu.PerFrameVertexData{ .view_proj = proj_matrix.multiply(view_matrix).data };

    rpass.bindGraphicsPipeline(pipeline.?);

    try gpu.Bindings.PER_FRAME_VERTEX_DATA.bind(&cmd, &pfd);

    const view_position: [4]f32 = .{ camera.translation[0], camera.translation[1], camera.translation[2], 0 };
    try gpu.Bindings.VIEW_POSITION.bind(&cmd, &view_position);

    for (models) |model| try model.draw(&cmd, &rpass);

    // ImGui Rendering
    if (debug) renderDebug(&cmd, &rpass, frame_time_ms);

    // Submit the render pass.
    rpass.end();
    try cmd.submit();
}

fn exit() !void {
    try device.waitForIdle();

    c.cImGui_ImplSDLGPU3_Shutdown();
    c.cImGui_ImplSDL3_Shutdown();
    c.ImGui_DestroyContext(null);

    c.SDL_ReleaseGPUTexture(device.handle, depth_texture);
    c.SDL_ReleaseGPUGraphicsPipeline(device.handle, pipeline);

    for (models) |model| model.deinit(&device);
    try window.destroy();

    arena.deinit();

    c.SDL_Quit();
}

fn loadPipeline(recompile: bool) !void {
    if (pipeline != null) c.SDL_ReleaseGPUGraphicsPipeline(device.handle, pipeline);

    var compiled_vertex_shader: gpu.compile.CompiledShader = undefined;
    var compiled_fragment_shader: gpu.compile.CompiledShader = undefined;

    if (recompile) {
        compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(
            allocator,
            "src/assets/shaders/vertex.slang",
            .Vertex,
            pipeline == null,
            true,
        )).?;
        compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(
            allocator,
            "src/assets/shaders/fragment.slang",
            .Fragment,
            pipeline == null,
            true,
        )).?;
    } else {
        compiled_vertex_shader = .{
            .allocator = allocator,
            .spv = std.fs.cwd().readFileAlloc(
                allocator,
                "src/assets/shaders/compiled/vertex.spv",
                std.math.maxInt(usize),
            ) catch {
                log_gdn.err("Failed to read vertex shader!", .{});
                return;
            },
            .layout = std.fs.cwd().readFileAlloc(
                allocator,
                "src/assets/shaders/compiled/vertex.layout",
                std.math.maxInt(usize),
            ) catch {
                log_gdn.err("Failed to read vertex shader layout!", .{});
                return;
            },
        };

        compiled_fragment_shader = .{
            .allocator = allocator,
            .spv = std.fs.cwd().readFileAlloc(
                allocator,
                "src/assets/shaders/compiled/fragment.spv",
                std.math.maxInt(usize),
            ) catch {
                log_gdn.err("Failed to read fragment shader!", .{});
                return;
            },
            .layout = std.fs.cwd().readFileAlloc(
                allocator,
                "src/assets/shaders/compiled/fragment.layout",
                std.math.maxInt(usize),
            ) catch {
                log_gdn.err("Failed to read fragment shader layout!", .{});
                return;
            },
        };
    }

    const vertex_layout = try gpu.slang.ShaderLayout.parseLeaky(allocator, compiled_vertex_shader.layout);
    const fragment_layout = try gpu.slang.ShaderLayout.parseLeaky(allocator, compiled_fragment_shader.layout);

    pipeline = gpu.slang.ShaderLayout.createPipelineLeaky(
        allocator,
        device.handle,
        window.handle,
        &vertex_layout,
        &fragment_layout,
        compiled_vertex_shader.spv,
        compiled_fragment_shader.spv,
        wireframe,
    ).?;

    if (recompile) log_gdn.info("Compiled and reloaded shaders!", .{});
}

fn renderDebug(cmd: *const SDL.GPUCommandBuffer, rpass: *const SDL.GPURenderPass, frame_time_ms: f32) void {
    // Begin a new ImGui frame.
    c.cImGui_ImplSDLGPU3_NewFrame();
    c.cImGui_ImplSDL3_NewFrame();
    c.ImGui_NewFrame();

    // Show the ImGui metrics window.
    // c.ImGui_ShowMetricsWindow(null);

    // Show a performance metrics window.
    _ = c.ImGui_Begin(
        "-",
        null,
        c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoDecoration |
            c.ImGuiWindowFlags_AlwaysAutoResize |
            c.ImGuiWindowFlags_NoMove,
    );
    c.ImGui_SetWindowPos(.{ .x = 5.0, .y = 5.0 }, c.ImGuiCond_None);
    c.ImGui_SeparatorText("Performance");
    c.ImGui_Text("FPS: %-6.2f", 1e3 / frame_time_ms);
    c.ImGui_Text("Frame Time (ms): %-6.3f", frame_time_ms);
    c.ImGui_SeparatorText("Camera");
    c.ImGui_Text("Position: (%.2f, %.2f, %.2f)", camera.translation[0], camera.translation[1], camera.translation[2]);
    c.ImGui_Text(
        "Rotation (deg): (%.2f, %.2f, %.2f)",
        @mod(std.math.radiansToDegrees(camera.rotation[0]), 360),
        @mod(std.math.radiansToDegrees(camera.rotation[1]), 360),
        @mod(std.math.radiansToDegrees(camera.rotation[2]), 360),
    );
    c.ImGui_Text("Velocity: (%.2f, %.2f, %.2f)", camera.translation[0], camera.translation[1], camera.translation[2]);
    c.ImGui_Text("FoV (deg): %.2f", fov);
    c.ImGui_SeparatorText("Mouse");
    c.ImGui_Text("Right Pressed: %d", right_mouse_pressed);
    c.ImGui_Text("Delta: (%.2f, %.2f)", mouse_delta_x, mouse_delta_y);
    c.ImGui_End();

    // Render ImGui, prepare the draw data and submit the draw calls.
    c.ImGui_Render();
    const draw_data: *c.ImDrawData = c.ImGui_GetDrawData();
    c.cImgui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd.handle);
    c.cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd.handle, rpass.handle);
}

// Main

var err: ?anyerror = null;

pub fn main() !void {
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
    std.testing.refAllDeclsRecursive(@import("gpu.zig"));
    std.testing.refAllDeclsRecursive(@import("object.zig"));
}
