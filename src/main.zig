const std = @import("std");

const zm = @import("zm");

const trace = @import("trace.zig");
const gpu = @import("gpu.zig");
const ffi = @import("ffi.zig");
const log = @import("log.zig");
const object = @import("object.zig");
const c = ffi.c;

const DynamicTransfrom = @import("transform.zig").DynamicTransform;
const Model = object.Model;
const FZ = trace.FnZone;
const SDL = ffi.SDL;

const log_gdn = std.log.scoped(.garden);
const log_imgui = std.log.scoped(.imgui);

pub const std_options: std.Options = .{ .log_level = .debug };

// Configuration

const INITIAL_WINDOW_SIZE = .{ .width = 1024, .height = 1024 };
const WINDOW_FLAGS = c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_VULKAN;

const TARGET_FRAMERATE: f32 = 60.0; // FPS
const TARGET_FRAMETIME_NS: u64 = @intFromFloat(1e9 / TARGET_FRAMERATE);

const TARGET_UPDATE_RATE: f32 = 1_000.0; // UPS
const TARGET_UPDATE_TIME_NS: u64 = @intFromFloat(1e9 / TARGET_UPDATE_RATE);

const FRAMES_IN_FLIGHT = 3;

var MOVEMENT_SPEED: f32 = 4.0;
const ZOOM_SPEED: f32 = 2;

const MIN_FOV = 30.0;
const INITIAL_FOV = 90.0;
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
var depth_texture: SDL.GPUTexture = undefined;

var camera: DynamicTransfrom = .{
    .translation = .{ -6.75, 4, -5.25 },
    .rotation = .{ std.math.degreesToRadians(-45), std.math.degreesToRadians(45), 0 },
};
var car: Model = undefined;
var light: Model = undefined;

var dynamic_transforms = [_]*DynamicTransfrom{ &camera, &car.transform, &light.transform };
var models = [_]*Model{ &car, &light };

var fov: f32 = INITIAL_FOV;
var proj_matrix: zm.Mat4f = zm.Mat4f.perspective(std.math.degreesToRadians(INITIAL_FOV), 1.0, 0.05, 100.0);

var last_update_ns: u64 = 0;
var last_render_ns: u64 = 0;
var next_render_ns: u64 = 0;
var next_update_ns: u64 = 0;
var should_exit = false;

var debug = true;
var wireframe = false;

var right_mouse_pressed: bool = false;
var mouse_delta_x: f32 = 0;
var mouse_delta_y: f32 = 0;
var keyboard_state: [*c]const bool = undefined;

// Functions

fn init() !void {
    var fz = FZ.init(@src(), "init");
    defer fz.end();

    // Initialize SDL.
    fz.push(@src(), "sdl init");
    try SDL.initialize(c.SDL_INIT_VIDEO);

    // Create the window and device.
    fz.replace(@src(), "create window");
    window = try SDL.Window.create(allocator, "Garden Demo", 1024, 1024, WINDOW_FLAGS);
    try window.setPosition(c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
    try window.show();

    fz.replace(@src(), "create gpu device");
    device = try SDL.GPUDevice.createAndClaimForWindow(allocator, c.SDL_GPU_SHADERFORMAT_SPIRV, false, null, &window);
    try device.setSwapchainParameters(&window, .{ .present_mode = .MAILBOX });
    try device.setAllowedFramesInFlight(3);

    // Create the depth texture.
    fz.replace(@src(), "create depth texture");
    const size_px = try window.getSizeInPixels();
    depth_texture = try SDL.GPUTexture.create(allocator, &device, "Depth Texture", .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .width = size_px[0],
        .height = size_px[1],
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    });

    // Create an ImGui context.
    fz.replace(@src(), "imgui init");
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
    fz.replace(@src(), "load pipeline");
    try loadPipeline(false);

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();
    last_render_ns = c.SDL_GetTicksNS();
    next_update_ns = c.SDL_GetTicksNS();
    next_render_ns = c.SDL_GetTicksNS();

    // Get a pointer to the keyboard state.
    keyboard_state = c.SDL_GetKeyboardState(null);

    // Create the initial models.
    fz.replace(@src(), "load models");
    car = try Model.initFromObjFile(
        allocator,
        &device,
        "Car",
        .{},
        "src/assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.obj",
        "src/assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.mtl",
        try object.embedTextureMap(
            allocator,
            "src/assets/models/2021-Lamborghini-Countac [Lexyc16]/textures",
            &.{
                "Lamborghini-text-logo-1440x900_baseColor.png",
                "Material.001_baseColor.png",
                "Material.002_baseColor.png",
                "Material.002_metallicRoughness.png",
                "Material.002_normal.png",
                "Material.010_normal.png",
                "Material.012_normal.png",
                "Material.013_baseColor.png",
                "Material.025_baseColor.jpeg",
                "Material.029_baseColor.png",
            },
        ),
        // @embedFile("assets/models/cube/Cube.obj"),
        // @embedFile("assets/models/cube/Cube.mtl"),
    );

    light = try Model.initFromObjFile(
        allocator,
        &device,
        "Light",
        .{
            .translation = .{ 0.0, 5.0, 0.0 },
            .scale = @splat(0.1),
        },
        "src/assets/models/Cube/cube.obj",
        "src/assets/models/Cube/cube.mtl",
        .init(allocator),
    );
    light.meshes[0].material.gpu.basic = 1;
}

