const std = @import("std");

const ffi = @import("../ffi.zig");
const log = @import("../log.zig");

const c = ffi.c;
const cstr = ffi.cstr;

/// This is not a full representation of the file, just the properties we need.
pub const ShaderLayout = struct {
    allocator: std.mem.Allocator,

    entry_point_name: []const u8,
    stage: c.SDL_GPUShaderStage,
    vertex_input: ?*c.SDL_GPUVertexInputState = null,
    num_uniform_buffers: usize = 0,

    const Self = @This();

    pub fn parseLeaky(allocator: std.mem.Allocator, json: []const u8) ?Self {
        // Parse the reflection json file.
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch log.oom();
        defer parsed.deinit();

        var self = Self{
            .allocator = allocator,
            .entry_point_name = undefined,
            .stage = undefined,
        };

        { // Entry point parsing
            const entry_points = parsed.value.object.get("entryPoints").?.array;
            const entry_point = entry_points.getLast().object;

            self.entry_point_name = allocator.dupe(u8, entry_point.get("name").?.string) catch log.oom();
            self.stage = outer: {
                const raw_stage = entry_point.get("stage").?.string;

                if (std.mem.eql(u8, raw_stage, "vertex")) {
                    break :outer c.SDL_GPU_SHADERSTAGE_VERTEX;
                } else if (std.mem.eql(u8, raw_stage, "fragment")) {
                    break :outer c.SDL_GPU_SHADERSTAGE_FRAGMENT;
                } else {
                    log.gdn.err("Invalid Shader Type: {s}!", .{raw_stage});
                    return null;
                }
            };

            // Skip parameter parsing for fragment shaders.
            if (self.stage == c.SDL_GPU_SHADERSTAGE_FRAGMENT) return self;

            // Parse the parameters for this entry point if present.
            const parameters = entry_point.get("parameters").?.array;
            if (parameters.items.len > 1) {
                log.gdn.err("TODO: Shader reflection only supports a single vertex parameter!", .{});
                return null;
            }

            if (parameters.getLastOrNull()) |parameter| {
                const fields = parameter.object.get("type").?.object.get("fields").?.array;
                var vertex_attributes = std.ArrayList(c.SDL_GPUVertexAttribute).init(allocator);

                var offset: usize = 0;
                for (fields.items) |field| {
                    const vertex_attribute = vertex_attributes.addOne() catch log.oom();

                    vertex_attribute.location = @intCast(field.object.get("binding").?.object.get("index").?.integer);
                    vertex_attribute.offset = @intCast(offset);

                    const ty = field.object.get("type").?.object;
                    const type_kind = ty.get("kind").?.string;

                    const sdl_type: c.SDL_GPUVertexElementFormat, const size: usize = if (std.mem.eql(u8, type_kind, "vector")) outer: {
                        const count: usize = @intCast(ty.get("elementCount").?.integer);
                        const element_type = ty.get("elementType").?.object;
                        const element_type_kind = element_type.get("kind").?.string;

                        if (std.mem.eql(u8, element_type_kind, "scalar")) {
                            const scalar_type = element_type.get("scalarType").?.string;
                            if (std.mem.eql(u8, scalar_type, "float32")) {
                                const sdl_type = switch (count) {
                                    1 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT,
                                    2 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                                    3 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                                    4 => c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                                    else => unreachable,
                                };
                                break :outer .{ @intCast(sdl_type), @sizeOf(f32) * count };
                            } else {
                                log.gdn.err("TODO: Scalar type \"{s}\" not yet supported!", .{scalar_type});
                                return null;
                            }
                        } else {
                            log.gdn.err("TODO: Vector element kind \"{s}\" not yet supported!", .{element_type_kind});
                            return null;
                        }
                    } else {
                        log.gdn.err("TODO: Type kind \"{s}\" not yet supported!", .{type_kind});
                        return null;
                    };

                    vertex_attribute.buffer_slot = 0; // TODO: Corresponds to the parameter index.
                    vertex_attribute.format = sdl_type;

                    offset += size;
                }

                const vertex_buffer_description = allocator.create(c.SDL_GPUVertexBufferDescription) catch log.oom();
                vertex_buffer_description.* = .{
                    .slot = 0,
                    .pitch = @intCast(offset),
                    .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                    .instance_step_rate = 0,
                };

                self.vertex_input = allocator.create(c.SDL_GPUVertexInputState) catch log.oom();
                self.vertex_input.?.* = .{
                    .num_vertex_buffers = 1,
                    .vertex_buffer_descriptions = @ptrCast(vertex_buffer_description),
                    .num_vertex_attributes = @intCast(vertex_attributes.items.len),
                    .vertex_attributes = @ptrCast(allocator.dupe(c.SDL_GPUVertexAttribute, vertex_attributes.items) catch log.oom()),
                };
            }
        } // Entry point parsing

        { // Paramater parsing
            self.num_uniform_buffers = parsed.value.object.get("parameters").?.array.items.len;
        } // Paramater parsing

        return self;
    }

    pub fn createShader(self: *const Self, device: *c.SDL_GPUDevice, code: []const u8) ?*c.SDL_GPUShader {
        const shader = c.SDL_CreateGPUShader(device, &.{
            .code = cstr(self.allocator, code) catch log.oom(),
            .code_size = code.len,
            .entrypoint = cstr(self.allocator, self.entry_point_name) catch log.oom(),
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .stage = self.stage,
            .num_uniform_buffers = @intCast(self.num_uniform_buffers),
        });
        if (shader == null) log.sdl.err("SDL_CreateGPUShader");

        return shader;
    }

    pub fn createPipeline(
        device: *c.SDL_GPUDevice,
        window: *c.SDL_Window,
        vertex_layout: *const Self,
        fragment_layout: *const Self,
        vertex_code: []const u8,
        fragment_code: []const u8,
    ) ?*c.SDL_GPUGraphicsPipeline {
        const vertex_shader = vertex_layout.createShader(device, vertex_code) orelse return null;
        const fragment_shader = fragment_layout.createShader(device, fragment_code) orelse return null;

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
            },
            .rasterizer_state = .{
                .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            },
        });
        if (pipeline == null) log.sdl.err("SDL_CreateGPUGraphicsPipeline");

        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseGPUShader(device, fragment_shader);

        return pipeline;
    }
};

test {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = ShaderLayout.parseLeaky(arena.allocator(), @embedFile("../shaders/compiled/shader.vert.layout")).?;
}
