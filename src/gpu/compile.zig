const std = @import("std");

const log = std.log.scoped(.@"gpu.compile");
const oom = @import("../log.zig").oom;

const EMBEDDED_VERTEX_SHADER = @embedFile("../assets/shaders/compiled/vertex.spv");
const EMBEDDED_VERTEX_SHADER_LAYOUT = @embedFile("../assets/shaders/compiled/vertex.layout");
const EMBEDDED_FRAGMENT_SHADER = @embedFile("../assets/shaders/compiled/fragment.spv");
const EMBEDDED_FRAGMENT_SHADER_LAYOUT = @embedFile("../assets/shaders/compiled/fragment.layout");

pub const CompiledShader = struct {
    allocator: ?std.mem.Allocator,

    spv: []const u8,
    layout: []const u8,

    const Stage = enum {
        Vertex,
        Fragment,
    };

    /// Compile a `.slang` shader for the `stage` and output the resultant file contents.
    pub fn compileBlocking(allocator: std.mem.Allocator, path: []const u8, stage: Stage, embedded: bool, return_contents: bool) !?@This() {
        // Convert stage enum into file extension and entrypoint.
        const ext = switch (stage) {
            .Vertex => "vertex",
            .Fragment => "fragment",
        };

        if (embedded) {
            log.debug("Using pre-compiled {s} shader.", .{ext});
            return switch (stage) {
                .Vertex => .{ .allocator = null, .spv = EMBEDDED_VERTEX_SHADER, .layout = EMBEDDED_VERTEX_SHADER_LAYOUT },
                .Fragment => .{ .allocator = null, .spv = EMBEDDED_FRAGMENT_SHADER, .layout = EMBEDDED_FRAGMENT_SHADER_LAYOUT },
            };
        }

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

        log.debug("Compiling {s} shader: {s}/{s}.slang...", .{ ext, dirname, filename });

        const spv_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.spv", .{ dirname, filename }) catch oom();
        const layout_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.layout", .{ dirname, filename }) catch oom();
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
                "spirv_1_3",
                "-fvk-use-entrypoint-name",
                "-matrix-layout-row-major",
            },
            allocator,
        );
        _ = try child.spawnAndWait();

        // If we aren't returning the contents then exit.
        if (!return_contents) return null;

        // Read the output files.
        const spv = std.fs.cwd().readFileAlloc(allocator, spv_path, std.math.maxInt(usize)) catch {
            log.err("Failed to read vertex shader!", .{});
            return null;
        };

        const layout = std.fs.cwd().readFileAlloc(allocator, layout_path, std.math.maxInt(usize)) catch {
            log.err("Failed to read vertex shader layout!", .{});
            return null;
        };

        return .{ .allocator = allocator, .spv = spv, .layout = layout };
    }

    pub fn deinit(self: @This()) void {
        if (self.allocator) |a| {
            a.free(self.spv);
            a.free(self.layout);
        }
    }
};
