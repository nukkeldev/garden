const std = @import("std");

const ffi = @import("../ffi.zig");

const log = std.log.scoped(.@"gpu.slang");
const oom = @import("../log.zig").oom;

const c = ffi.c;
const SDL = ffi.SDL;
const cstr = ffi.CStr;

// TODO: FIXED_BUFFER_ALLOCATOR FOR COMPTIME JSON PARSING

test "online compilation" {
    const start = std.time.milliTimestamp();
    const shader = try @import("slang").compileShader(std.testing.allocator, "phong", @embedFile("../assets/shaders/phong.slang"));
    std.debug.print("[{}ms] spirv: {}, json: {}", .{ std.time.milliTimestamp() - start, shader.spirv.len, shader.refl.len });

    // const file = try std.fs.cwd().createFile("test.json", .{});
    // defer file.close();

    // _ = try file.write(shader.refl);
}

pub const ShaderLayout = struct {
    entry_point_name: []const u8,
    stage: c.SDL_GPUShaderStage,
    vertex_input: ?*c.SDL_GPUVertexInputState = null,

    num_storage_buffers: usize = 0,
    num_uniform_buffers: usize = 0,
    num_samplers: usize = 0,

    const Self = @This();

    pub fn parseLeaky(arena_allocator: std.mem.Allocator, json: []const u8, entry_point_name: []const u8) !Self {
        // Parse the reflection json file.
        const reflection = try std.json.parseFromSliceLeaky(RawReflection, arena_allocator, json, .{});

        var self = Self{
            .entry_point_name = entry_point_name,
            .stage = undefined,
        };

        var entry_point = reflection.entryPoints[0];
        for (reflection.entryPoints) |ep| {
            if (std.mem.eql(u8, ep.name, entry_point_name)) {
                entry_point = ep;
                break;
            }
        } else {
            log.err("Cannot find entrypoint '{s}' out of:", .{entry_point_name});
            for (reflection.entryPoints) |ep| log.debug("- '{s}'", .{ep.name});
            return error.UnknownEntryPoint;
        }

        outer: { // Entry point parsing
            self.stage = switch (entry_point.stage) {
                .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
                .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            };

            // Skip SDL_GPUVertexInputState creation for fragment shaders.
            if (entry_point.stage == .fragment) break :outer;

            // Parse the parameters for this entry point.
            if (entry_point.parameters.len > 1) {
                log.err("TODO: Only a single vertex parameter is supported currently!", .{});
                return error.InvalidFormat;
            }

            const parameter = entry_point.parameters[0];
            const fields = parameter.type.fields.?;

            var vertex_attributes = std.ArrayList(c.SDL_GPUVertexAttribute).init(arena_allocator);

            var offset: usize = 0;
            for (fields) |field| {
                const vertex_attribute = vertex_attributes.addOne() catch oom();

                vertex_attribute.location = @intCast(field.binding.?.index.?);
                vertex_attribute.offset = @intCast(offset);

                const sdl_type: c.SDL_GPUVertexElementFormat, const size: usize = switch (field.type.kind) {
                    .vector => inner: {
                        const count: usize = field.type.elementCount.?;
                        const element_type = field.type.elementType.?;

                        switch (element_type.kind) {
                            .scalar => switch (element_type.scalarType.?) {
                                .float32 => {
                                    const sdl_type = switch (count) {
                                        1 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT,
                                        2 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                                        3 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                                        4 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                                        else => unreachable,
                                    };

                                    break :inner .{ @intCast(sdl_type), @sizeOf(f32) * count };
                                },
                                else => {
                                    log.err("TODO: Unsupported element scalar type: {s}!", .{@tagName(element_type.scalarType.?)});
                                    return error.UnsupportedElementScalarType;
                                },
                            },
                            else => {
                                log.err("TODO: Unsupported element type: {s}!", .{@tagName(element_type.kind)});
                                return error.UnsupportedElementType;
                            },
                        }
                    },
                    .scalar => switch (field.type.scalarType.?) {
                        .float32 => .{ c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, 4 },
                        .uint32 => .{ c.SDL_GPU_VERTEXELEMENTFORMAT_UINT, 4 },
                        .bool => .{ c.SDL_GPU_VERTEXELEMENTFORMAT_UINT, 4 },
                    },
                    else => {
                        log.err("TODO: Unsupported field type: {s}!", .{@tagName(field.type.kind)});
                        return error.UnsupportedFieldType;
                    },
                };

                vertex_attribute.buffer_slot = 0; // TODO: Corresponds to the parameter index.
                vertex_attribute.format = sdl_type;

                offset += size;
            }

            const vertex_buffer_description = arena_allocator.create(c.SDL_GPUVertexBufferDescription) catch oom();
            vertex_buffer_description.* = .{
                .slot = 0,
                .pitch = @intCast(offset),
                .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                .instance_step_rate = 0,
            };

            self.vertex_input = arena_allocator.create(c.SDL_GPUVertexInputState) catch oom();
            self.vertex_input.?.* = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = @ptrCast(vertex_buffer_description),
                .num_vertex_attributes = @intCast(vertex_attributes.items.len),
                .vertex_attributes = @ptrCast(arena_allocator.dupe(
                    c.SDL_GPUVertexAttribute,
                    vertex_attributes.items,
                ) catch oom()),
            };
        }

        for (reflection.parameters) |param| {
            switch (entry_point.stage) {
                .vertex => if (param.binding.space.? > 1) continue,
                .fragment => if (param.binding.space.? < 2) continue,
            }

            switch (param.type.kind) {
                .resource => switch (param.type.baseShape.?) {
                    .structuredBuffer => self.num_storage_buffers += 1,
                    .texture2D => self.num_samplers += 1,
                },
                .constantBuffer => self.num_uniform_buffers += 1,
                .samplerState => self.num_samplers += 1,
            }
        }

        return self;
    }

    pub fn createShaderLeaky(self: *const Self, allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, code: []const u8) ?*c.SDL_GPUShader {
        const shader = c.SDL_CreateGPUShader(device, &.{
            .code = cstr(allocator, code) catch oom(),
            .code_size = code.len,
            .entrypoint = cstr(allocator, self.entry_point_name) catch oom(),
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .stage = self.stage,
            .num_uniform_buffers = @intCast(self.num_uniform_buffers),
            .num_storage_buffers = @intCast(self.num_storage_buffers),
            .num_samplers = @intCast(self.num_samplers),
            .num_storage_textures = 0, // TODO
        });
        if (shader == null) SDL.err("SDL_CreateGPUShader", "", .{});

        return shader;
    }

    pub fn createPipelineLeaky(
        allocator: std.mem.Allocator,
        device: *c.SDL_GPUDevice,
        window: *c.SDL_Window,
        vertex_layout: *const Self,
        fragment_layout: *const Self,
        vertex_code: []const u8,
        fragment_code: []const u8,
        wireframe: bool,
    ) ?*c.SDL_GPUGraphicsPipeline {
        const vertex_shader = vertex_layout.createShaderLeaky(allocator, device, vertex_code) orelse return null;
        const fragment_shader = fragment_layout.createShaderLeaky(allocator, device, fragment_code) orelse return null;

        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &.{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .vertex_input_state = vertex_layout.vertex_input.?.*,
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
                    .{
                        .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                    },
                },
                .has_depth_stencil_target = true,
                .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
            },
            .depth_stencil_state = .{
                .enable_depth_test = true,
                .enable_depth_write = true,
                .enable_stencil_test = false,
                .compare_op = c.SDL_GPU_COMPAREOP_LESS,
                .write_mask = 0xFF,
            },
            .rasterizer_state = .{
                .fill_mode = if (wireframe) c.SDL_GPU_FILLMODE_LINE else c.SDL_GPU_FILLMODE_FILL,
                .cull_mode = c.SDL_GPU_CULLMODE_BACK,
                .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            },
        });
        if (pipeline == null) SDL.err("SDL_CreateGPUGraphicsPipeline", "", .{});

        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseGPUShader(device, fragment_shader);

        return pipeline;
    }
};

