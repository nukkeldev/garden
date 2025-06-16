const std = @import("std");
const common = @import("../common.zig");

pub const CompiledShader = struct {
    allocator: std.mem.Allocator,

    spv: []const u8,
    layout: []const u8,

    const Stage = enum {
        Vertex,
        Fragment,
    };

    /// Compile a `.slang` shader for the `stage` and output the resultant file contents.
    pub fn compileBlocking(allocator: std.mem.Allocator, path: []const u8, stage: Stage, return_contents: bool) !?@This() {
        // Convert stage enum into file extension and entrypoint.
        const ext = switch (stage) {
            .Vertex => "vertex",
            .Fragment => "fragment",
        };
        const entry = switch (stage) {
            .Vertex => "vertexMain",
            .Fragment => "fragmentMain",
        };

        // Resolve to an absolute path.
        const abs = try std.fs.cwd().realpathAlloc(allocator, path);
        defer allocator.free(abs);

        // Break path into components.
        const dirname = std.fs.path.dirname(abs).?;
        const basename = std.fs.path.basename(abs);
        const filename = basename[0 .. std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len];

        std.log.debug("Compiling {s} shader: {s}/{s}.slang...", .{ ext, dirname, filename });

        const spv_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.{s}.spv", .{ dirname, filename, ext[0..4] }) catch common.oom();
        const layout_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.{s}.layout", .{ dirname, filename, ext[0..4] }) catch common.oom();
        defer allocator.free(spv_path);
        defer allocator.free(layout_path);

        // Ensure the output directory exists.
        var mkdir = std.process.Child.init(&.{ "mkdir", "-p", dirname }, allocator);
        _ = try mkdir.spawnAndWait();

        // Create and spawn the child process.
        var child = std.process.Child.init(
            &.{
                "slangc",
                abs,
                "-o",
                spv_path,
                "-reflection-json",
                layout_path,
                "-entry",
                entry,
                "-target",
                "spirv",
                "-profile",
                "spirv_1_0",
                "-emit-spirv-via-glsl",
                "-fvk-use-entrypoint-name",
            },
            allocator,
        );
        _ = try child.spawnAndWait();

        // If we aren't returning the contents then exit.
        if (!return_contents) return null;

        // Read the output files.
        const spv = std.fs.cwd().readFileAlloc(allocator, spv_path, std.math.maxInt(usize)) catch {
            common.log.err("Failed to read vertex shader!", .{});
            return null;
        };

        const layout = std.fs.cwd().readFileAlloc(allocator, layout_path, std.math.maxInt(usize)) catch {
            common.log.err("Failed to read vertex shader layout!", .{});
            return null;
        };

        return .{ .allocator = allocator, .spv = spv, .layout = layout };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.spv);
        self.allocator.free(self.layout);
    }
};
