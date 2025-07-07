const std = @import("std");

const c = @cImport({
    @cInclude("c.h");
});

pub const Shader = struct {
    spirv: []const u8,
    // TODO: Future work would be to directly use the reflection APIs outputs rather than json parsing.
    refl: []const u8,
};

// TODO: Fix leak.
/// A thin-wrapper around a C++-invocation of slang's compilation API.
pub fn compileShader(allocator: std.mem.Allocator, name: [:0]const u8, input: [:0]const u8) !Shader {
    var spirv: [*c]u8 = null;
    var spirv_len: usize = 0;

    var refl: [*c]u8 = null;
    var refl_len: usize = 0;

    const path = try std.fmt.allocPrint(allocator, "{s}.slang\x00", .{name});
    defer allocator.free(path);

    const ret = c.__compileShader(name, path.ptr, input, &spirv, &spirv_len, &refl, &refl_len);
    if (ret != 0) {
        std.log.err("Compilation Error! Exit code = {}", .{ret});
        return error.CompilationFailed;
    }

    return .{
        .spirv = spirv[0..spirv_len],
        .refl = refl[0..refl_len],
    };
}
