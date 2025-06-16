const std = @import("std");

const gpu = @import("gpu.zig");
const common = @import("common.zig");
const c = common.c;

const SDL_Fatal = common.SDL_Fatal;

pub const std_options: std.Options = .{ .log_level = .debug };

// Constants

const NS_PER_S = 1_000_000_000.0;

// Configuration

const TARGET_FRAMERATE: f32 = 60.0;
const TARGET_FRAMETIME_NS: u64 = @intFromFloat(NS_PER_S / 60.0);

// App

var shader_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;

var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;

var last_update_ns: u64 = 0;

var should_exit = false;

fn init() !void {
    // Initialize SDL.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) SDL_Fatal("SDL_Init(c.SDL_INIT_VIDEO)");

    // Create the window associated with the GPU device.
    window = c.SDL_CreateWindow("Garden", 720, 720, 0) orelse SDL_Fatal("SDL_CreateWindow");
    device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, false, "vulkan") orelse SDL_Fatal("SDL_CreateGPUDevice");
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) SDL_Fatal("SDL_ClaimWindowForGPUDevice");

    // Create the rendering pipeline.
    try load_pipeline();

    // Create vertex buffer.
    vertex_buffer = c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 3,
    }) orelse SDL_Fatal("SDL_CreateGPUBuffer(SDL_GPU_BUFFERUSAGE_VERTEX)");

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 3,
    }) orelse SDL_Fatal("SDL_CreateGPUTransferBuffer");

    {
        const transfer_data: *[3][6]f32 = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse common.SDL_Fatal("SDL_MapGPUTransferBuffer")));
        transfer_data[0] = [_]f32{ 0, 0.5, 0, 1, 0, 0 };
        transfer_data[1] = [_]f32{ -0.5, -0.5, 0, 0, 1, 0 };
        transfer_data[2] = [_]f32{ 0.5, -0.5, 0, 0, 0, 1 };
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const upload_cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse SDL_Fatal("SDL_AcquireGPUCommandBuffer");
    const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd_buf) orelse SDL_Fatal("SDL_BeginGPUCopyPass");

    c.SDL_UploadToGPUBuffer(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    }, &.{
        .buffer = vertex_buffer,
        .offset = 0,
        .size = (@sizeOf(f32) * 3 + @sizeOf(f32) * 3) * 3,
    }, false);

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf)) SDL_Fatal("SDL_SubmitGPUCommandBuffer");
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // Set the start time.
    last_update_ns = c.SDL_GetTicksNS();
}

fn update() !void {
    const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());

    // TODO: Get rid of conditional.
    if (ticks_ns - last_update_ns < TARGET_FRAMETIME_NS) {
        c.SDL_DelayNS(@intCast(TARGET_FRAMETIME_NS - (ticks_ns - last_update_ns)));
    }

    try pollEvents();
    try render(ticks_ns);

    last_update_ns = ticks_ns;
}

fn pollEvents() !void {
    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => if (!event.key.repeat) {
            switch (event.key.scancode) {
                c.SDL_SCANCODE_ESCAPE => should_exit = true,
                c.SDL_SCANCODE_R => try load_pipeline(),
                else => {},
            }
        },
        c.SDL_EVENT_QUIT => should_exit = true,
        else => {},
    };
}

fn render(ticks: u64) !void {
    _ = ticks;

    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse SDL_Fatal("SDL_AcquireGPUCommandBuffer");

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, window, &swapchain_texture, null, null)) {
        SDL_Fatal("SDL_WaitAndAcquireGPUSwapchainTexture");
    }

    if (swapchain_texture) |tex| {
        const color_target_info = c.SDL_GPUColorTargetInfo{
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .texture = tex,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        };

        const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &[_]c.SDL_GPUColorTargetInfo{color_target_info}, 1, null) orelse SDL_Fatal("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(render_pass);

        c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline.?);
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &[_]c.SDL_GPUBufferBinding{.{ .buffer = vertex_buffer, .offset = 0 }}, 1);
        c.SDL_DrawGPUPrimitives(render_pass, 3, 1, 0, 0);
    }

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buf)) common.SDL_Err("SDL_SubmitGPUCommandBuffer");
}

fn exit() !void {
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    shader_arena.deinit();
}

fn load_pipeline() !void {
    if (pipeline != null) c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const compiled_vertex_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/shaders/shader.slang", .Vertex, true)).?;
    const compiled_fragment_shader = (try gpu.compile.CompiledShader.compileBlocking(shader_arena.allocator(), "src/shaders/shader.slang", .Fragment, true)).?;

    const vertex_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_vertex_shader.layout).?;
    const fragment_layout = gpu.slang.ShaderLayout.parseLeaky(shader_arena.allocator(), compiled_fragment_shader.layout).?;

    pipeline = gpu.slang.ShaderLayout.createPipeline(device, window, &vertex_layout, &fragment_layout, compiled_vertex_shader.spv, compiled_fragment_shader.spv).?;

    common.log.info("Compiled and reloaded shaders!", .{});
}

// Main

pub fn main() void {
    const args: []const []const u8 = &.{};
    _ = c.SDL_RunApp(@intCast(args.len), @ptrCast(@constCast(&args)), &sdlMainWrapper, null);
}

fn sdlMainWrapper(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    sdlMain() catch |e| common.fatal(common.log, "{}", .{e});
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
