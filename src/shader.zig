// Imports

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

// Cache

pub const GraphicsPipelineCache = struct {
    arena: std.heap.ArenaAllocator,
    pipelines: std.StringHashMap(GraphicsPipeline),

    // Types

    const Self = @This();

    // (De)Initialization

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .arena = .init(allocator),
            .shaders = .init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        var iter = self.pipelines.valueIterator();
        while (iter.next()) |ppl| ppl.deinit();

        self.arena.deinit();
    }

    // Methods

    pub fn put(self: *Self, pipeline: GraphicsPipeline) !void {
        try self.pipelines.put(pipeline.name, pipeline);
    }

    pub fn get(self: *const Self, name: []const u8) ?*const GraphicsPipeline {
        return self.pipelines.getPtr(name);
    }
};

// Pipeline

pub const GraphicsPipeline = struct {
    device: *c.SDL_GPUDevice,
    name: []const u8,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_shader: Shader,
    fragment_shader: Shader,

    const Self = @This();
    pub const InitOptions = struct {
        vertex_shader: Shader,
        fragment_shader: Shader,
    };

    pub fn init(device: *c.SDL_GPUDevice, name: []const u8, options: InitOptions) Self {
        var self: Self = undefined;

        self.device = device;
        self.name = name;

        self.vertex_shader = options.vertex_shader;
        self.fragment_shader = options.fragment_shader;

        const info: c.SDL_GPUGraphicsPipelineCreateInfo = .{
            .vertex_shader = &self.vertex_shader,
            .fragment_shader = &self.fragment_shader,
            .
        };

        self.pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &info);

        return self;
    }

    pub fn deinit(self: Self) void {
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
    }

    // ---

    pub fn reload(self: *Self) void {
        _ = self;
    }
};

// Shader

pub const Shader = struct {
    device: *c.SDL_GPUDevice,
    path: []const u8,

    shader: *c.SDL_GPUShader,
    location: union(enum) {
        File: std.fs.File,
        // TODO: Embedded,
    },

    const Self = @This();
    pub const Stage = enum {
        Vertex,
        Fragment,
    };

    pub fn initFromFile(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, path: []const u8, stage: Stage) Self {
        const shader_name = std.fs.path.basename(path);

        // Read the contents of the sources.
        const layout_contents, const shader_contents = outer: {
            const layout = std.fs.cwd().readFileAlloc(
                allocator,
                path ++ ".layout",
            ) catch |e| common.fatal(
                common.log,
                "Failed to read shader layout \"{s}.layout\": {}",
                .{ shader_name, e },
            );

            const shader = std.fs.cwd().readFileAlloc(
                allocator,
                path,
            ) catch |e| common.fatal(
                common.log,
                "Failed to read shader \"{s}\": {}",
                .{ shader_name, e },
            );

            break :outer .{ layout, shader };
        };

        // Parse the layout.
        // We are under the assumption of a valid layout.

        const parsed_layout = std.json.parseFromSlice(std.json.Value, Self.allocator, layout_contents, .{}) catch @panic("");
        const layout = parsed_layout.value.object;

        const entry_point = layout.get("entryPoints").?.array[0];

        const desc: c.SDL_GPUShaderCreateInfo = .{
            .code_size = shader_contents.len,
            .code = shader_contents,
            .entrypoint = entry_point,
            .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
            .stage = switch (stage) {
                .Vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
                .Fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            },
            .num_uniform_buffers = 0, // TODO:
        };

        const shader = c.SDL_CreateGPUShader(device, &desc);

        return .{
            .device = device,
            .path = path,
            .shader = shader,
            .location = .File,
        };
    }

    pub fn deinit(self: Self) void {
        c.SDL_ReleaseGPUShader(self.device, self.shader);
    }

    // ---

    pub fn get
};

// Shader Layouts

const Layout = struct {
    
}

fn parseShaderLayout(layout: []const u8)