fn update() !void {
    const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());

    if (ticks_ns >= next_update_ns) {
        try pollEvents();
        try updateSystems(ticks_ns, ticks_ns - last_update_ns);
        last_update_ns = ticks_ns;
        next_update_ns = ticks_ns + TARGET_UPDATE_TIME_NS;
    }
    if (ticks_ns >= next_render_ns) {
        try render(ticks_ns);
        last_render_ns = ticks_ns;
        next_render_ns = ticks_ns + TARGET_FRAMETIME_NS;
    }
}

fn pollEvents() !void {
    var fz = FZ.init(@src(), "pollEvents");
    defer fz.end();

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
    var fz = FZ.init(@src(), "updateSystems");
    defer fz.end();

    // Rotating Lights
    light.transform.translational_velocity = .{
        @sin(@as(f32, @floatFromInt(ticks)) / 1e9),
        @cos(@as(f32, @floatFromInt(ticks)) / 1e9),
        0.0,
    };

    const dt_s = @as(f32, @floatFromInt(dt)) / 1e9;
    for (dynamic_transforms) |t| t.update(dt_s);

    if (!c.SDL_SetWindowRelativeMouseMode(
        window.handle,
        right_mouse_pressed,
    )) SDL.err("SetWindowRelativeMouseMode", "", .{});
}

