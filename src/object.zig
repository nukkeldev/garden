const std = @import("std");

const zm = @import("zm");
const obj = @import("obj");

const transform = @import("transform.zig");
const c = @import("ffi.zig").c;
const gpu = @import("gpu.zig");

const log = @import("log.zig");

pub const Model = struct {
    o012: transform.O012,
    meshes: []Mesh,
};

pub const Mesh = struct {
    device: *c.SDL_GPUDevice,

    name: []const u8,

    vertex_data: []const gpu.VertexInput,
    index_data: ?[]const u32 = null,
    // SSBOs apparently require a 16-byte alignment.
    fragment_normals_data: []const [4]f32,

    use_flat_shading: bool = true,

    vertex_buffer: *c.SDL_GPUBuffer,
    index_buffer: *c.SDL_GPUBuffer,
    fragment_normals_buffer: *c.SDL_GPUBuffer,

    const Self = @This();

    /// Creates one Object per mesh in the .obj.
    pub fn initFromOBJLeaky(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, model_data: []const u8, material_bytes: ?[]const u8) ![]Self {
        var model = try obj.parseObj(allocator, model_data);
        defer model.deinit(allocator);
        const objects = try allocator.alloc(Self, model.meshes.len);

        var material_data = if (material_bytes) |d| try obj.parseMtl(allocator, d) else null;
        defer if (material_data != null) material_data.?.deinit(allocator);

        const model_verticies = try allocator.alloc(gpu.VertexInput, model.vertices.len / 3);
        for (0..model_verticies.len) |i| {
            model_verticies[i] = .{
                .position = .{ model.vertices[i * 3], model.vertices[i * 3 + 1], model.vertices[i * 3 + 2] },
                .normal = undefined,
                .color = .{ 1, 1, 1 },
            };
        }

        for (model.meshes, 0..) |mesh, i| {
            const vertices = try allocator.dupe(gpu.VertexInput, model_verticies);
            const indices = try allocator.alloc(u32, mesh.indices.len);

            for (mesh.indices, 0..) |index, j| {
                const k: usize = @intCast(index.vertex.?);

                if (index.normal) |n| vertices[k].normal = [_]f32{
                    model.normals[n * 3],
                    model.normals[n * 3 + 1],
                    model.normals[n * 3 + 2],
                };

                if (material_data) |m| {
                    for (mesh.materials) |mat| if (j >= mat.start_index and j <= mat.end_index) {
                        const material = m.materials.get(mat.material).?;
                        vertices[k].color = material.diffuse_color orelse .{ 1.0, 1.0, 1.0 };
                        break;
                    };
                }
                indices[j] = @intCast(k);
            }

            const fragment_normals_data = try calculateFragmentNormals(allocator, vertices, indices);

            objects[i] = .{
                .device = device,
                .name = try allocator.dupe(u8, mesh.name orelse {
                    log.gdn.err("Meshes must be named!", .{});
                    return error.MeshesMustBeNamed;
                }),
                .vertex_data = vertices,
                .index_data = indices,
                .fragment_normals_data = fragment_normals_data,
                .vertex_buffer = try gpu.initBuffer(
                    gpu.VertexInput,
                    @intCast(vertices.len),
                    vertices,
                    device,
                    c.SDL_GPU_BUFFERUSAGE_VERTEX,
                ),
                .index_buffer = try gpu.initBuffer(u32, @intCast(indices.len), indices, device, c.SDL_GPU_BUFFERUSAGE_INDEX),
                .fragment_normals_buffer = try gpu.initBuffer(
                    [4]f32,
                    @intCast(fragment_normals_data.len),
                    fragment_normals_data,
                    device,
                    c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                ),
            };

            log.gdn.debug("Loaded mesh '{s}' with {} verticies and {} indices.", .{
                objects[i].name,
                vertices.len,
                indices.len,
            });
        }

        return objects;
    }

    pub fn deinit(self: Self) void {
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.index_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.fragment_normals_buffer);
    }

    pub fn draw(self: *const Self, render_pass: *c.SDL_GPURenderPass) void {
        c.SDL_BindGPUFragmentStorageBuffers(render_pass, 0, &self.fragment_normals_buffer, 1);
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &[_]c.SDL_GPUBufferBinding{.{ .buffer = self.vertex_buffer, .offset = 0 }}, 1);
        c.SDL_BindGPUIndexBuffer(render_pass, &[_]c.SDL_GPUBufferBinding{.{ .buffer = self.index_buffer, .offset = 0 }}, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast(self.index_data.?.len), 1, 0, 0, 0);
    }

    fn calculateFragmentNormals(allocator: std.mem.Allocator, vertices: []const gpu.VertexInput, indices: []const u32) ![]const [4]f32 {
        const fragments = indices.len / 3;
        const fragment_normals_data = try allocator.alloc([4]f32, fragments);

        for (0..fragments) |fragmentId| {
            const v0: zm.Vec3f = vertices[indices[fragmentId * 3]].position;
            const v1: zm.Vec3f = vertices[indices[fragmentId * 3 + 1]].position;
            const v2: zm.Vec3f = vertices[indices[fragmentId * 3 + 2]].position;
            const normal = zm.vec.normalize(zm.vec.cross(v1 - v0, v2 - v0));
            fragment_normals_data[fragmentId] = .{ normal[0], normal[1], normal[2], 0 };
        }

        return fragment_normals_data;
    }
};
