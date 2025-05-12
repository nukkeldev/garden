const std = @import("std");

/// Whether to download the prebuilt binary from flooh/sokol-tools-bin.
const USE_PREBUILT = false;

/// The url of sokol-tools git repository.
const SHDC_URL = "https://github.com/floooh/sokol-tools";
/// The url of the sokol-tools-bin git repository.
const SHDC_BIN_URL = "https://github.com/floooh/sokol-tools-bin";

/// The revision of the compiler to build.
const BUILD_REVISION: []const u8 = "1ded6f042622f0eba4a29f4027af6acd0fd997eb";
/// The revision of the prebuilt binaries to download.
const PREBUILT_REVISION: []const u8 = "9abc4ce9a851e199105ce7929f5d616bbb7118b4";

pub fn main() !void {
    // Initialize an allocator.
    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();

    const alloc = da.allocator();

    // Check if an shdc executable is in the cwd.
    var shdc_exists = true;
    std.fs.cwd().access("shdc", .{}) catch |e| switch (e) {
        error.FileNotFound => shdc_exists = false,
        else => return e,
    };

    b: switch (shdc_exists) {
        true => {
            // If it is, then use it to compile our shaders that need recompilation.
            std.log.info("shdc compiler found", .{});
        },
        false => {
            std.log.warn("shdc compiler not found", .{});
            try acquire_shdc(alloc);
            continue :b true;
        },
    }
}

fn acquire_shdc(alloc: std.mem.Allocator) !void {
    // Format the url for whichever version we'd like.
    const url = try formatted_repo_url(alloc);
    defer alloc.free(url);

    // Create an http client.
    std.log.debug("Downloading {s}...", .{url});
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    // Fetch the zip file.
    var resp = std.ArrayList(u8).init(alloc);
    defer resp.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &resp },
    });

    std.log.debug("{}: {}", .{ result, resp.items.len });
}

fn formatted_repo_url(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{[url]s}/archive/{[hash]s}.zip", .{
        .url = if (USE_PREBUILT) SHDC_BIN_URL else SHDC_URL,
        .hash = if (USE_PREBUILT) PREBUILT_REVISION else BUILD_REVISION,
    });
}
