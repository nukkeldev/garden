const std = @import("std");

const zm = @import("zm");
const ztracy = @import("ztracy");

const gpu = @import("gpu.zig");
const log = @import("log.zig");

const DynamicTransform = @import("transform.zig").DynamicTransform;
const SDL = @import("ffi.zig").SDL;
const c = @import("ffi.zig").c;
const gdn = log.gdn;

const IndexType = u32;

pub const Model = struct {
    name: []const u8,
    transform: DynamicTransform,

    meshes: []Mesh,

    // -- Types -- //

    pub const Mesh = struct {
        name: []const u8,
        material: gpu.Material,

        vertex_data: []const gpu.VertexInput,
        vertex_buffer: SDL.GPUBuffer,

        index_data: []const u32,
        index_buffer: SDL.GPUBuffer,

        fragment_normals_data: []const [4]f32,
        fragment_normals_buffer: SDL.GPUBuffer,
    };

    // -- Initialization -- //

    /// Initializes a `Model` from an embedded `.obj` model and `.mtl` material library.
    pub fn initFromEmbeddedObj(
        allocator: std.mem.Allocator,
        device: *const SDL.GPUDevice,
        name: []const u8,
        transform: DynamicTransform,
        model_data: []const u8,
        material_lib_data: []const u8,
    ) !Model {
        const model_tz = ztracy.ZoneN(@src(), "initFromEmbeddedObj");
        defer model_tz.End();

        gdn.debug("Loading model '{s}'...", .{name});

        // Parse the OBJ model and material data.
        var obj_model, var material_lib = try loadOBJFromBytesDeprecated(allocator, model_data, material_lib_data);
        defer obj_model.deinit(allocator);
        defer material_lib.deinit(allocator);

        // Allocate places for us to store our re-computed meshes.
        const meshes = try allocator.alloc(Mesh, obj_model.meshes.len);

        // The OBJ model gives us a flatten list of verticies that we need to
        // unflatten as well as so we can store additional data per vertex.
        const master_vertices_tz = ztracy.ZoneN(@src(), "copy vert");
        const master_vertices = try allocator.alloc(gpu.VertexInput, obj_model.vertices.len / 3);
        for (master_vertices, 0..) |*vertex, i| {
            vertex.* = .{
                .position = .{ obj_model.vertices[i * 3], obj_model.vertices[i * 3 + 1], obj_model.vertices[i * 3 + 2] },
                .normal = undefined,
            };
        }
        master_vertices_tz.End();

        // Create our transfer buffer.
        var max_tbuf_len = @sizeOf(gpu.VertexInput) * master_vertices.len;
        for (obj_model.meshes) |*mesh| {
            max_tbuf_len = @max(
                mesh.indices.len * @sizeOf(IndexType),
                mesh.indices.len / 3 * @sizeOf([4]f32),
                max_tbuf_len,
            );
        }

        const tbuf: SDL.GPUTransferBuffer(.Upload) = try .create(
            allocator,
            device,
            max_tbuf_len,
            "Model Upload Buffer",
        );
        defer tbuf.release(device);

        // Additionally, these verticies are common for all meshes so them per `Mesh`.
        for (obj_model.meshes, meshes, 0..) |*raw_mesh, *mesh, mesh_idx| {
            const mesh_tz = ztracy.ZoneN(@src(), "copy mesh");
            defer mesh_tz.End();

            const mesh_name = raw_mesh.name orelse {
                log.gdn.err("Cannot load an unnamed mesh!", .{});
                return error.InvalidModel;
            };
            gdn.debug("Loading mesh '{s}' for model '{s}'.", .{ mesh_name, name });

            // Make sure we are able to render this model.
            {
                // Ensure we are loading a triangulated mesh.
                for (raw_mesh.num_vertices) |*n| if (n.* != 3) {
                    gdn.err("Cannot load a mesh with non-triangular faces!", .{});
                    return error.InvalidModel;
                };

                // TODO: Currently we only support one material per mesh.
                if (raw_mesh.materials.len > 1) {
                    gdn.err("TODO: Cannot load a mesh with multiple materials!", .{});
                    gdn.debug("The mesh uses the following materials: ", .{});
                    for (raw_mesh.materials, 0..) |m, i| gdn.debug("{}. {s}", .{ i, m.material });
                    return error.InvalidModel;
                }
            }

            // Allocate enough space for our vertices and indices.
            const vertices_mask = try allocator.alloc(bool, master_vertices.len);
            const vertices = try allocator.dupe(gpu.VertexInput, master_vertices);
            const indices = try allocator.alloc(u32, raw_mesh.indices.len);

            // Copy over all of the indices.
            for (raw_mesh.indices, indices) |*raw_index, *index| {
                const vertex_idx: usize = @intCast(raw_index.vertex orelse return error.InvalidModel);
                const normal_idx: usize = @intCast(raw_index.normal orelse return error.InvalidModel);

                if (!vertices_mask[vertex_idx]) {
                    vertices[vertex_idx].normal = [_]f32{
                        obj_model.normals[normal_idx * 3],
                        obj_model.normals[normal_idx * 3 + 1],
                        obj_model.normals[normal_idx * 3 + 2],
                    };
                    vertices_mask[vertex_idx] = true;
                }

                index.* = @intCast(vertex_idx);
            }

            // Calculate fragment normals for flat-shading.
            const fragment_normals_data = outer: {
                const fragments = indices.len / 3;
                const fragment_normals_data = try allocator.alloc([4]f32, fragments);

                for (0..fragments) |fragmentId| {
                    const v0: zm.Vec3f = vertices[indices[fragmentId * 3]].position;
                    const v1: zm.Vec3f = vertices[indices[fragmentId * 3 + 1]].position;
                    const v2: zm.Vec3f = vertices[indices[fragmentId * 3 + 2]].position;
                    const normal = zm.vec.normalize(zm.vec.cross(v1 - v0, v2 - v0));
                    fragment_normals_data[fragmentId] = .{ normal[0], normal[1], normal[2], 0 };
                }

                break :outer fragment_normals_data;
            };

            // Retrieve the material for this mesh.
            const material = if (raw_mesh.materials.len > 0) outer: {
                const raw_material = material_lib.materials.getPtr(raw_mesh.materials[0].material) orelse {
                    gdn.err("Failed to load material '{s}' from material library!", .{raw_mesh.materials[0].material});
                    return error.InvalidMaterial;
                };
                gdn.debug("Converting raw material '{s}': {}", .{ raw_mesh.materials[0].material, raw_material });

                const material = gpu.Material{};

                gdn.debug("Loaded material '{s}': {}", .{ raw_mesh.materials[0].material, material });
                break :outer material;
            } else gpu.Material{};

            // Create our and upload data to our buffers.
            var vertex_buffer: SDL.GPUBuffer = undefined;
            var index_buffer: SDL.GPUBuffer = undefined;
            var fragment_normals_buffer: SDL.GPUBuffer = undefined;
            {
                const cmd = try SDL.GPUCommandBuffer.acquire(device);
                const cpass = try SDL.GPUCopyPass.begin(&cmd);

                vertex_buffer = try SDL.GPUBuffer.create(
                    allocator,
                    device,
                    "Mesh Vertex Buffer",
                    c.SDL_GPU_BUFFERUSAGE_VERTEX,
                    @intCast(@sizeOf(gpu.VertexInput) * vertices.len),
                );
                try cpass.upload(&tbuf, device, &vertex_buffer, gpu.VertexInput, vertices, true, false);

                index_buffer = try SDL.GPUBuffer.create(
                    allocator,
                    device,
                    "Mesh Index Buffer",
                    c.SDL_GPU_BUFFERUSAGE_INDEX,
                    @intCast(@sizeOf(IndexType) * indices.len),
                );
                try cpass.upload(&tbuf, device, &index_buffer, IndexType, indices, true, false);

                fragment_normals_buffer = try SDL.GPUBuffer.create(
                    allocator,
                    device,
                    "Mesh Fragment Normals Buffer",
                    c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                    @intCast(@sizeOf([4]f32) * fragment_normals_data.len),
                );
                try cpass.upload(&tbuf, device, &fragment_normals_buffer, [4]f32, fragment_normals_data, true, false);

                cpass.end();
                try cmd.submit();
            }

            mesh.* = .{
                .name = try allocator.dupe(u8, mesh_name),
                .material = material,
                .vertex_data = vertices,
                .vertex_buffer = vertex_buffer,
                .index_data = indices,
                .index_buffer = index_buffer,
                .fragment_normals_data = fragment_normals_data,
                .fragment_normals_buffer = fragment_normals_buffer,
            };

            log.gdn.debug("Loaded mesh '{s}' with {} verticies and {} indices.", .{
                meshes[mesh_idx].name,
                vertices.len,
                indices.len,
            });
        }

        gdn.info("Loaded model '{s}'.", .{name});
        return Model{ .name = name, .transform = transform, .meshes = meshes };
    }

    // -- Deinitialization -- //

    pub fn deinit(model: *Model, device: *const SDL.GPUDevice) void {
        // TODO: Deallocate everything so we don't need to use an arena.
        for (model.meshes) |*mesh| {
            mesh.vertex_buffer.release(device);
            mesh.index_buffer.release(device);
            mesh.fragment_normals_buffer.release(device);
        }
    }

    // -- Rendering -- //

    pub fn draw(
        model: *const Model,
        cmd: *const SDL.GPUCommandBuffer,
        rpass: *const SDL.GPURenderPass,
    ) !void {
        // Calculate the model and inverse transposed normal matricies.
        const model_matrix = model.transform.modelMatrix();
        const normal_matrix = model_matrix.inverse().transpose();

        const pmvd = gpu.PerMeshVertexData{
            .model = model_matrix.data,
            .normalMat = normal_matrix.data,
        };

        // Render each mesh with the proper material properties.
        for (model.meshes) |*mesh| {
            const pmfd = gpu.PerMeshFragmentData{
                .normalMat = normal_matrix.data,
                .material = mesh.material,
            };

            // Bind our uniforms and storage buffers.
            try gpu.Bindings.PER_MESH_VERTEX_DATA.bind(cmd, &pmvd);
            try gpu.Bindings.PER_MESH_FRAGMENT_DATA.bind(cmd, &pmfd);
            try gpu.Bindings.FRAGMENT_NORMALS.bind(rpass, &mesh.fragment_normals_buffer, 0);

            // Bind our vertex and index buffers.
            try rpass.bindBuffer(gpu.VertexInput, .Vertex, 0, &mesh.vertex_buffer, 0);
            try rpass.bindBuffer(IndexType, .Index, 0, &mesh.index_buffer, 0);

            // Push a render call to the pass.
            rpass.drawIndexedPrimitives(@intCast(mesh.index_data.len), 1, 0, 0, 0);
        }
    }
};

