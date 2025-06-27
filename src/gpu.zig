const std = @import("std");
const c = @import("ffi.zig").c;
const SDL = @import("ffi.zig").SDL;
const zm = @import("zm");

pub const slang = @import("gpu/slang.zig");
pub const compile = @import("gpu/compile.zig");

const sdl = @import("log.zig").sdl;

// Vertex Input

pub const VertexInput = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,
};

pub const PerFrameData = extern struct {
    model: [16]f32,
    view: [16]f32,
    proj: [16]f32,
};

// Helper Functions

pub fn initBuffer(comptime T: type, len: u32, data: []const T, device: *c.SDL_GPUDevice, buffer_usage: c.SDL_GPUBufferUsageFlags) !*c.SDL_GPUBuffer {
    const data_size = @sizeOf(T) * len;

    const buffer = c.SDL_CreateGPUBuffer(device, &.{
        .usage = buffer_usage,
        .size = data_size,
    }) orelse {
        SDL.err("SDL_CreateGPUBuffer", "", .{});
        return error.SDLError;
    };

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
    }) orelse {
        SDL.err("SDL_CreateGPUTransferBuffer", "", .{});
        return error.SDLError;
    };

    {
        const transfer_data: [*]T = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, true) orelse {
            SDL.err("SDL_MapGPUTransferBuffer", "", .{});
            return error.SDLError;
        }));
        @memcpy(transfer_data, data);
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        SDL.err("SDL_AcquireGPUCommandBuffer", "", .{});
        return error.SDLError;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        SDL.err("SDL_BeginGPUCopyPass", "", .{});
        return error.SDLError;
    };

    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        },
        &.{
            .buffer = buffer,
            .offset = 0,
            .size = data_size,
        },
        false,
    );

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        SDL.err("SDL_SubmitGPUCommandBuffer", "", .{});
        return error.SDLError;
    }
    c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    return buffer;
}

pub fn downloadBuffer(comptime T: type, len: u32, buffer: *c.SDL_GPUBuffer, device: *c.SDL_GPUDevice) []T {
    const data_size = @sizeOf(T) * len;

    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = data_size,
    }) orelse {
        SDL.err("SDL_CreateGPUTransferBuffer", "", .{});
        return error.SDLError;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    const buffer_region = c.SDL_GPUBufferRegion{
        .buffer = buffer,
        .offset = 0,
        .size = data_size,
    };

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        SDL.err("SDL_AcquireGPUCommandBuffer", "", .{});
        return error.SDLError;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        SDL.err("SDL_BeginGPUCopyPass", "", .{});
        return error.SDLError;
    };

    c.SDL_DownloadFromGPUBuffer(
        copy_pass,
        &buffer_region,
        &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        },
    );

    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        SDL.err("SDL_SubmitGPUCommandBuffer", "", .{});
        return error.SDLError;
    }

    const data: [*]T = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false)));
    return data[0..len];
}
