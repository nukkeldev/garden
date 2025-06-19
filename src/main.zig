const std = @import("std");

const gpu = @import("gpu.zig");
const ffi = @import("ffi.zig");
const log = @import("log.zig");
const ecs = @import("ecs");
const components = @import("components.zig");
const object = @import("object.zig");
const zm = @import("zm");

const gdn = log.gdn;
const sdl = log.sdl;
const gui = log.gui;

const c = ffi.c;
const cstr = ffi.cstr;

pub const std_options: std.Options = .{ .log_level = .debug };

// Configuration

const INITIAL_WINDOW_SIZE = .{ .width = 1024, .height = 1024 };
const WINDOW_FLAGS = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_VULKAN;

const TARGET_FRAMERATE: f32 = 60.0;
const TARGET_FRAMETIME_NS: u64 = @intFromFloat(1e9 / 60.0);

const FRAMES_IN_FLIGHT = 3;

const MOVEMENT_SPEED: f32 = 1.0;
const ROTATION_SPEED: f32 = 4.0;

// State

var shader_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var ecs_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var im_context: *c.ImGuiContext = undefined;

var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var player: object.Object([6]f32, .U16) = undefined;

var reg: ecs.Registry = undefined;

var e_player: ecs.Entity = undefined;
var e_camera: ecs.Entity = undefined;

var t_player: *components.Transform1 = undefined;
var v_player: *components.Transform2 = undefined;
var t_camera: *components.Transform1 = undefined;

var transformables: ecs.OwningGroup = undefined;

var proj_matrix: zm.Mat4f = zm.Mat4f.perspective(std.math.degreesToRadians(60.0), 1.0, 0.05, 100.0);

var last_update_ns: u64 = 0;
var should_exit = false;
var show_imgui_demo_window = true;

var keyboard_state: [*c]const bool = undefined;

// Functions

