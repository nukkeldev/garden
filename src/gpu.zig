const std = @import("std");
const c = @import("ffi.zig").c;

pub const slang = @import("gpu/slang.zig");
pub const compile = @import("gpu/compile.zig");

const sdl = @import("log.zig").sdl;

pub fn initBuffer(comptime T: type, len: u32, data: []const T, device: *c.SDL_GPUDevice, buffer_usage: c.SDL_GPUBufferUsageFlags) *c.SDL_GPUBuffer {
    const data_size = @sizeOf(T) * len;

    const buffer = c.SDL_CreateGPUBuffer(device, &.{
        .usage = buffer_usage,
        .size = data_size,
    }) orelse sdl.fatal("SDL_CreateGPUBuffer");

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
    }) orelse sdl.fatal("SDL_CreateGPUTransferBuffer");

    {
        const transfer_data: [*]T = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse sdl.fatal("SDL_MapGPUTransferBuffer")));
        @memcpy(transfer_data, data);
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse sdl.fatal("SDL_AcquireGPUCommandBuffer");
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse sdl.fatal("SDL_BeginGPUCopyPass");

    c.SDL_UploadToGPUBuffer(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
    }, &.{
        .buffer = buffer,
        .offset = 0,
        .size = data_size,
    }, false);

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) sdl.fatal("SDL_SubmitGPUCommandBuffer");
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    return buffer;
}
