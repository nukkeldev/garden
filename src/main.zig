const std = @import("std");

const gpu = @import("gpu.zig");
const ffi = @import("ffi.zig");
const log = @import("log.zig");
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

// App

var shader_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var im_context: *c.ImGuiContext = undefined;

var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;

var triangle_pos: zm.Vec3f = .{ 0, 0, 0 };
var triangle_vel: zm.Vec3f = .{ 0, 0, 0 };
var proj_matrix: zm.Mat4f = zm.Mat4f.perspective(std.math.degreesToRadians(60.0), 1.0, 0.05, 100.0);

var last_update_ns: u64 = 0;
var should_exit = false;
var show_imgui_demo_window = true;

var keyboard_state: [*c]const bool = undefined;

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

    // Create vertex buffer.
    vertex_buffer = c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 6,
    }) orelse sdl.fatal("SDL_CreateGPUBuffer(SDL_GPU_BUFFERUSAGE_VERTEX)");

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 6,
    }) orelse sdl.fatal("SDL_CreateGPUTransferBuffer");

    {
        const transfer_data: *[6][6]f32 = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse sdl.fatal("SDL_MapGPUTransferBuffer")));
        transfer_data[0] = [_]f32{ 0.5, 0.5, 0, 1, 0, 0 };
        transfer_data[1] = [_]f32{ -0.5, 0.5, 0, 0, 1, 0 };
        transfer_data[2] = [_]f32{ -0.5, -0.5, 0, 0, 0, 1 };
        transfer_data[3] = [_]f32{ 0.5, 0.5, 0, 1, 0, 0 };
        transfer_data[4] = [_]f32{ -0.5, -0.5, 0, 0, 0, 1 };
        transfer_data[5] = [_]f32{ 0.5, -0.5, 0, 0, 1, 0 };
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const upload_cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse sdl.fatal("SDL_AcquireGPUCommandBuffer");
    const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd_buf) orelse sdl.fatal("SDL_BeginGPUCopyPass");

    c.SDL_UploadToGPUBuffer(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    }, &.{
        .buffer = vertex_buffer,
        .offset = 0,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 6,
    }, false);

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();

    keyboard_state = c.SDL_GetKeyboardState(null);
}

fn update() !void {
    const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());
    const dt = ticks_ns - last_update_ns;

    // TODO: Get rid of conditional.
    // if (dt < TARGET_FRAMETIME_NS) {
    //     c.SDL_DelayNS(@intCast(TARGET_FRAMETIME_NS - (ticks_ns - last_update_ns)));
    // }

    try pollEvents(dt);
    try render(ticks_ns, dt);

    last_update_ns = ticks_ns;
}

fn pollEvents(dt: u64) !void {
    const dt_s = @as(f32, @floatFromInt(dt)) / 1e9;

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

    triangle_vel[0] = @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_W]))) - @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_S]))) * MOVEMENT_SPEED;
    triangle_vel[2] = @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_D]))) - @as(f32, @floatFromInt(@intFromBool(keyboard_state[c.SDL_SCANCODE_A]))) * MOVEMENT_SPEED;

    triangle_pos = triangle_pos + triangle_vel * zm.Vec3f{ dt_s, dt_s, dt_s };
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
    c.ImGui_Text("FPS: %.2f | Frame Time: %.2f ms\nPosition: (%.2f, %.2f, %.2f)", 1000.0 / frame_time, frame_time, triangle_pos[0], triangle_pos[1], triangle_pos[2]);
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

    const rpass = c.SDL_BeginGPURenderPass(cmd, &color_target_info, 1, null) orelse sdl.fatal("SDL_BeginGPURenderPass");

    const model_matrix = zm.Mat4f.translationVec3(triangle_pos).scale(0.5);
    const view_matrix = zm.Mat4f.lookAt(.{ 0, 3, 3 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const model_view_proj = proj_matrix.multiply(view_matrix).multiply(model_matrix).transpose();

    c.SDL_BindGPUGraphicsPipeline(rpass, pipeline.?);

    c.SDL_PushGPUVertexUniformData(cmd, 0, @ptrCast(&model_view_proj), @sizeOf(zm.Mat4f));
    c.SDL_BindGPUVertexBuffers(rpass, 0, &[_]c.SDL_GPUBufferBinding{.{ .buffer = vertex_buffer, .offset = 0 }}, 1);
    c.SDL_DrawGPUPrimitives(rpass, 6, 1, 0, 0);

    // Submit the render pass.
    c.cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, rpass);
    c.SDL_EndGPURenderPass(rpass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
}

fn exit() !void {
    _ = c.SDL_WaitForGPUIdle(device);

    c.cImGui_ImplSDLGPU3_Shutdown();
    c.cImGui_ImplSDL3_Shutdown();
    c.ImGui_DestroyContext(null);

    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    c.SDL_ReleaseWindowFromGPUDevice(device, window);
    c.SDL_DestroyGPUDevice(device);
    c.SDL_DestroyWindow(window);

    c.SDL_Quit();

    shader_arena.deinit();
}

fn load_pipeline() !void {
    if (pipeline != null) c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/shaders/shader.slang", .Vertex, pipeline == null, true)).?;
    const compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/shaders/shader.slang", .Fragment, pipeline == null, true)).?;

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
