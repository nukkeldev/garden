const std = @import("std");

// SDL export

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

// Logging

pub const sdl_log = std.log.scoped(.sdl);
pub const log = std.log.scoped(.garden);

pub fn SDL_Warn(comptime name: []const u8) void {
    sdl_log.warn(name ++ ": {s}", .{c.SDL_GetError()});
}

pub fn SDL_Err(comptime name: []const u8) void {
    sdl_log.err(name ++ ": {s}", .{c.SDL_GetError()});
}

pub fn SDL_Fatal(comptime name: []const u8) noreturn {
    fatal(sdl_log, name ++ ": {s}", .{c.SDL_GetError()});
}

// Panicking

pub fn fatal(comptime Log: type, comptime msg: []const u8, args: anytype) noreturn {
    Log.err(msg, args);
    // Exit with a non-error code so the console isn't flooded.
    std.process.exit(0);
}

pub fn oom() noreturn {
    fatal(log, "Out-of-memory!", .{});
}
