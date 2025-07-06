const std = @import("std");

const zm = @import("zm");
const img = @import("img");

const gpu = @import("gpu.zig");
const trace = @import("trace.zig");
const c = @import("ffi.zig").c;

const SDL = @import("ffi.zig").SDL;
const DynamicTransform = @import("transform.zig").DynamicTransform;

const FZ = trace.FnZone;
const Image = img.Image;

const MAX_U32 = std.math.maxInt(u32);

const log = std.log.scoped(.object);

pub const Model = struct {
    allocator: std.mem.Allocator,

    name: []const u8,
    transform: DynamicTransform,

    vertex_len: usize,
    vertex_buffer: SDL.GPUBuffer,
    meshes: []Mesh,

    sampler: SDL.GPUSampler,

    // -- Types -- //

    pub const Mesh = struct {
        name: []const u8,
        material: Material,

        face_count: usize,
        index_buffer: SDL.GPUBuffer,

        fragment_normals_len: usize,
        fragment_normals_buffer: SDL.GPUBuffer,
    };

    pub const Material = struct {
        gpu: gpu.Material,
        textures: std.AutoHashMap(MapType, SDL.GPUTexture),

        pub const MapType = enum {
            Diffuse,
        };
    };

    // -- Initialization -- //

    /// Initializes a `Model` from an embedded `.obj` model and `.mtl` material library.
    pub fn initFromObjFile(
        allocator: std.mem.Allocator,
        device: *const SDL.GPUDevice,
        name: []const u8,
        transform: DynamicTransform,
        model_path: []const u8,
        material_lib_path: []const u8,
        textures: std.StringHashMap(Image),
    ) !Model {
        var fz = FZ.init(@src(), "initFromEmbeddedObj");
        defer fz.end();

        log.debug("Loading model '{s}'...", .{name});

        // Parse the OBJ model and material data.
        fz.push(@src(), "read model");
        const model_data = try std.fs.cwd().readFileAlloc(allocator, model_path, std.math.maxInt(usize));
        const material_lib_data = try std.fs.cwd().readFileAlloc(allocator, material_lib_path, std.math.maxInt(usize));

        fz.replace(@src(), "parse model");
        const model = try TinjObjLoader.loadFromBytes(allocator, name, model_data, material_lib_data);
        defer model.deinit(allocator);

        allocator.free(model_data);
        allocator.free(material_lib_data);

        log.debug("Loaded model '{s}' with {} vertices, {} normals, and {} texcoords.", .{
            name,
            model.vertices.len,
            model.normals.len,
            model.texcoords.len,
        });

        // Allocate places for us to store our re-computed meshes.
        fz.replace(@src(), "alloc meshes");
        const meshes = try allocator.alloc(Mesh, model.meshes.len);

        // The OBJ model gives us a flatten list of verticies that we need to
        // unflatten as well as so we can store additional data per vertex.
        fz.replace(@src(), "copy vert");
        const vertices = try allocator.alloc(gpu.VertexInput, model.vertices.len);
        defer allocator.free(vertices);

        for (vertices, 0..) |*vertex, i| {
            vertex.* = .{
                .position = model.vertices[i],
                .normal = model.normals[i],
                .texcoord = model.texcoords[i],
            };
        }

        // Create our cmd, cpass, and tbuf.
        fz.replace(@src(), "create cmd, cpass, and tbuf");

        const cmd = try SDL.GPUCommandBuffer.acquire(device);
        const cpass = try SDL.GPUCopyPass.begin(&cmd);

        var max_tbuf_len = @sizeOf(gpu.VertexInput) * vertices.len;
        for (model.meshes) |*mesh| {
            max_tbuf_len = @max(
                mesh.indices.len * @sizeOf([4]f32),
                max_tbuf_len,
            );
        }

        {
            var tex_iter = textures.valueIterator();
            while (tex_iter.next()) |v| {
                try v.convert(.rgba32);
                max_tbuf_len = @max(
                    v.imageByteSize(),
                    max_tbuf_len,
                );
            }
        }

        const tbuf: SDL.GPUTransferBuffer(.Upload) = try .create(
            allocator,
            device,
            max_tbuf_len,
            "Model Upload Buffer",
        );
        defer tbuf.release(device);

        // Additionally, these vertices are common for all meshes so clone them
        // per `Mesh`.
        fz.replace(@src(), "copy meshes");
        for (model.meshes, meshes, 0..) |*raw_mesh, *mesh, mesh_idx| {
            fz.push(@src(), "copy mesh");
            defer fz.pop();

            const mesh_name = raw_mesh.name orelse {
                log.err("Meshes must be named!", .{});
                return error.InvalidModel;
            };

            fz.replace(@src(), "copy indices");
            // Allocate enough space for our indices.
            const indices = try allocator.dupe([3]u32, raw_mesh.indices);
            defer allocator.free(indices);

            // Calculate fragment normals for flat-shading.
            fz.replace(@src(), "calc frag norms");
            const fragment_normals = outer: {
                const fragment_normals_data = try allocator.alloc([4]f32, indices.len);

                for (0..indices.len) |idx| {
                    const index = indices[idx];
                    const v0: zm.Vec3f = vertices[index[0]].position;
                    const v1: zm.Vec3f = vertices[index[1]].position;
                    const v2: zm.Vec3f = vertices[index[2]].position;
                    const normal = zm.vec.normalize(zm.vec.cross(v1 - v0, v2 - v0));
                    fragment_normals_data[idx] = .{ normal[0], normal[1], normal[2], 0 };
                }

                break :outer fragment_normals_data;
            };

            // Create our and upload data to our buffers.
            fz.replace(@src(), "upload data");

            const index_buffer = try SDL.GPUBuffer.createAndUploadData(
                &cpass,
                allocator,
                device,
                &tbuf,
                u32,
                @ptrCast(indices),
                "Mesh Index Buffer",
                c.SDL_GPU_BUFFERUSAGE_INDEX,
            );
            const fragment_normals_buffer = try SDL.GPUBuffer.createAndUploadData(
                &cpass,
                allocator,
                device,
                &tbuf,
                [4]f32,
                fragment_normals,
                "Mesh Fragment Normals Buffer",
                c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            );

            fz.replace(@src(), "create material and load textures");
            var material = Material{
                .gpu = gpu.Material{
                    .ambientColor = raw_mesh.material.diffuse,
                    .diffuseColor = raw_mesh.material.diffuse,
                    .specularColor = raw_mesh.material.diffuse,
                    .specularExponent = raw_mesh.material.shininess,
                },
                .textures = .init(allocator),
            };
            {
                const image = outer: {
                    if (raw_mesh.material.diffuse_texname != null) {
                        const file = std.fs.path.basename(std.mem.span(raw_mesh.material.diffuse_texname));
                        log.debug("Loading diffuse map: {s}", .{file});
                        if (textures.getPtr(file)) |f| break :outer f;
                    }

                    const pixels: [4]f32 = .{
                        raw_mesh.material.diffuse[0],
                        raw_mesh.material.diffuse[1],
                        raw_mesh.material.diffuse[2],
                        1.0,
                    };
                    var image = try Image.fromRawPixels(allocator, 1, 1, @ptrCast(&pixels), .float32);
                    try image.convert(.rgba32);
                    break :outer &image;
                };

                const diffuse_map = try SDL.GPUTexture.createAndUploadImage(
                    &cpass,
                    allocator,
                    device,
                    &tbuf,
                    image,
                    "Diffuse Texture",
                );
                try material.textures.put(.Diffuse, diffuse_map);
            }
            mesh.* = .{
                .name = try allocator.dupe(u8, mesh_name),
                .material = material,
                .face_count = indices.len,
                .index_buffer = index_buffer,
                .fragment_normals_len = fragment_normals.len,
                .fragment_normals_buffer = fragment_normals_buffer,
            };

            log.debug("Loaded mesh '{s}' with {} indices.", .{
                meshes[mesh_idx].name,
                indices.len,
            });
        }

        // Upload our vertices.
        fz.replace(@src(), "upload vertices");
        const vertex_buffer: SDL.GPUBuffer = try SDL.GPUBuffer.createAndUploadData(
            &cpass,
            allocator,
            device,
            &tbuf,
            gpu.VertexInput,
            vertices,
            "Mesh Vertex Buffer",
            c.SDL_GPU_BUFFERUSAGE_VERTEX,
        );

        // Create our texture sampler.
        // TODO: Adjust the properties to work in _most_ cases or expose the configuration.
        fz.replace(@src(), "create sampler");
        const sampler = try SDL.GPUSampler.create(allocator, device, "Texture Sampler", .{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        });

        fz.replace(@src(), "submit cpass");
        cpass.end();
        try cmd.submit();

        log.info("Loaded model '{s}'.", .{name});
        return Model{
            .allocator = allocator,
            .name = name,
            .transform = transform,
            .vertex_len = vertices.len,
            .vertex_buffer = vertex_buffer,
            .meshes = meshes,
            .sampler = sampler,
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
                .material = mesh.material.gpu,
            };

            // Bind our uniforms and storage buffers.
            fz.replace(@src(), "bind");
            try gpu.Bindings.PER_MESH_VERTEX_DATA.bind(cmd, &pmvd);
            try gpu.Bindings.PER_MESH_FRAGMENT_DATA.bind(cmd, &pmfd);
            try gpu.Bindings.FRAGMENT_NORMALS.bind(rpass, &mesh.fragment_normals_buffer, 0);

            // Bind textures.
            gpu.Bindings.DIFFUSE_MAP.bind(rpass, mesh.material.textures.getPtr(.Diffuse).?, &model.sampler);

            // Bind our vertex and index buffers.
            try rpass.bindBuffer(u32, .Index, 0, &mesh.index_buffer, 0);

            // Push a render call to the pass.
            fz.replace(@src(), "draw");
            rpass.drawIndexedPrimitives(@intCast(mesh.face_count * 3), 1, 0, 0, 0);
        }
    }
};

