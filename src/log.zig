const std = @import("std");

// TODO: Maybe? https://github.com/ziglang/zig/issues/7106

// Helpers

pub fn oom() noreturn {
    std.debug.print("Out-Of-Memory!", .{});
    std.process.exit(0);
}
