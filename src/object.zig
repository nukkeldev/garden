const std = @import("std");
const zm = @import("zm");
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

        const Self = @This();

        pub fn init(device: *c.SDL_GPUDevice, vertex_data: []const VertexType) Self {
            return .{
                .device = device,
                .vertex_data = vertex_data,
                .vertex_buffer = gpu.initBuffer(VertexType, @intCast(vertex_data.len), vertex_data, device, c.SDL_GPU_BUFFERUSAGE_VERTEX),
            };
        }

        pub fn initIndexed(device: *c.SDL_GPUDevice, vertex_data: []const VertexType, index_data: []const ResolvedIndexType) Self {
            return .{
                .device = device,
                .vertex_data = vertex_data,
                .index_data = index_data,
                .vertex_buffer = gpu.initBuffer(VertexType, @intCast(vertex_data.len), vertex_data, device, c.SDL_GPU_BUFFERUSAGE_VERTEX),
                .index_buffer = gpu.initBuffer(ResolvedIndexType, @intCast(index_data.len), index_data, device, c.SDL_GPU_BUFFERUSAGE_INDEX),
            };
        }

        /// Creates one Object per mesh in the .obj.
        pub fn initFromOBJLeaky(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, model_data: []const u8, material_bytes: ?[]const u8) ![]Self {
            var model = try obj.parseObj(allocator, model_data);
            defer model.deinit(allocator);
            const objects = try allocator.alloc(Self, model.meshes.len);

            var material_data = if (material_bytes) |d| try obj.parseMtl(allocator, d) else null;
            defer if (material_data != null) material_data.?.deinit(allocator);

            const model_verticies = try allocator.alloc(VertexType, model.vertices.len * 2);
            for (0..model.vertices.len / 3) |i| {
                model_verticies[i] = .{ model.vertices[i * 3], model.vertices[i * 3 + 1], model.vertices[i * 3 + 2], 1.0, 1.0, 1.0 };
            }

            for (model.meshes, 0..) |mesh, i| {
                const vertices = try allocator.dupe(VertexType, model_verticies);
                const indices = try allocator.alloc(ResolvedIndexType, mesh.indices.len);
                for (mesh.indices, 0..) |index, j| {
                    const k: usize = @intCast(index.vertex.?);
                    var color: zm.Vec3f = .{ 1, 1, 1 };

                    if (material_data) |m| {
                        for (mesh.materials) |mat| if (j >= mat.start_index and j <= mat.end_index) {
                            const material = m.materials.get(mat.material).?;
                            color = material.diffuse_color orelse .{ 1.0, 1.0, 1.0 };
                        };
                    }

                    vertices[k][3] = color[0];
                    vertices[k][4] = color[1];
                    vertices[k][5] = color[2];

                    indices[j] = @intCast(k);
                }
                objects[i] = initIndexed(device, vertices, indices);
            }

            return objects;
        }

        pub fn deinit(self: *Self) void {
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
                // c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast(self.index_data.?.len), 1, 0, 0, 0);

                for (0..self.index_data.?.len / 3) |i| {
                    c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast((i + 1) * 3), 1, 0, 0, 0);
                }
            } else {
                c.SDL_DrawGPUPrimitives(render_pass, @intCast(self.vertex_data.len), 1, 0, 0);
            }
        }
    };
}
