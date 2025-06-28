const std = @import("std");

const zm = @import("zm");
const obj = @import("obj");

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
        gdn.debug("Loading model '{s}'...", .{name});

        // Parse the OBJ model and material data.
        var obj_model = try obj.parseObj(allocator, model_data);
        defer obj_model.deinit(allocator);
        var material_lib = try obj.parseMtl(allocator, material_lib_data);
        defer material_lib.deinit(allocator);

        // Allocate places for us to store our re-computed meshes.
        const meshes = try allocator.alloc(Mesh, obj_model.meshes.len);

        // The OBJ model gives us a flatten list of verticies that we need to
        // unflatten as well as so we can store additional data per vertex.
        const master_vertices = try allocator.alloc(gpu.VertexInput, obj_model.vertices.len / 3);
        for (master_vertices, 0..) |*vertex, i| {
            vertex.* = .{
                .position = .{ obj_model.vertices[i * 3], obj_model.vertices[i * 3 + 1], obj_model.vertices[i * 3 + 2] },
                .normal = undefined,
            };
        }

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
