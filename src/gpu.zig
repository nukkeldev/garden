const SDL = @import("ffi.zig").SDL;
const c = @import("ffi.zig").c;

// -- Submodules -- //

pub const slang = @import("gpu/slang.zig");

// -- Enums -- //

pub const Stage = enum { Vertex, Fragment };

// -- Bindings -- //

/// Last updated for the following bindings:
/// ```
/// // Vertex
/// [[vk::binding(0, 1)]]
/// uniform ConstantBuffer<PerMeshVertexData> pmd;
/// [[vk::binding(1, 1)]]
/// uniform ConstantBuffer<PerFrameVertexData> pfd;
///
/// // Fragment
/// [[vk::binding(0, 2)]]
/// StructuredBuffer<float4> fragmentNormals;
/// [[vk::binding(0, 3)]]
/// uniform ConstantBuffer<PerMeshFragmentData> pmd;
/// [[vk::binding(1, 3)]]
/// uniform ConstantBuffer<float3> viewPosition;
/// ```
pub const Bindings = struct {
    // -- Types -- //

    pub const BufferBinding = struct {
        type: type,
        stage: SDL.ShaderStage,
        slot: u32,

        pub fn bind(comptime binding: BufferBinding, rpass: *const SDL.GPURenderPass, buffer: *const SDL.GPUBuffer, offset: u32) !void {
            try rpass.bindBuffer(
                binding.type,
                switch (binding.stage) {
                    .Vertex => @panic("TODO"),
                    .Fragment => .FragmentStorage,
                },
                binding.slot,
                buffer,
                offset,
            );
        }
    };

    pub const UniformBinding = struct {
        type: type,
        stage: SDL.ShaderStage,
        slot: u32,

        pub fn bind(comptime binding: UniformBinding, cmd: *const SDL.GPUCommandBuffer, data: *const binding.type) !void {
            cmd.pushUniformData(binding.stage, binding.type, binding.slot, data);
        }
    };

    pub const TextureBinding = struct {
        stage: SDL.ShaderStage,
        slot: u32,

        pub fn bind(
            comptime binding: TextureBinding,
            rpass: *const SDL.GPURenderPass,
            texture: *const SDL.GPUTexture,
            sampler: *const SDL.GPUSampler,
        ) void {
            const sampler_binding = c.SDL_GPUTextureSamplerBinding{
                .texture = texture.handle,
                .sampler = sampler.handle,
            };

            switch (binding.stage) {
                .Vertex => c.SDL_BindGPUVertexSamplers(rpass.handle, binding.slot, &sampler_binding, 1),
                .Fragment => c.SDL_BindGPUFragmentSamplers(rpass.handle, binding.slot, &sampler_binding, 1),
            }
        }
    };

    // -- Bindings -- //

    // Vertex

    pub const PER_MESH_VERTEX_DATA = UniformBinding{
        .type = PerMeshVertexData,
        .stage = .Vertex,
        .slot = 0,
    };

    pub const PER_FRAME_VERTEX_DATA = UniformBinding{
        .type = PerFrameVertexData,
        .stage = .Vertex,
        .slot = 1,
    };

    // Fragment

    pub const DIFFUSE_MAP = TextureBinding{
        .stage = .Fragment,
        .slot = 0,
    };

    pub const FRAGMENT_NORMALS = BufferBinding{
        .type = [4]f32,
        .stage = .Fragment,
        .slot = 1,
    };

    pub const PER_MESH_FRAGMENT_DATA = UniformBinding{
        .type = PerMeshFragmentData,
        .stage = .Fragment,
        .slot = 0,
    };

    pub const PER_FRAME_FRAGMENT_DATA = UniformBinding{
        .type = PerFrameFragmentData,
        .stage = .Fragment,
        .slot = 1,
    };
};

// -- Structs -- //

// Per-Mesh Data

pub const PerMeshVertexData = extern struct {
    model: [16]f32,
    // TODO: Move this to a per-model.
    normalMat: [16]f32,
};

pub const PerMeshFragmentData = extern struct {
    // TODO: Move this to a per-model.
    normalMat: [16]f32,
    material: Material,
};

// Per-Frame Data

pub const PerFrameVertexData = extern struct {
    view_proj: [16]f32,
};

pub const PerFrameFragmentData = extern struct {
    lights: [16]Light,
    lightCount: u32,
    view_pos: [3]f32,
};

// Vertex Data

pub const VertexInput = extern struct {
    position: [3]f32,
    normal: [3]f32,
    texcoord: [2]f32,
};

// Material

pub const Material = extern struct {
    /// bool
    basic: u32 = @intFromBool(false),
    flatShading: u32 = @intFromBool(false),
    __pad1: [8]u8 = .{0} ** 8,

    ambientColor: [3]f32 = .{ 1, 1, 1 },
    __pad2: [4]u8 = .{0} ** 4,

    diffuseColor: [3]f32 = .{ 1, 1, 1 },
    __pad3: [4]u8 = .{0} ** 4,

    specularColor: [3]f32 = .{ 1, 1, 1 },
    specularExponent: f32 = 1000,
};

// Light

pub const Light = extern struct {
    position: [3]f32,
    __pad0: [4]u8 = .{0} ** 4,
    color: [3]f32,
    __pad1: [4]u8 = .{0} ** 4,
};