fn render(ticks_ns: u64) !void {
    trace.ztracy.FrameMark();
    var fz = FZ.init(@src(), "render");
    defer fz.end();

    fz.push(@src(), "acquire");
    const cmd = try SDL.GPUCommandBuffer.acquire(&device);
    const swapchain_texture: ?*c.SDL_GPUTexture = try cmd.waitAndAcquireSwapchainTexture(&window);
    if (swapchain_texture == null) return;

    const tex = swapchain_texture.?;

    // SDL Rendering

    fz.replace(@src(), "begin render pass");
    const color_target_info = c.SDL_GPUColorTargetInfo{
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .texture = tex,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const depth_stencil_target_info = c.SDL_GPUDepthStencilTargetInfo{
        .texture = depth_texture.handle,
        .cycle = true,
        .clear_depth = 1,
        .clear_stencil = 0,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .stencil_load_op = c.SDL_GPU_LOADOP_CLEAR,
        .stencil_store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const rpass = try SDL.GPURenderPass.begin(&cmd, &.{color_target_info}, depth_stencil_target_info);

    fz.replace(@src(), "calc view mat");
    const view_matrix = zm.Mat4f.lookAt(camera.translation, camera.translation + camera.forward(), zm.vec.up(f32));
    const pfvd = gpu.PerFrameVertexData{ .view_proj = proj_matrix.multiply(view_matrix).data };

    fz.replace(@src(), "bind");
    try gpu.Bindings.PER_FRAME_VERTEX_DATA.bind(&cmd, &pfvd);

    var lights: [16]gpu.Light = undefined;
    lights[0] = .{
        .position = light.transform.translation,
        .color = .{ 1.0, 0.0, 0.0 },
    };
    lights[1] = .{
        .position = light.transform.translation * @as([3]f32, @splat(-1)),
        .color = .{ 0.0, 1.0, 0.0 },
    };

    const pffd = gpu.PerFrameFragmentData{
        .lights = lights,
        .lightCount = 2,
        .view_pos = camera.translation,
    };
    try gpu.Bindings.PER_FRAME_FRAGMENT_DATA.bind(&cmd, &pffd);

    fz.replace(@src(), "draw");
    rpass.bindGraphicsPipeline(pipeline.?);
    for (models) |model| try model.draw(&cmd, &rpass);

    // ImGui Rendering
    if (debug) renderDebug(&cmd, &rpass, ticks_ns);

    // Submit the render pass.
    fz.replace(@src(), "submit");
    rpass.end();
    try cmd.submit();
}

fn exit() !void {
    var fz = FZ.init(@src(), "exit");
    defer fz.end();

    try device.waitForIdle();

    c.cImGui_ImplSDLGPU3_Shutdown();
    c.cImGui_ImplSDL3_Shutdown();
    c.ImGui_DestroyContext(null);

    depth_texture.release(&device);
    c.SDL_ReleaseGPUGraphicsPipeline(device.handle, pipeline);

    for (models) |model| model.deinit(&device);
    try window.destroy();

    arena.deinit();

    c.SDL_Quit();
}

// TODO: CASHHHHHH
fn loadPipeline(recompile: bool) !void {
    var fz = FZ.init(@src(), "loadPipeline");
    defer fz.end();

    if (pipeline != null) {
        c.SDL_ReleaseGPUGraphicsPipeline(device.handle, pipeline);
    }

    const compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(
        allocator,
        "src/assets/shaders/phong.slang",
        .Vertex,
        true,
    )).?;
    const compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(
        allocator,
        "src/assets/shaders/phong.slang",
        .Fragment,
        true,
    )).?;

    const vertex_layout = try gpu.slang.ShaderLayout.parseLeaky(allocator, compiled_vertex_shader.layout, "vertexMain");
    const fragment_layout = try gpu.slang.ShaderLayout.parseLeaky(allocator, compiled_fragment_shader.layout, "fragmentMain");

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

fn renderDebug(cmd: *const SDL.GPUCommandBuffer, rpass: *const SDL.GPURenderPass, ticks_ns: u64) void {
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

    const frame_time_ms = @as(f32, @floatFromInt(ticks_ns - last_render_ns)) / 1e6;
    const update_time_ms = @as(f32, @floatFromInt(ticks_ns - last_update_ns)) / 1e6;

    c.ImGui_Text("FPS: %-6.2f", 1e3 / frame_time_ms);
    c.ImGui_Text("Frame Time (ms): %-6.3f", frame_time_ms);
    c.ImGui_Text("UPS: %-6.2f", 1e3 / update_time_ms);
    c.ImGui_Text("Update Time (ms): %-6.3f", update_time_ms);
    c.ImGui_SeparatorText("Camera");
    c.ImGui_Text("Position: (%.2f, %.2f, %.2f)", camera.translation[0], camera.translation[1], camera.translation[2]);
    c.ImGui_Text(
        "Rotation (deg): (%.2f, %.2f, %.2f)",
        @mod(std.math.radiansToDegrees(camera.rotation[0]), 360),
        @mod(std.math.radiansToDegrees(camera.rotation[1]), 360),
        @mod(std.math.radiansToDegrees(camera.rotation[2]), 360),
    );
    c.ImGui_Text(
        "Velocity: (%.2f, %.2f, %.2f)",
        camera.translational_velocity[0],
        camera.translational_velocity[1],
        camera.translational_velocity[2],
    );
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