// -- Helper Functions -- //

const obj = @import("obj");

const OBJModel = struct { obj.ObjData, obj.MaterialData };

/// Parses an `.obj` model and `.mtl` material library from bytes.
fn loadOBJFromBytesDeprecated(allocator: std.mem.Allocator, obj_data: []const u8, mtl_data: []const u8) !OBJModel {
    const parsing_tz = ztracy.ZoneN(@src(), "loadOBJFromBytesDeprecated");
    defer parsing_tz.End();

    return .{ try obj.parseObj(allocator, obj_data), try obj.parseMtl(allocator, mtl_data) };
}

/// Parses an `.obj` model and `.mtl` material library from bytes.
fn loadOBJFromBytes(allocator: std.mem.Allocator, obj_data: []const u8, mtl_data: []const u8) !OBJModel {
    const parsing_tz = ztracy.ZoneN(@src(), "loadOBJFromBytes");
    defer parsing_tz.End();

    _ = allocator;

    var attributes: c.tinyobj_attrib_t = undefined;

    var shapes: ?[*]c.tinyobj_shape_t = undefined;
    var num_shapes: usize = undefined;

    var materials: ?[*]c.tinyobj_material_t = undefined;
    var num_materials: usize = undefined;

    const FileReaderContext = struct { obj_data: []const u8, mtl_data: []const u8 };

    const file_reader = struct {
        /// Provide a callback that can read text file without any parsing or modification.
        pub fn f(
            /// User provided context.
            ctx: ?*anyopaque,
            /// Filename to be loaded, without a file extension.
            _: [*c]const u8,
            is_mtl: c_int,
            /// `.obj` filename. Useful when you load `.mtl` from same location of `.obj`.
            /// When the callback is called to load `.obj`, `filename` and `obj_filename` are same.
            _: [*c]const u8,
            /// Content of loaded file
            buf: [*c][*c]u8,
            /// Size of content(file)
            len: [*c]usize,
        ) callconv(.c) void {
            const ctx_: *const FileReaderContext = @ptrCast(@alignCast(ctx.?));
            var data = if (is_mtl == 1) ctx_.mtl_data else ctx_.obj_data;

            buf.* = @ptrCast(&data.ptr);
            len.* = data.len;
        }
    }.f;

    const ret = c.tinyobj_parse_obj(
        &attributes,
        &shapes,
        &num_shapes,
        &materials,
        &num_materials,
        null,
        file_reader,
        @constCast(@ptrCast(&FileReaderContext{ .obj_data = obj_data, .mtl_data = mtl_data })),
        0,
    );
    return switch (ret) {
        c.TINYOBJ_SUCCESS => unreachable,
        c.TINYOBJ_ERROR_EMPTY => error.TinyObjEmpty,
        c.TINYOBJ_ERROR_INVALID_PARAMETER => error.TinyObjInvalidParameter,
        c.TINYOBJ_ERROR_FILE_OPERATION => error.TinyObjFileOperation,
        else => unreachable,
    };
}

test "loadObjFromBytes" {
    _ = try loadOBJFromBytes(
        std.testing.allocator,
        @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.obj"),
        @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.mtl"),
    );
}
