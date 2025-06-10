const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});

const print = std.debug.print;

pub fn main() void {
    checkVideoDrivers();
}

fn checkVideoDrivers() void {
    const num: usize = @intCast(c.SDL_GetNumVideoDrivers());
    print("{} video drivers found:\n", .{num});
    for (0..num) |n| {
        print(" - {s}\n", .{c.SDL_GetVideoDriver(@intCast(n))});
    }
}
