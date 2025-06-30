const std = @import("std");

const zm = @import("zm");

const gpu = @import("gpu.zig");
const c = @import("ffi.zig").c;

const SDL = @import("ffi.zig").SDL;
const DynamicTransform = @import("transform.zig").DynamicTransform;

const FZ = @import("trace.zig").FnZone;

const IndexType = u32;

const log = std.log.scoped(.object);

pub const Model = struct {
    name: []const u8,
    transform: DynamicTransform,

    vertex_len: usize,
    vertex_buffer: SDL.GPUBuffer,
    meshes: []Mesh,

    // -- Types -- //

    pub const Mesh = struct {
        name: []const u8,
        material: gpu.Material,

        index_len: usize,
        index_buffer: SDL.GPUBuffer,

        fragment_normals_len: usize,
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
        var fz = FZ.init(@src(), "initFromEmbeddedObj");
        defer fz.end();

        log.debug("Loading model '{s}'...", .{name});

        // Parse the OBJ model and material data.
        fz.push(@src(), "parse model");
        var obj_model, var material_lib = try loadOBJFromBytesDeprecated(allocator, model_data, material_lib_data);
        defer obj_model.deinit(allocator);
        defer material_lib.deinit(allocator);

        // Allocate places for us to store our re-computed meshes.
        fz.replace(@src(), "alloc meshes");
        const meshes = try allocator.alloc(Mesh, obj_model.meshes.len);

        // The OBJ model gives us a flatten list of verticies that we need to
        // unflatten as well as so we can store additional data per vertex.
        fz.replace(@src(), "copy vert");
        const vertices = try allocator.alloc(gpu.VertexInput, obj_model.vertices.len / 3);
        const vertices_normal_mask = try allocator.alloc(bool, vertices.len);
        defer allocator.free(vertices);
        defer allocator.free(vertices_normal_mask);

        for (vertices, 0..) |*vertex, i| {
            vertex.* = .{
                .position = .{
                    obj_model.vertices[i * 3],
                    obj_model.vertices[i * 3 + 1],
                    obj_model.vertices[i * 3 + 2],
                },
                .normal = undefined,
            };
        }

        // Create our cmd, cpass, and tbuf.
        fz.replace(@src(), "create cmd, cpass, and tbuf");

        const cmd = try SDL.GPUCommandBuffer.acquire(device);
        const cpass = try SDL.GPUCopyPass.begin(&cmd);

        var max_tbuf_len = @sizeOf(gpu.VertexInput) * vertices.len;
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
        fz.replace(@src(), "copy meshes");
        for (obj_model.meshes, meshes, 0..) |*raw_mesh, *mesh, mesh_idx| {
            fz.push(@src(), "copy mesh");
            defer fz.pop();

            const mesh_name = raw_mesh.name orelse {
                log.err("Cannot load an unnamed mesh!", .{});
                return error.InvalidModel;
            };
            log.debug("Loading mesh '{s}' for model '{s}'.", .{ mesh_name, name });

            // Make sure we are able to render this model.
            {
                // Ensure we are loading a triangulated mesh.
                for (raw_mesh.num_vertices) |*n| if (n.* != 3) {
                    log.err("Cannot load a mesh with non-triangular faces!", .{});
                    return error.InvalidModel;
                };

                // TODO: Currently we only support one material per mesh.
                if (raw_mesh.materials.len > 1) {
                    log.err("TODO: Cannot load a mesh with multiple materials!", .{});
                    log.debug("The mesh uses the following materials: ", .{});
                    for (raw_mesh.materials, 0..) |m, i| log.debug("{}. {s}", .{ i, m.material });
                    return error.InvalidModel;
                }
            }

            fz.replace(@src(), "alloc vert & index");
            // Allocate enough space for our vertices and indices.
            const indices = try allocator.alloc(u32, raw_mesh.indices.len);
            defer allocator.free(indices);

            // Copy over all of the indices.
            fz.replace(@src(), "copy indices");
            for (raw_mesh.indices, indices) |*raw_index, *index| {
                const vertex_idx: usize = @intCast(raw_index.vertex orelse return error.InvalidModel);
                const normal_idx: usize = @intCast(raw_index.normal orelse return error.InvalidModel);

                if (!vertices_normal_mask[vertex_idx]) {
                    vertices[vertex_idx].normal = [_]f32{
                        obj_model.normals[normal_idx * 3],
                        obj_model.normals[normal_idx * 3 + 1],
                        obj_model.normals[normal_idx * 3 + 2],
                    };
                    vertices_normal_mask[vertex_idx] = true;
                }

                index.* = @intCast(vertex_idx);
            }

            // Calculate fragment normals for flat-shading.
            fz.replace(@src(), "calc frag norms");
            const fragment_normals = outer: {
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
            fz.replace(@src(), "mesh mat");
            const material = if (raw_mesh.materials.len > 0) outer: {
                const raw_material = material_lib.materials.getPtr(raw_mesh.materials[0].material) orelse {
                    log.err("Failed to load material '{s}' from material library!", .{raw_mesh.materials[0].material});
                    return error.InvalidMaterial;
                };
                log.debug("Converting raw material '{s}': {}", .{ raw_mesh.materials[0].material, raw_material });

                const material = gpu.Material{};

                log.debug("Loaded material '{s}': {}", .{ raw_mesh.materials[0].material, material });
                break :outer material;
            } else gpu.Material{};

            // Create our and upload data to our buffers.
            fz.replace(@src(), "upload data");

            const index_buffer = try cpass.createAndUploadDataToBuffer(
                allocator,
                device,
                &tbuf,
                IndexType,
                indices,
                "Mesh Index Buffer",
                c.SDL_GPU_BUFFERUSAGE_INDEX,
            );
            const fragment_normals_buffer = try cpass.createAndUploadDataToBuffer(
                allocator,
                device,
                &tbuf,
                [4]f32,
                fragment_normals,
                "Mesh Fragment Normals Buffer",
                c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            );

            mesh.* = .{
                .name = try allocator.dupe(u8, mesh_name),
                .material = material,
                .index_len = indices.len,
                .index_buffer = index_buffer,
                .fragment_normals_len = fragment_normals.len,
                .fragment_normals_buffer = fragment_normals_buffer,
            };

            log.debug("Loaded mesh '{s}' with {} verticies and {} indices.", .{
                meshes[mesh_idx].name,
                vertices.len,
                indices.len,
            });
        }

        // Upload our vertices.
        fz.replace(@src(), "upload vertices");
        const vertex_buffer: SDL.GPUBuffer = try cpass.createAndUploadDataToBuffer(
            allocator,
            device,
            &tbuf,
            gpu.VertexInput,
            vertices,
            "Mesh Vertex Buffer",
            c.SDL_GPU_BUFFERUSAGE_VERTEX,
        );

        fz.replace(@src(), "submit cpass");
        cpass.end();
        try cmd.submit();

        log.info("Loaded model '{s}'.", .{name});
        return Model{
            .name = name,
            .transform = transform,
            .vertex_len = vertices.len,
            .vertex_buffer = vertex_buffer,
            .meshes = meshes,
        };
    }

    // -- Deinitialization -- //

    pub fn deinit(model: *Model, device: *const SDL.GPUDevice) void {
        // TODO: Deallocate everything so we don't need to use an arena.
        model.vertex_buffer.release(device);
        for (model.meshes) |*mesh| {
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
        var fz = FZ.init(@src(), "Model.draw");
        defer fz.end();

        // Calculate the model and inverse transposed normal matricies.
        fz.push(@src(), "calc matrices");
        const model_matrix = model.transform.modelMatrix();
        const normal_matrix = model_matrix.inverse().transpose();

        const pmvd = gpu.PerMeshVertexData{
            .model = model_matrix.data,
            .normalMat = normal_matrix.data,
        };

        // Render each mesh with the proper material properties.
        fz.replace(@src(), "bind vertex buf");
        try rpass.bindBuffer(gpu.VertexInput, .Vertex, 0, &model.vertex_buffer, 0);

        fz.replace(@src(), "draw meshes");
        for (model.meshes) |*mesh| {
            fz.push(@src(), "draw mesh");
            defer fz.pop();

            const pmfd = gpu.PerMeshFragmentData{
                .normalMat = normal_matrix.data,
                .material = mesh.material,
            };

            // Bind our uniforms and storage buffers.
            fz.replace(@src(), "bind");
            try gpu.Bindings.PER_MESH_VERTEX_DATA.bind(cmd, &pmvd);
            try gpu.Bindings.PER_MESH_FRAGMENT_DATA.bind(cmd, &pmfd);
            try gpu.Bindings.FRAGMENT_NORMALS.bind(rpass, &mesh.fragment_normals_buffer, 0);

            // Bind our vertex and index buffers.
            try rpass.bindBuffer(IndexType, .Index, 0, &mesh.index_buffer, 0);

            // Push a render call to the pass.
            fz.replace(@src(), "draw");
            rpass.drawIndexedPrimitives(@intCast(mesh.index_len), 1, 0, 0, 0);
        }
    }
};

// -- Helper Functions -- //

const obj = @import("obj");

const OBJModelDeprecated = struct { obj.ObjData, obj.MaterialData };

/// Parses an `.obj` model and `.mtl` material library from bytes.
fn loadOBJFromBytesDeprecated(allocator: std.mem.Allocator, obj_data: []const u8, mtl_data: []const u8) !OBJModelDeprecated {
    var fz = FZ.init(@src(), "loadOBJFromBytesDeprecated");
    defer fz.end();

    return .{ try obj.parseObj(allocator, obj_data), try obj.parseMtl(allocator, mtl_data) };
}

const OBJModel = struct {};

const FileReaderContext = struct { obj_data: []const u8, mtl_data: []const u8 };
export fn tinyobj_file_reader_callback(
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
    const data = if (is_mtl == 1) ctx_.mtl_data else ctx_.obj_data;

    buf.* = @constCast(@ptrCast(data.ptr));
    len.* = data.len;
}

/// Parses an `.obj` model and `.mtl` material library from bytes.
fn loadOBJFromBytes(allocator: std.mem.Allocator, obj_data: []const u8, mtl_data: []const u8) !OBJModel {
    var fz = FZ.init(@src(), "loadOBJFromBytes");
    defer fz.end();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var attrib: c.tinyobj_attrib_t = undefined;
    var shapes: [*c]c.tinyobj_shape_t = null;
    var num_shapes: usize = undefined;
    var materials: [*c]c.tinyobj_shape_t = null;
    var num_materials: usize = undefined;

    const flags = c.TINYOBJ_FLAG_TRIANGULATE;

    const ret = c.tinyobj_parse_obj(
        &attrib,
        &shapes,
        &num_shapes,
        &materials,
        &num_materials,
        "<unused filename>",
        tinyobj_file_reader_callback,
        @constCast(@ptrCast(&FileReaderContext{ .obj_data = obj_data, .mtl_data = mtl_data })),
        flags,
    );

    log.debug("`tinyobj_parse_obj` returned {}.", .{ret});

    return switch (ret) {
        c.TINYOBJ_SUCCESS => outer: {
            log.debug("Successfully parsed .obj model!", .{});
            log.debug("Model Attributes: {}", .{attrib});
            log.debug("Vertices: {any}", .{attrib.vertices[0..attrib.num_vertices]});
            break :outer error.Success;
        },
        c.TINYOBJ_ERROR_EMPTY => error.TinyObjEmpty,
        c.TINYOBJ_ERROR_INVALID_PARAMETER => error.TinyObjInvalidParameter,
        c.TINYOBJ_ERROR_FILE_OPERATION => error.TinyObjFileOperation,
        else => unreachable,
    };
}

test "loadObjFromBytes" {
    const @"cube.obj" =
        \\ # https://gist.github.com/noonat/1131091
        \\ # cube.obj
        \\ #
        \\ 
        \\ o cube
        \\ mtllib cube.mtl
        \\ 
        \\ v -0.500000 -0.500000 0.500000
        \\ v 0.500000 -0.500000 0.500000
        \\ v -0.500000 0.500000 0.500000
        \\ v 0.500000 0.500000 0.500000
        \\ v -0.500000 0.500000 -0.500000
        \\ v 0.500000 0.500000 -0.500000
        \\ v -0.500000 -0.500000 -0.500000
        \\ v 0.500000 -0.500000 -0.500000
        \\ 
        \\ vt 0.000000 0.000000
        \\ vt 1.000000 0.000000
        \\ vt 0.000000 1.000000
        \\ vt 1.000000 1.000000
        \\ 
        \\ vn 0.000000 0.000000 1.000000
        \\ vn 0.000000 1.000000 0.000000
        \\ vn 0.000000 0.000000 -1.000000
        \\ vn 0.000000 -1.000000 0.000000
        \\ vn 1.000000 0.000000 0.000000
        \\ vn -1.000000 0.000000 0.000000
        \\ 
        \\ g cube
        \\ usemtl cube
        \\ s 1
        \\ f 1/1/1 2/2/1 3/3/1
        \\ f 3/3/1 2/2/1 4/4/1
        \\ s 2
        \\ f 3/1/2 4/2/2 5/3/2
        \\ f 5/3/2 4/2/2 6/4/2
        \\ s 3
        \\ f 5/4/3 6/3/3 7/2/3
        \\ f 7/2/3 6/3/3 8/1/3
        \\ s 4
        \\ f 7/1/4 8/2/4 1/3/4
        \\ f 1/3/4 8/2/4 2/4/4
        \\ s 5
        \\ f 2/1/5 8/2/5 4/3/5
        \\ f 4/3/5 8/2/5 6/4/5
        \\ s 6
        \\ f 7/1/6 1/2/6 5/3/6
        \\ f 5/3/6 1/2/6 3/4/6
    ;

    const @"cube.mtl" =
        \\ newmtl cube
        \\ Ns 10.0000
        \\ Ni 1.5000
        \\ d 1.0000
        \\ Tr 0.0000
        \\ Tf 1.0000 1.0000 1.0000 
        \\ illum 2
        \\ Ka 0.0000 0.0000 0.0000
        \\ Kd 0.5880 0.5880 0.5880
        \\ Ks 0.0000 0.0000 0.0000
        \\ Ke 0.0000 0.0000 0.0000
        // \\ map_Ka cube.png
        // \\ map_Kd cube.png
    ;

    _ = loadOBJFromBytes(
        std.testing.allocator,
        @"cube.obj",
        @"cube.mtl",
    ) catch |e| {
        std.debug.print("Error: {}\n", .{e});
        return;
    };
}
