const std = @import("std");

// SDL export

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

// C-Interop

pub fn cstr(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    const out = try allocator.alloc(u8, str.len + 1);
    @memset(out, 0);
    std.mem.copyForwards(u8, out, str);
    return @ptrCast(out);
}

pub fn nullptr(comptime T: type) T {
    return @as(T, @ptrFromInt(0));
}