fn init() !void {
    c.SDL_SetMainReady();

    // Initialize SDL.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) sdl.fatal("SDL_Init(c.SDL_INIT_VIDEO)");

    // Create the window.
    const display_scale = c.SDL_GetDisplayContentScale(c.SDL_GetPrimaryDisplay());
    window = c.SDL_CreateWindow(
        "Garden",
        @intFromFloat(display_scale * @as(f32, @floatFromInt(INITIAL_WINDOW_SIZE.width))),
        @intFromFloat(display_scale * @as(f32, @floatFromInt(INITIAL_WINDOW_SIZE.height))),
        WINDOW_FLAGS,
    ) orelse sdl.fatal("SDL_CreateWindow");
    if (!c.SDL_SetWindowPosition(window, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED)) sdl.err("SDL_SetWindowPosition");
    if (!c.SDL_ShowWindow(window)) sdl.err("SDL_ShowWindow");

    // Create the GPU device and claim the window for it.
    // TODO: If `debug_mode` is enabled, `c.cImGui_ImplSDLGPU3_RenderDrawData` below crashes
    // with an a load of some random value not being "valid for type 'bool'". I am not sure
    // how to fix this currently but it appears to be some sort of use-after-free?
    device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, false, null) orelse sdl.fatal("SDL_CreateGPUDevice");
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) sdl.fatal("SDL_ClaimWindowForGPUDevice");
    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_MAILBOX)) sdl.fatal("SDL_SetGPUSwapchainParameters");
    if (!c.SDL_SetGPUAllowedFramesInFlight(device, FRAMES_IN_FLIGHT)) sdl.fatal("SDL_SetGPUAllowedFramesInFlight");

    // Create an ImGui context.
    im_context = c.ImGui_CreateContext(null) orelse gui.fatal("igCreateContext");

    const io = c.ImGui_GetIO();
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls

    // Configure ImGui styling.
    const style = c.ImGui_GetStyle();
    c.ImGui_StyleColorsDark(style);
    c.ImGuiStyle_ScaleAllSizes(style, display_scale);

    // Setup ImGui rendering.
    if (!c.cImGui_ImplSDL3_InitForSDLGPU(window)) gui.fatal("cImGui_ImplSDL3_InitForSDLGPU");
    var imgui_init = c.ImGui_ImplSDLGPU3_InitInfo{
        .Device = device,
        .ColorTargetFormat = c.SDL_GetGPUSwapchainTextureFormat(device, window),
        .MSAASamples = c.SDL_GPU_SAMPLECOUNT_1,
    };
    if (!c.cImGui_ImplSDLGPU3_Init(&imgui_init)) gui.fatal("cImGui_ImplSDLGPU3_Init");

    // Create the rendering pipeline.
    try load_pipeline();

    // Create player object.
    player = .initIndexed(
        device,
        &.{
            .{ -1, -1, -1, 0.247, 0.475, 0.757 }, // #3F79C1,
            .{ 1, -1, -1, 0.851, 0.306, 0.451 }, // #D94E73
            .{ 1, 1, -1, 0.482, 0.784, 0.290 }, // #7BC84A
            .{ -1, 1, -1, 0.965, 0.773, 0.165 }, // #F6C52A
            .{ -1, -1, 1, 0.541, 0.306, 0.812 }, // #8A4ECF
            .{ 1, -1, 1, 0.180, 0.776, 0.721 }, // #2EC6B8
            .{ 1, 1, 1, 0.929, 0.416, 0.184 }, // #ED6A2F
            .{ -1, 1, 1, 0.282, 0.635, 0.878 }, // #489ADF
        },
        &.{
            0, 2, 1, 2, 0, 3, // front
            1, 6, 5, 6, 1, 2, // right
            5, 7, 4, 7, 5, 6, // back
            4, 3, 0, 3, 4, 7, // left
            3, 6, 2, 6, 3, 7, // top
            4, 1, 5, 1, 4, 0, // bottom
        },
    );

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();

    // Get a pointer to the keyboard state.
    keyboard_state = c.SDL_GetKeyboardState(null);

    // Setup initial entities with the ECS.
    reg = .init(ecs_arena.allocator());

    e_camera = reg.create();
    reg.add(e_camera, components.Transform1{ .x = .{ 0, 3, 3 } });
    reg.addTypes(e_camera, .{ components.Transform2, components.Transform3 });
    t_camera = reg.get(components.Transform1, e_camera);

    e_player = reg.create();
    reg.addTypes(e_player, .{ components.Transform1, components.Transform2, components.Transform3 });
    t_player = reg.get(components.Transform1, e_player);
    v_player = reg.get(components.Transform2, e_player);

    transformables = reg.group(.{ components.Transform1, components.Transform2, components.Transform3 }, .{}, .{});
}

fn update() !void {
    const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());
    const dt = ticks_ns - last_update_ns;

    // TODO: Get rid of conditional.
    // if (dt < TARGET_FRAMETIME_NS) {
    //     c.SDL_DelayNS(@intCast(TARGET_FRAMETIME_NS - (ticks_ns - last_update_ns)));
    // }

    try pollEvents();
    try updateSystems(dt);
    try render(ticks_ns, dt);

    last_update_ns = ticks_ns;
}

fn pollEvents() !void {
    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) {
        _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                switch (event.key.scancode) {
                    // General
                    c.SDL_SCANCODE_ESCAPE => should_exit = true,
                    // Debug
                    c.SDL_SCANCODE_R => if (!event.key.repeat and event.key.mod & c.SDL_KMOD_LCTRL != 0) try load_pipeline(),
                    else => {},
                }
            },
            c.SDL_EVENT_QUIT => should_exit = true,
            else => {},
        }
    }

    v_player.v[0] = (@as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_D]))) - @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_A])))) * MOVEMENT_SPEED;
    v_player.v[2] = (@as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_S]))) - @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_W])))) * MOVEMENT_SPEED;
    v_player.vr[1] = (@as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_Q]))) - @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_E])))) * ROTATION_SPEED;
}

