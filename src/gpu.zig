const c = @import("ffi.zig").c;

pub const slang = @import("gpu/slang.zig");
pub const compile = @import("gpu/compile.zig");

const sdl = @import("log.zig").sdl;

pub fn initBuffer(comptime T: type, len: comptime_int, data: [len]T, device: *c.SDL_GPUDevice) *c.SDL_GPUBuffer {
    const data_size = @sizeOf(T) * len;

    const buffer = c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = data_size,
    }) orelse sdl.fatal("SDL_CreateGPUBuffer(SDL_GPU_BUFFERUSAGE_VERTEX)");

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
    }) orelse sdl.fatal("SDL_CreateGPUTransferBuffer");

    {
        const transfer_data: *[len]T = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse sdl.fatal("SDL_MapGPUTransferBuffer")));
        transfer_data.* = data;
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const upload_cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse sdl.fatal("SDL_AcquireGPUCommandBuffer");
    const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd_buf) orelse sdl.fatal("SDL_BeginGPUCopyPass");

    c.SDL_UploadToGPUBuffer(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    }, &.{
        .buffer = buffer,
        .offset = 0,
        .size = data_size,
    }, false);

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    return buffer;
}
