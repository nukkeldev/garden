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

var should_exit = false;

fn init() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        fatal(sdl_log, "Couldn't initialize SDL: {s}", .{c.SDL_GetError()});
    }

    if (!c.SDL_CreateWindowAndRenderer("Garden", 720, 720, 0, &window, &renderer)) {
        fatal(sdl_log, "Couldn't create window/renderer: {s}", .{c.SDL_GetError()});
    }
}

fn update() !void {
    try pollEvents();
    try render();
}

fn pollEvents() !void {
    var event: c.SDL_Event = undefined;
    if (c.SDL_PollEvent(&event)) switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            switch (event.key.scancode) {
                c.SDL_SCANCODE_ESCAPE => should_exit = true,
                else => {},
            }
        },
        c.SDL_EVENT_QUIT => should_exit = true,
        else => {},
    };
}

fn render() !void {}

fn exit() !void {}

// Main

pub fn main() void {
    const args: []const []const u8 = &.{};
    _ = c.SDL_RunApp(@intCast(args.len), @ptrCast(@constCast(&args)), &sdlMainWrapper, null);
}

fn sdlMainWrapper(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    sdlMain() catch |e| fatal("Error: {}", .{e});
    return 1;
}

pub fn sdlMain() !void {
    try init();
    while (!should_exit) try update();
    try exit();
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
