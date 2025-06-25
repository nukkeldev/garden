const std = @import("std");

// TODO: Maybe? https://github.com/ziglang/zig/issues/7106

// Instances

pub const gdn = std.log.scoped(.gdn);
pub const gui = std.log.scoped(.gui);
pub const sdl = std.log.scoped(.sdl);

// Helpers

pub fn oom() noreturn {
    gdn.err("Out-Of-Memory!", .{});
    std.process.exit(0);
}
