const std = @import("std");
const sokol = @import("sokol");

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

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dynamic_linkage = false,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_zlm = b.dependency("zlm", .{
        .target = target,
        .optimize = optimize,
    });

    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));

    exe_mod.addImport("sokol", dep_sokol.module("sokol"));
    exe_mod.addImport("cimgui", dep_cimgui.module("cimgui"));
    exe_mod.addImport("zlm", dep_zlm.module("zlm"));

    const pp = b.step("build-shaders", "Builds all of the shaders.");
    pp.* = std.Build.Step.init(.{
        .id = pp.id,
        .name = pp.name,
        .owner = pp.owner,
        .makeFn = PostProcess.postProcessShaders,
    });
    buildShaders(b, dep_sokol, pp) catch @panic("Failed to create shader build step!");

    exe.step.dependOn(pp);

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
fn buildShaders(b: *std.Build, dep_sokol: *std.Build.Dependency, dependent: *std.Build.Step) !void {
    // Open shaders directory.
    var dir = try std.fs.cwd().openDir("src/shaders", .{ .iterate = true });
    defer dir.close();

    // Ensure our build directory exists.
    _ = dir.makeDir("build") catch {};

    // Iterate through all of the items in the directory.
    var iter = dir.iterate();
    while (try iter.next()) |item| {
        // Filter only for shader files.
        if (item.kind != std.fs.File.Kind.file or !std.mem.endsWith(u8, item.name, ".glsl")) continue;

        // Set the input and output file paths.
        const input_path = b.fmt("src/shaders/{s}", .{item.name});
        const output_path = b.fmt("src/shaders/build/{s}.zig", .{item.name});

        // Create the compilation command and bind it to the dependent step.
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

        dependent.dependOn(compile);
    }
}

const PostProcess = struct {
    // TODO: Merge this step with the compilation step using global variables (perhaps a map keyed by step name) to specify shader files?
    pub fn postProcessShaders(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
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
        ;

        // ---

        const alloc = step.owner.allocator;
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
            const file = try source_dir.openFile(item.name, .{});
            defer file.close();

            // Check if the built file exists.
            const built = built_dir.openFile(try std.mem.concat(alloc, u8, &[_][]const u8{ item.name, ".zig" }), .{ .mode = .read_write }) catch |e| {
                std.log.err("Shader '{s}' has not been built; cannot post-process!\n", .{item.name});
                return e;
            };
            defer built.close();

            // Read the contents of the source file.
            const contents = try file.readToEndAlloc(alloc, std.math.maxInt(usize));

            // Get the shader name.
            const shader_name = b: {
                const start = std.mem.indexOf(u8, contents, "@program").?;
                const line = contents[(start + "@program".len)..std.mem.indexOfPos(u8, contents, start, "\n").?];

                var tokens = std.mem.tokenizeScalar(u8, line, ' ');
                break :b tokens.next().?;
            };

            // Filter to just the vertex shader; we can assume syntactically valid 'annotated glsl'.
            const vs = b: {
                // Find the start of the @vs annotation.
                var start = std.mem.indexOf(u8, contents, "@vs").?;
                // Skip to the next line.
                start = std.mem.indexOfPos(u8, contents, start, "\n").? + 1;

                break :b contents[start..std.mem.indexOfPos(u8, contents, start, "@end").?];
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
        }
    }
};
