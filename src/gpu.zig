const SDL = @import("ffi.zig").SDL;

// -- Submodules -- //

pub const slang = @import("gpu/slang.zig");
pub const compile = @import("gpu/compile.zig");

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

    pub const FRAGMENT_NORMALS = BufferBinding{
        .type = [4]f32,
        .stage = .Fragment,
        .slot = 0,
    };

    pub const PER_MESH_FRAGMENT_DATA = UniformBinding{
        .type = PerMeshFragmentData,
        .stage = .Fragment,
        .slot = 0,
    };

    pub const VIEW_POSITION = UniformBinding{
        .type = [4]f32,
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

    /// bool
    flatShading: u32,
    __pad0: [12]u8 = .{0} ** 12,

    ambientColor: [3]f32,
    __pad1: [4]u8 = .{0} ** 4,

    diffuseColor: [3]f32,
    __pad2: [4]u8 = .{0} ** 4,

    specularColor: [3]f32,
    __pad3: [4]u8 = .{0} ** 4,
    specularExponent: f32,
    __pad4: [12]u8 = .{0} ** 12,
};

// Per-Frame Data

pub const PerFrameVertexData = extern struct {
    view_proj: [16]f32,
};

// Vertex Data

pub const VertexInput = extern struct {
    position: [3]f32,
    normal: [3]f32,
};