fn updateSystems(dt: u64) !void {
    const dt_s = @as(f32, @floatFromInt(dt)) / 1e9;
    const dt_s3: zm.Vec3f = .{ dt_s, dt_s, dt_s };

    var iter_23 = transformables.iterator(struct { vel: *components.Transform2, acc: *components.Transform3 });
    while (iter_23.next()) |entity| {
        entity.vel.*.v += entity.acc.*.a * dt_s3;
        entity.vel.*.vr += entity.acc.*.ar * dt_s3;
    }
    var iter_12 = transformables.iterator(struct { pos: *components.Transform1, vel: *components.Transform2 });
    while (iter_12.next()) |entity| {
        entity.pos.*.x += entity.vel.*.v * dt_s3;
        entity.pos.*.r += entity.vel.*.vr * dt_s3;
    }
}

fn render(ticks: u64, dt: u64) !void {
    _ = ticks;
    const frame_time = @as(f32, @floatFromInt(dt)) / 1e6;

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse sdl.fatal("SDL_AcquireGPUCommandBuffer");

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain_texture, null, null)) {
        sdl.fatal("SDL_WaitAndAcquireGPUSwapchainTexture");
    }
    if (swapchain_texture == null) return;

    const tex = swapchain_texture.?;

    // ImGui Rendering

    c.cImGui_ImplSDLGPU3_NewFrame();
    c.cImGui_ImplSDL3_NewFrame();
    c.ImGui_NewFrame();

    _ = c.ImGui_Begin("-", null, 0);
    c.ImGui_Text("FPS: %.2f | Frame Time: %.2f ms\nPlayer Position: (%.2f, %.2f, %.2f)", 1000.0 / frame_time, frame_time, t_player.x[0], t_player.x[1], t_player.x[2]);
    c.ImGui_End();

    c.ImGui_Render();
    const draw_data: *c.ImDrawData = c.ImGui_GetDrawData();
    c.cImgui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);

    // SDL Rendering

    const color_target_info = c.SDL_GPUColorTargetInfo{
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .texture = tex,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target_info, 1, null) orelse sdl.fatal("SDL_BeginGPURenderPass");

    const model_matrix = zm.Mat4f.translationVec3(t_player.x).multiply(.rotation(.{ 0, 1, 0 }, t_player.r[1])).multiply(.scaling(0.5, 0.5, 0.5));
    const view_matrix = zm.Mat4f.lookAt(t_camera.x, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const model_view_proj = proj_matrix.multiply(view_matrix).multiply(model_matrix).transpose();

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline.?);

    c.SDL_PushGPUVertexUniformData(cmd, 0, @ptrCast(&model_view_proj), @sizeOf(zm.Mat4f));
    player.draw(render_pass);

    // Submit the render pass.
    c.cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, render_pass);
    c.SDL_EndGPURenderPass(render_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
}

fn exit() !void {
    _ = c.SDL_WaitForGPUIdle(device);

    c.cImGui_ImplSDLGPU3_Shutdown();
    c.cImGui_ImplSDL3_Shutdown();
    c.ImGui_DestroyContext(null);

    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    player.deinit();

    c.SDL_ReleaseWindowFromGPUDevice(device, window);
    c.SDL_DestroyGPUDevice(device);
    c.SDL_DestroyWindow(window);

    c.SDL_Quit();

    shader_arena.deinit();
    ecs_arena.deinit();
}

fn load_pipeline() !void {
    if (pipeline != null) c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/assets/shaders/shader.slang", .Vertex, pipeline == null, true)).?;
    const compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/assets/shaders/shader.slang", .Fragment, pipeline == null, true)).?;

    const vertex_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_vertex_shader.layout).?;
    const fragment_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_fragment_shader.layout).?;

    pipeline = gpu.slang.ShaderLayout.createPipeline(device, window, &vertex_layout, &fragment_layout, compiled_vertex_shader.spv, compiled_fragment_shader.spv).?;

    gdn.info("Compiled and reloaded shaders!", .{});
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

// Tests

test {
    std.testing.log_level = .debug;
    std.testing.refAllDeclsRecursive(gpu);
}
