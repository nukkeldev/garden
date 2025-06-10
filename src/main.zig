const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

pub const std_options: std.Options = .{ .log_level = .debug };

const sdl_log = std.log.scoped(.sdl);
const log = std.log.scoped(.garden);

// App

var window: ?*c.SDL_Window = null;
var renderer: ?*c.SDL_Renderer = null;

// SDL

pub fn sdlMain() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        fatal(sdl_log, "Couldn't initialize SDL: {s}", .{c.SDL_GetError()});
    }

    if (!c.SDL_CreateWindowAndRenderer("Garden", 720, 720, 0, &window, &renderer)) {
        fatal(sdl_log, "Couldn't create window/renderer: {s}", .{c.SDL_GetError()});
    }
}

// Main

pub fn main() void {
    var da = std.heap.DebugAllocator(.{}).init;
    const allocator = da.allocator();
    defer _ = da.deinit();

    const args = std.process.argsAlloc(allocator) catch oom();
    defer std.process.argsFree(allocator, args);

    _ = c.SDL_RunApp(@intCast(args.len), @ptrCast(@constCast(&args)), &sdlMainWrapper, null);
}

fn sdlMainWrapper(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    sdlMain() catch |e| fatal("Error: {}", .{e});
    return 1;
}

// Utils

fn fatal(comptime Log: type, comptime msg: []const u8, args: anytype) noreturn {
    Log.err(msg, args);
    // Exit with a non-error code so the console isn't flooded.
    std.process.exit(0);
}

fn oom() noreturn {
    fatal(log, "Out-of-memory!", .{});
}