// -- OBJ Loading -- //
// TODO: Rewrite to be pure zig.

const obj = @import("obj");

const OBJModelDeprecated = struct { obj.ObjData, obj.MaterialData };

/// Parses an `.obj` model and `.mtl` material library from bytes.
fn loadOBJFromBytesDeprecated(allocator: std.mem.Allocator, obj_data: []const u8, mtl_data: []const u8) !OBJModelDeprecated {
    var fz = FZ.init(@src(), "loadOBJFromBytesDeprecated");
    defer fz.end();

    return .{ try obj.parseObj(allocator, obj_data), try obj.parseMtl(allocator, mtl_data) };
}

const OBJModel = struct {
    vertices: [][3]f32,
    normals: [][3]f32,
    texcoords: [][2]f32,
    meshes: []Mesh,
    __raw_materials: []c.tinyobj_material_t,

    pub const Mesh = struct {
        name: ?[]const u8 = null,
        indices: [][3]u32,
        material: c.tinyobj_material_t,
    };

    pub fn deinit(model: *const OBJModel, allocator: std.mem.Allocator) void {
        allocator.free(model.vertices);
        allocator.free(model.normals);
        allocator.free(model.texcoords);
        for (model.meshes) |*mesh| {
            if (mesh.name) |n| allocator.free(n);
            allocator.free(mesh.indices);
        }
        allocator.free(model.meshes);
    }
};