test "shader layout creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const layout_json = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        "src/assets/shaders/compiled/phong.slang.layout",
        std.math.maxInt(usize),
    );
    defer std.testing.allocator.free(layout_json);

    _ = try ShaderLayout.parseLeaky(arena.allocator(), layout_json, "vertexMain");
    _ = try ShaderLayout.parseLeaky(arena.allocator(), layout_json, "fragmentMain");
}

/// NOTE: This is not a complete definition of the result of Slang's reflection json,
/// NOTE: only what I have been exposed to with my shaders.
pub const RawReflection = struct {
    parameters: []Parameter,
    entryPoints: []EntryPoint,

    pub const Parameter = struct {
        name: []const u8,
        binding: Binding,
        type: Type,
    };

    pub const Binding = struct {
        kind: BindingKind,

        // Descriptor Table Slot
        space: ?usize = null,
        index: ?usize = null, // Descriptor Table Slot & Varying Input
        used: ?usize = null,

        // Uniform
        offset: ?usize = null,
        size: ?usize = null,

        // Varying Input/Output
        count: ?usize = null,

        pub const BindingKind = enum { descriptorTableSlot, uniform, varyingInput, varyingOutput };
    };

    pub const Type = struct {
        kind: TypeKind,

        // Constant Buffer
        elementType: ?ElementType = null,
        containerVarLayout: ?ContainerVarLayout = null,
        elementVarLayout: ?ElementVarLayout = null,

        // Resource
        baseShape: ?TypeResourceBaseShape = null,
        resultType: ?*ElementType = null,

        pub const TypeKind = enum { constantBuffer, resource, samplerState };
        pub const ElementType = struct {
            kind: ElementTypeKind,
            name: ?[]const u8 = null,

            // Struct
            fields: ?[]ElementTypeStructField = null,
            // Scalar
            scalarType: ?ElementTypeScalarType = null,
            // Matrix
            rowCount: ?usize = null,
            columnCount: ?usize = null,
            // Vector / Array
            elementCount: ?usize = null,
            // Array
            uniformStride: ?usize = null,

            elementType: ?*ElementType = null,

            pub const ElementTypeKind = enum { @"struct", scalar, matrix, vector, array };
            pub const ElementTypeScalarType = enum { float32, uint32, bool };
            pub const ElementTypeStructField = struct {
                name: []const u8,
                type: *ElementType,
                stage: ?EntryPoint.EntryPointStage = null,
                binding: ?Binding = null,
                semanticName: ?[]const u8 = null,
                semanticIndex: ?usize = null,
            };
        };
        pub const ContainerVarLayout = struct { binding: Binding };
        pub const ElementVarLayout = struct {
            type: ElementType,
            binding: Binding,
        };
        pub const TypeResourceBaseShape = enum {
            structuredBuffer,
            texture2D,
        };
    };

    pub const EntryPoint = struct {
        name: []const u8,
        stage: EntryPointStage,
        parameters: []EntryPointParamater,
        result: EntryPointResult,
        bindings: ?[]EntryPointBinding = null,

        pub const EntryPointStage = enum {
            vertex,
            fragment,
        };
        pub const EntryPointParamater = struct {
            name: []const u8,
            semanticName: ?[]const u8 = null,
            stage: ?EntryPointStage = null,
            binding: ?Binding = null,
            type: Type.ElementType,
        };
        pub const EntryPointResult = struct {
            stage: EntryPointStage,
            semanticName: ?[]const u8 = null,
            binding: Binding,
            type: Type.ElementType,
        };
        pub const EntryPointBinding = struct {
            name: []const u8,
            binding: Binding,
        };
    };
};

test "slang reflection layout parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const vertexLayoutSource = @embedFile("../assets/shaders/compiled/vertex.layout");
    const fragmentLayoutSource = @embedFile("../assets/shaders/compiled/fragment.layout");

    _ = try std.json.parseFromSliceLeaky(
        RawReflection,
        arena.allocator(),
        vertexLayoutSource,
        .{ .ignore_unknown_fields = false },
    );
    _ = try std.json.parseFromSliceLeaky(
        RawReflection,
        arena.allocator(),
        fragmentLayoutSource,
        .{ .ignore_unknown_fields = false },
    );
}
