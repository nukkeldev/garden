const std = @import("std");
const sokol = @import("sokol");

var dep_sokol: *std.Build.Dependency = undefined;

pub fn build(b: *std.Build) void {
    // Options

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Executable

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "graphics",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Dependencies

    dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dynamic_linkage = false,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    exe_mod.addImport("sokol", dep_sokol.module("sokol"));
    exe_mod.addImport("cimgui", dep_cimgui.module("cimgui"));

    const build_shaders = b.step("build-shaders", "Builds all of the shaders.");
    build_shaders.* = std.Build.Step.init(.{
        .id = build_shaders.id,
        .name = build_shaders.name,
        .owner = build_shaders.owner,
        .makeFn = buildShaders,
    });

    exe.step.dependOn(build_shaders);

    // Command: run

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Command: test

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

/// Builds all GLSL shaders in the `src/shaders` directory.
fn buildShaders(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const alloc = b.allocator;
    _ = options;

    // Open shaders and built-shaders directories.
    var source_dir = try std.fs.cwd().openDir("src/shaders", .{ .iterate = true });
    var built_dir = try std.fs.cwd().openDir("src/shaders/build", .{});
    defer source_dir.close();
    defer built_dir.close();

    // Iterate through all of the items in the directory.
    var entries = source_dir.iterate();
    while (try entries.next()) |item| {
        // Filter only for shader files.
        if (item.kind != std.fs.File.Kind.file or !std.mem.endsWith(u8, item.name, ".glsl")) continue;

        // Open the source file.
        const source = try source_dir.openFile(item.name, .{});
        defer source.close();

        // Check if the built file exists.
        const opt_built: ?std.fs.File = built_dir.openFile(try std.mem.concat(alloc, u8, &[_][]const u8{ item.name, ".zig" }), .{ .mode = .read_write }) catch |e| b: {
            switch (e) {
                error.FileNotFound => {
                    // File has not been built before and therefore needs to be built.
                    break :b null;
                },
                else => return e,
            }
        };

        var needs_to_be_built = true;
        if (opt_built) |built| {
            // Read the contents of the source and built files.
            const source_contents = try source.readToEndAlloc(alloc, std.math.maxInt(usize));
            const built_contents = try built.readToEndAlloc(alloc, std.math.maxInt(usize));

            // Compute the MD5 hash of the shader's contents.
            const Md5 = std.crypto.hash.Md5;
            var hash: [Md5.digest_length]u8 = undefined;
            Md5.hash(source_contents, &hash, .{});

            var hash_str: [Md5.digest_length * 2]u8 = undefined;
            for (0..hash.len) |i| {
                _ = try std.fmt.bufPrint(hash_str[2 * i .. 2 * i + 2], "{x:0<2}", .{hash[i]});
            }

            // Read the previous hash.
            const last_hash_str = b: {
                if (std.mem.lastIndexOf(u8, built_contents, "// HASH: ")) |start| {
                    break :b built_contents[start + 9 .. std.mem.indexOfScalarPos(u8, built_contents, start, '\n') orelse source_contents.len];
                }
                break :b built_contents[0..0];
            };

            // Don't compile if the source hasn't changed.
            if (std.mem.eql(u8, last_hash_str, &hash_str)) {
                std.debug.print("{s} has an equivalent hash, skipping...\n", .{item.name});
                needs_to_be_built = false;
            } else {
                std.debug.print("{s} source has changed, recompiling...\n", .{item.name});
            }

            built.close();
        }

        // If the file needs to be built then build it.
        if (needs_to_be_built) {
            // Set the input and output file paths.
            const input_path = b.fmt("src/shaders/{s}", .{item.name});
            const output_path = b.fmt("src/shaders/build/{s}.zig", .{item.name});

            // Create the compilation command.
            const compile: *std.Build.Step = &(try sokol.shdc.compile(b, .{
                .dep_shdc = dep_sokol.builder.dependency("shdc", .{}),
                .input = b.path(input_path),
                .output = b.path(output_path),
                .slang = .{
                    .glsl430 = false,
                    .glsl410 = true,
                    .glsl310es = false,
                    .glsl300es = true,
                    .metal_macos = true,
                    .hlsl5 = true,
                    .wgsl = true,
                },
                .reflection = true,
            })).step;

            // Run the compilation command.
            try compile.make(.{ .progress_node = undefined, .thread_pool = undefined, .watch = false });

            // Post-process the built file.
            try postProcessShader(alloc, item.name);
        }
    }
}

fn postProcessShader(alloc: std.mem.Allocator, file_name: []const u8) !void {
    const InputType = enum {
        vec3,
        vec4,

        const Self = @This();

        pub fn tagged(name: []const u8) ?Self {
            inline for (@typeInfo(Self).@"enum".fields) |field| {
                if (std.mem.eql(u8, name, field.name)) return @field(Self, field.name);
            }

            return null;
        }

        pub fn getVertexFormat(self: Self) []const u8 {
            return switch (self) {
                .vec3 => "FLOAT3",
                .vec4 => "FLOAT4",
            };
        }
    };

    // Function Templates

    const TEMPLATE_GetVertexLayoutState = struct {
        const pre =
            \\pub fn {s}GetVertexLayoutState() sg.VertexLayoutState {{
            \\    var state: sg.VertexLayoutState = .{{}};
            \\
        ;
        const repr =
            \\    state.attrs[ATTR_{s}_{s}].format = .{s};
            \\
        ;
        const post =
            \\    return state;
            \\}}
            \\
        ;
    };

    const TEMPLATE_GetPipelineDesc =
        \\pub fn {s}GetPipelineDesc(desc: sg.PipelineDesc) sg.PipelineDesc {{
        \\    var desc_ = desc;
        \\    desc_.shader = sg.makeShader({s}ShaderDesc(sg.queryBackend()));
        \\    desc_.layout = {s}GetVertexLayoutState();
        \\    return desc_;
        \\}}
        \\
    ;

    // ---

    // Open shaders and built-shaders directories.
    var source_dir = try std.fs.cwd().openDir("src/shaders", .{ .iterate = true });
    var built_dir = try std.fs.cwd().openDir("src/shaders/build", .{});
    defer source_dir.close();
    defer built_dir.close();

    // Open the source file for reading.
    const source = try source_dir.openFile(file_name, .{});
    defer source.close();

    // Open the built file for reading and writing.
    const built = try built_dir.openFile(try std.mem.concat(alloc, u8, &[_][]const u8{ file_name, ".zig" }), .{ .mode = .read_write });
    defer built.close();

    // Read the contents of the source file.
    const source_contents = try source.readToEndAlloc(alloc, std.math.maxInt(usize));

    // Compute the MD5 hash of the shader's contents (again).
    const Md5 = std.crypto.hash.Md5;
    var hash: [Md5.digest_length]u8 = undefined;
    Md5.hash(source_contents, &hash, .{});

    var hash_str: [Md5.digest_length * 2]u8 = undefined;
    for (0..hash.len) |i| {
        _ = try std.fmt.bufPrint(hash_str[2 * i .. 2 * i + 2], "{x:0<2}", .{hash[i]});
    }

    // Get the shader name.
    const shader_name = b: {
        const start = std.mem.indexOf(u8, source_contents, "@program").?;
        const line = source_contents[(start + "@program".len)..std.mem.indexOfScalarPos(u8, source_contents, start, '\n').?];

        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        break :b tokens.next().?;
    };

    // Filter to just the vertex shader; we can assume syntactically valid 'annotated glsl'.
    const vs = b: {
        // Find the start of the @vs annotation.
        var start = std.mem.indexOf(u8, source_contents, "@vs").?;
        // Skip to the next line.
        start = std.mem.indexOfScalarPos(u8, source_contents, start, '\n').? + 1;

        break :b source_contents[start..std.mem.indexOfPos(u8, source_contents, start, "@end").?];
    };

    // Parse the inputs to the vertex shader.
    var attrs = std.ArrayList(struct { []const u8, InputType }).init(alloc);
    defer attrs.deinit();

    // TODO: Would be better to split by semicolon.
    var lines = std.mem.splitScalar(u8, vs, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "in")) {
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            _ = tokens.next(); // Ignore the "in".

            // Parse the type and name from the next two tokens.
            const ty = b: {
                const raw = tokens.next().?;
                const ty = InputType.tagged(raw);
                if (ty == null) {
                    std.log.err("Unknown input type: '{s}'! Ignoring...\n", .{raw});
                    continue;
                }

                break :b ty.?;
            };
            const name = b: {
                var name = tokens.next().?;
                if (std.mem.endsWith(u8, name, ";")) {
                    name = name[0 .. name.len - 1];
                }
                break :b name;
            };
            const input = .{ name, ty };

            // Append the parsed input to the attribute list.
            try attrs.append(input);
        }
    }

    // Append the new function templates to the end of the built file.
    try built.seekFromEnd(0);
    const writer = built.writer();

    // Indicate the below functions to be generated by us.
    try writer.print("\n// -- POST-PROCESSING --\n\n", .{});

    { // GetVertexLayoutState
        try writer.print(TEMPLATE_GetVertexLayoutState.pre, .{shader_name});
        for (attrs.items) |attr| {
            try writer.print(TEMPLATE_GetVertexLayoutState.repr, .{ shader_name, attr[0], attr[1].getVertexFormat() });
        }
        try writer.print(TEMPLATE_GetVertexLayoutState.post, .{});
    }

    { // GetPipelineDesc
        try writer.print(TEMPLATE_GetPipelineDesc, .{shader_name} ** 3);
    }

    // Write the shader's content hash for change diffing.
    try writer.print("// HASH: {s}\n", .{hash_str});
}
