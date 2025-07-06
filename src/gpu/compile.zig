const std = @import("std");

const log = std.log.scoped(.@"gpu.compile");
const oom = @import("../log.zig").oom;

const EMBEDDED_SHADER = @embedFile("../assets/shaders/compiled/phong.spv");
const EMBEDDED_SHADER_LAYOUT = @embedFile("../assets/shaders/compiled/phong.slang.layout");

pub const CompiledShader = struct {
    allocator: ?std.mem.Allocator,

    spv: []const u8,
    layout: []const u8,
    entry_point_name: []const u8,

    const Stage = enum {
        Vertex,
        Fragment,
    };

    /// Compile a `.slang` shader for the `stage` and output the resultant file contents.
    pub fn compileBlocking(allocator: std.mem.Allocator, path: []const u8, stage: Stage, embedded: bool, return_contents: bool) !?@This() {
        const entry_point_name = switch (stage) {
            .Vertex => "vertexMain",
            .Fragment => "fragmentMain",
        };

        if (embedded) {
            log.debug("Using pre-compiled {s} shader.", .{path});
            return .{ .allocator = null, .spv = EMBEDDED_SHADER, .layout = EMBEDDED_SHADER_LAYOUT, .entry_point_name = entry_point_name };
        }

        // Resolve to an absolute path.
        const abs = try std.fs.cwd().realpathAlloc(allocator, path);
        defer allocator.free(abs);

        // Break path into components.
        const dirname = std.fs.path.dirname(abs).?;
        const basename = std.fs.path.basename(abs);
        const filename = basename[0 .. std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len];

        log.debug("Compiling '{s}': {s}/{s}...", .{ path, dirname, basename });

        const spv_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.spv", .{ dirname, filename }) catch oom();
        const layout_path = std.fmt.allocPrint(allocator, "{s}/compiled/{s}.layout", .{ dirname, basename }) catch oom();
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
            log.err("Failed to read shader!", .{});
            return null;
        };

        const layout = std.fs.cwd().readFileAlloc(allocator, layout_path, std.math.maxInt(usize)) catch {
            log.err("Failed to read shader layout!", .{});
            return null;
        };

        return .{
            .allocator = allocator,
            .spv = spv,
            .layout = layout,
            .entry_point_name = entry_point_name,
        };
    }

    pub fn deinit(self: @This()) void {
        if (self.allocator) |a| {
            a.free(self.spv);
            a.free(self.layout);
        }
    }
};
