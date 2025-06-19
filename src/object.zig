const std = @import("std");
const obj = @import("obj");

const c = @import("ffi.zig").c;
const gpu = @import("gpu.zig");

pub fn Object(comptime VertexType: type, comptime IndexType: enum { U16, U32 }) type {
    const ResolvedIndexType = switch (IndexType) {
        .U16 => u16,
        .U32 => u32,
    };

    return struct {
        device: *c.SDL_GPUDevice,
        allocator: ?std.mem.Allocator = null,

        vertex_data: []const VertexType,
        index_data: ?[]const ResolvedIndexType = null,

        vertex_buffer: *c.SDL_GPUBuffer,
        index_buffer: ?*c.SDL_GPUBuffer = null,

        model: ?obj.Mesh = null,
        material: ?obj.Material = null,

        const Self = @This();

        pub fn init(device: *c.SDL_GPUDevice, vertex_data: []const VertexType) Self {
            return .{
                .device = device,
                .vertex_data = vertex_data,
                .vertex_buffer = gpu.initBuffer(VertexType, @intCast(vertex_data.len), vertex_data, device),
            };
        }

        pub fn initIndexed(device: *c.SDL_GPUDevice, vertex_data: []const VertexType, index_data: []const ResolvedIndexType) Self {
            return .{
                .device = device,
                .vertex_data = vertex_data,
                .index_data = index_data,
                .vertex_buffer = gpu.initBuffer(VertexType, @intCast(vertex_data.len), vertex_data, device),
                .index_buffer = gpu.initBuffer(ResolvedIndexType, @intCast(index_data.len), index_data, device),
            };
        }

        pub fn initFromOBJ(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, model_data: []const u8, material_data: ?[]const u8) !Self {
            const model = try obj.parseObj(allocator, model_data);

            var self = init(device, model.vertices, model.vertices.len);
            self.allocator = allocator;
            self.model = model;
            if (material_data) |d| {
                const material = try obj.parseMtl(allocator, d);
                self.material = material;
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.model) |m| m.deinit(self.allocator.?);
            if (self.material != null) self.material.?.deinit(self.allocator.?);

            c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
            if (self.index_buffer) |ib| c.SDL_ReleaseGPUBuffer(self.device, ib);
        }

        pub fn draw(self: *const Self, render_pass: *c.SDL_GPURenderPass) void {
            c.SDL_BindGPUVertexBuffers(render_pass, 0, &[_]c.SDL_GPUBufferBinding{.{ .buffer = self.vertex_buffer, .offset = 0 }}, 1);
            if (self.index_buffer) |ib| {
                c.SDL_BindGPUIndexBuffer(render_pass, &[_]c.SDL_GPUBufferBinding{.{ .buffer = ib, .offset = 0 }}, switch (IndexType) {
                    .U16 => c.SDL_GPU_INDEXELEMENTSIZE_16BIT,
                    .U32 => c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
                });
                c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast(self.index_data.?.len), 1, 0, 0, 0);
            } else {
                c.SDL_DrawGPUPrimitives(render_pass, @intCast(self.vertex_data.len), 1, 0, 0);
            }
        }
    };
}
