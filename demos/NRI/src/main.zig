const std = @import("std");

const c = @cImport({
    @cInclude("NRI.h");
    @cInclude("Extensions/NRIDeviceCreation.h");
});

pub fn main() !void {
    std.log.info("Using NRI Version: {}", .{c.NRI_VERSION});
    var result: c.NriResult = undefined;

    var adapters: [2]c.NriAdapterDesc = undefined;
    result = c.nriEnumerateAdapters(&adapters, null);
    if (result != c.NriResult_SUCCESS) {
        std.log.err("nriEnumerateAdapters(): {}", .{result});
        return error.NriError;
    }

    for (adapters, 0..) |adapter, i| std.log.info("Adapter {}: {}", .{ i, adapter });
}
