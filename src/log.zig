const std = @import("std");

// Instances

pub const gdn = TaggedLogger(.gdn, defaultLog, true);

pub const gui = TaggedLogger(.gui, defaultLog, false);
pub const sdl = TaggedLogger(.sdl, struct {
    fn log(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        _ = args;
        defaultLog(message_level, scope, format ++ ": {s}", .{@import("ffi.zig").c.SDL_GetError()});
    }
}.log, false);

// Helpers

pub fn oom() noreturn {
    gdn.fatal("Out-Of-Memory!", .{});
}

// Logger

fn TaggedLogger(comptime tag: @TypeOf(.enum_literal), comptime logFn: @TypeOf(defaultLog), comptime with_args: bool) type {
    const log = struct {
        fn log(
            comptime message_level: std.log.Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !std.log.logEnabled(message_level, tag)) return;
            logFn(message_level, tag, format, args);
        }
    }.log;

    if (with_args) {
        return struct {
            pub fn debug(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(.debug, format, args);
            }

            pub fn info(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(.info, format, args);
            }

            pub fn warn(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(.warn, format, args);
            }

            pub fn err(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(.err, format, args);
            }

            pub fn fatal(
                comptime format: []const u8,
                args: anytype,
            ) noreturn {
                err(format, args);
                // Exit with a non-error code so the console isn't flooded.
                std.process.exit(0);
            }
        };
    } else {
        return struct {
            pub fn debug(
                comptime format: []const u8,
            ) void {
                log(.debug, format, .{});
            }

            pub fn info(
                comptime format: []const u8,
            ) void {
                log(.info, format, .{});
            }

            pub fn warn(
                comptime format: []const u8,
            ) void {
                log(.warn, format, .{});
            }

            pub fn err(
                comptime format: []const u8,
            ) void {
                log(.err, format, .{});
            }

            pub fn fatal(
                comptime format: []const u8,
            ) noreturn {
                err(format);
                std.process.exit(0);
            }
        };
    }
}

fn defaultLog(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@import("builtin").mode == .Debug) {
        // https://github.com/ziglang/zig/issues/7106
        const debug_info = std.debug.getSelfDebugInfo() catch unreachable;
        var it = std.debug.StackIterator.init(@returnAddress(), null);
        for (0..4) |_| _ = it.next();
        const address: usize = it.next().?;
        const module = debug_info.getModuleForAddress(address - 1) catch unreachable;
        const symbol_info = module.getSymbolAtAddress(debug_info.allocator, address - 1) catch unreachable;
        defer if (symbol_info.source_location) |sl| debug_info.allocator.free(sl.file_name);
        const source = symbol_info.source_location.?;

        const source_fmt = std.fmt.allocPrint(debug_info.allocator, "({s}@{s}:{}) ", .{ std.fs.path.basename(source.file_name), symbol_info.name, source.line }) catch oom();
        defer debug_info.allocator.free(source_fmt);

        std.log.defaultLog(message_level, scope, "{s}" ++ format, .{source_fmt} ++ args);
    } else {
        std.log.defaultLog(message_level, scope, format, args);
    }
}