pub fn embedTextureMap(allocator: std.mem.Allocator, comptime root: []const u8, comptime files: []const []const u8) !std.StringHashMap(Image) {
    var map = std.StringHashMap(Image).init(allocator);
    inline for (files) |file| {
        const contents = try std.fs.cwd().readFileAlloc(allocator, root ++ std.fs.path.sep_str ++ file, std.math.maxInt(usize));
        defer allocator.free(contents);

        var image = try Image.fromMemory(allocator, contents);
        try image.convert(.rgba32);
        try map.put(file, image);
    }
    return map;
}

const TinjObjLoader = struct {
    // -- (Safe) Types -- //

    /// Models are required to be triangulated.
    const Attributes = struct {
        /// (x, y, z)
        vertices: [][3]f32,
        /// (n_x, n_y, n_z)
        normals: [][3]f32,
        /// (t_x, t_y)
        texcoords: [][2]f32,
        /// For each face, [i_0, i_1, ..., i_n] where n is the number of indices for that face.
        face_vertex_indices: [][3]u32,
        /// For each face, [i_0, i_1, ..., i_n] where n is the number of indices for that face.
        face_normal_indices: [][3]u32,
        /// For each face, [i_0, i_1, ..., i_n] where n is the number of indices for that face.
        face_texcoord_indices: [][3]u32,
        /// One material per face.
        face_material_ids: []u32,

        pub fn deinit(attributes: *const Attributes, allocator: std.mem.Allocator) void {
            allocator.free(attributes.vertices);
            allocator.free(attributes.normals);
            allocator.free(attributes.texcoords);
            allocator.free(attributes.face_vertex_indices);
            allocator.free(attributes.face_normal_indices);
            allocator.free(attributes.face_texcoord_indices);
            allocator.free(attributes.face_material_ids);
        }

        pub fn fromRaw(allocator: std.mem.Allocator, raw: *const c.tinyobj_attrib_t) !Attributes {
            var fz = FZ.init(@src(), "TinyObjLoader.Attributes.fromRaw");
            defer fz.end();

            var self: Attributes = undefined;

            // Copy vertices, normals, and texture coordinates into grouped arrays.
            fz.push(@src(), "copy data");

            // TODO:
            // Is there any way for me to clean up this memory without the help
            // of tinyobj (#define TINYOBJ_MALLOC)? I could keep this slice but
            // then I couldn't free it properly with a zig allocator; granted
            // any interop with FFI undermines that expectation.
            // NOTE: These are beautiful lines imo
            self.vertices = try allocator.dupe([3]f32, @ptrCast(raw.vertices[0 .. raw.num_vertices * 3]));
            self.normals = try allocator.dupe([3]f32, @ptrCast(raw.normals[0 .. raw.num_normals * 3]));
            self.texcoords = try allocator.dupe([2]f32, @ptrCast(raw.texcoords[0 .. raw.num_texcoords * 2]));

            // For each face, group the respective indices.
            const faces: [][3]c.tinyobj_vertex_index_t = @ptrCast(raw.faces[0..raw.num_faces]);

            fz.replace(@src(), "copy indices");

            self.face_vertex_indices = try allocator.alloc([3]u32, faces.len);
            self.face_normal_indices = try allocator.alloc([3]u32, faces.len);
            self.face_texcoord_indices = try allocator.alloc([3]u32, faces.len);
            self.face_material_ids = try allocator.alloc(u32, faces.len);

            // TODO: Chunk the data to process in parallel.
            for (
                faces,
                self.face_vertex_indices,
                self.face_normal_indices,
                self.face_texcoord_indices,
                self.face_material_ids,
                0..,
            ) |*indices, *v, *n, *t, *m, i| {
                for (0..3) |j| {
                    if (indices[j].v_idx == c.TINYOBJ_INVALID_INDEX or indices[j].v_idx < 0 or
                        indices[j].vn_idx == c.TINYOBJ_INVALID_INDEX or indices[j].vn_idx < 0 or
                        indices[j].vt_idx == c.TINYOBJ_INVALID_INDEX or indices[j].vt_idx < 0)
                    {
                        log.warn("TODO: Index {} contains an invalid or negative index!", .{i * 3 + j});
                    }

                    v.*[j] = @intCast(indices[j].v_idx);
                    n.*[j] = @intCast(indices[j].vn_idx);
                    t.*[j] = @intCast(indices[j].vt_idx);
                }
                m.* = @intCast(raw.material_ids[i]);
            }

            return self;
        }
    };

    // -- File Readers -- //

    const PassthroughFileReaderContext = struct { obj_data: []const u8, mtl_data: []const u8 };

    /// Outputs the data passed in through `ctx`.
    export fn passthroughFileReader(
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
        const ctx_: *const PassthroughFileReaderContext = @ptrCast(@alignCast(ctx.?));
        const data = if (is_mtl == 1) ctx_.mtl_data else ctx_.obj_data;

        buf.* = @constCast(@ptrCast(data.ptr));
        len.* = data.len;
    }

    // -- Loader -- //

    /// Parses an `.obj` model and `.mtl` material library from bytes.
    fn loadFromBytes(allocator: std.mem.Allocator, name: []const u8, raw_obj_data: []const u8, mtl_data: []const u8) !OBJModel {
        var fz = FZ.init(@src(), "TinjObjLoader.loadFromBytes");
        defer fz.end();

        // Remove all non-face geometry elements (currently only lines).
        const obj_data = try allocator.alloc(u8, raw_obj_data.len + 1);
        defer allocator.free(obj_data);
        {
            var i: usize = 0;
            var line_idx: usize = 0;
            var lines = std.mem.splitScalar(u8, raw_obj_data, '\n');
            while (lines.next()) |line| : (line_idx += 1) {
                if (std.mem.startsWith(u8, line, "l")) {
                    log.debug(
                        "Model contains polyline on line {}; this is not currently supported and will be filtered out.",
                        .{line_idx},
                    );
                    continue;
                } // Polylines
                @memcpy(obj_data[i .. i + line.len], line);
                obj_data[i + line.len] = '\n';
                i += line.len + 1;
            }
        }

        // Parse the model and material library.
        const parsing_start = std.time.milliTimestamp();
        const attributes: Attributes, const shapes: []c.tinyobj_shape_t, const materials: []c.tinyobj_material_t = outer: {
            fz.push(@src(), "parsing");
            var attrib: c.tinyobj_attrib_t = undefined;
            defer c.tinyobj_attrib_free(&attrib);
            var shapes: [*c]c.tinyobj_shape_t = null;
            var num_shapes: usize = undefined;
            var materials: [*c]c.tinyobj_material_t = null;
            var num_materials: usize = undefined;

            const flags = c.TINYOBJ_FLAG_TRIANGULATE;

            const ret = c.tinyobj_parse_obj(
                &attrib,
                &shapes,
                &num_shapes,
                &materials,
                &num_materials,
                "<unused filename>",
                passthroughFileReader,
                @constCast(@ptrCast(&PassthroughFileReaderContext{ .obj_data = obj_data, .mtl_data = mtl_data })),
                flags,
            );

            switch (ret) {
                c.TINYOBJ_SUCCESS => {},
                c.TINYOBJ_ERROR_EMPTY => return error.TinyObjEmpty,
                c.TINYOBJ_ERROR_INVALID_PARAMETER => return error.TinyObjInvalidParameter,
                c.TINYOBJ_ERROR_FILE_OPERATION => return error.TinyObjFileOperation,
                else => unreachable,
            }

            fz.replace(@src(), "safety-ing");
            break :outer .{ try Attributes.fromRaw(allocator, &attrib), shapes[0..num_shapes], materials[0..num_materials] };
        };
        defer attributes.deinit(allocator);
        defer c.tinyobj_shapes_free(shapes.ptr, shapes.len);

        log.debug(
            "Parsed .obj model '{s}' in {} ms ({} vertices, {} faces, {} normals, {} texcoords).",
            .{
                name,
                std.time.milliTimestamp() - parsing_start,
                attributes.vertices.len,
                attributes.face_vertex_indices.len,
                attributes.normals.len,
                attributes.texcoords.len,
            },
        );

        // Copy the data to the proper places.
        fz.replace(@src(), "copy data");

        // TODO: This is unnecessary but allows for easier deinitialization.
        const vertices = try allocator.dupe([3]f32, attributes.vertices);

        const normals = try allocator.alloc([3]f32, vertices.len);
        const texcoords = try allocator.alloc([2]f32, vertices.len);
        const vertices_normal_mask = try allocator.alloc(bool, normals.len);
        defer allocator.free(vertices_normal_mask);

        const meshes = try allocator.alloc(OBJModel.Mesh, shapes.len);

        for (meshes, shapes) |*mesh, *shape| {
            fz.push(@src(), "copy indices");
            defer fz.pop();

            if (shape.name != null) mesh.name = try allocator.dupe(u8, std.mem.span(shape.name));

            const offset = shape.face_offset;
            mesh.indices = try allocator.dupe([3]u32, attributes.face_vertex_indices[offset .. offset + shape.length]);

            // TODO: We are _only_ using the material of the first face in this shape.
            const material = materials[@intCast(attributes.face_material_ids[offset])];
            mesh.material = material;

            for (
                mesh.indices,
                attributes.face_normal_indices[offset .. offset + shape.length],
                attributes.face_texcoord_indices[offset .. offset + shape.length],
            ) |v_idx, vn_idx, vt_idx| {
                for (0..3) |i| {
                    if (!vertices_normal_mask[v_idx[i]]) {
                        normals[v_idx[i]] = attributes.normals[vn_idx[i]];
                        texcoords[v_idx[i]] = attributes.texcoords[vt_idx[i]];
                        vertices_normal_mask[v_idx[i]] = true;
                    }
                }
            }
        }

        return OBJModel{ .vertices = vertices, .normals = normals, .texcoords = texcoords, .__raw_materials = materials, .meshes = meshes };
    }
};

test "TinjObjLoader.loadFromBytes" {
    const obj_data = @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.obj");
    const mtl_data = @embedFile("assets/models/2021-Lamborghini-Countac [Lexyc16]/Countac.mtl");

    const model = TinjObjLoader.loadFromBytes(std.testing.allocator, "Lambo", obj_data, mtl_data) catch |e| {
        std.debug.print("Error: {}\n", .{e});
        return;
    };
    defer model.deinit(std.testing.allocator);
}
