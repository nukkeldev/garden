const std = @import("std");

// Instances

pub const gdn = TaggedLogger(.gdn, defaultLog, true);

pub const gui = TaggedLogger(.gui, defaultLog, false);
pub const sdl = TaggedLogger(.sdl, struct {
    fn log(
        comptime source: std.builtin.SourceLocation,
        comptime message_level: std.log.Level,
        comptime scope: @Type(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        _ = args;
        defaultLog(source, message_level, scope, format ++ ": {s}!", .{@import("ffi.zig").c.SDL_GetError()});
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
            comptime source: std.builtin.SourceLocation,
            comptime message_level: std.log.Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (comptime !std.log.logEnabled(message_level, tag)) return;
            logFn(source, message_level, tag, format, args);
        }
    }.log;

    if (with_args) {
        return struct {
            pub inline fn debug(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(@src(), .debug, format, args);
            }

            pub inline fn info(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(@src(), .info, format, args);
            }

            pub inline fn warn(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(@src(), .warn, format, args);
            }

            pub inline fn err(
                comptime format: []const u8,
                args: anytype,
            ) void {
                log(@src(), .err, format, args);
            }

            pub inline fn fatal(
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
            pub inline fn debug(
                comptime format: []const u8,
            ) void {
                log(@src(), .debug, format, .{});
            }

            pub inline fn info(
                comptime format: []const u8,
            ) void {
                log(@src(), .info, format, .{});
            }

            pub inline fn warn(
                comptime format: []const u8,
            ) void {
                log(@src(), .warn, format, .{});
            }

            pub inline fn err(
                comptime format: []const u8,
            ) void {
                log(@src(), .err, format, .{});
            }

            pub inline fn fatal(
                comptime format: []const u8,
            ) noreturn {
                err(format);
                std.process.exit(0);
            }
        };
    }
}

fn defaultLog(
    comptime source: std.builtin.SourceLocation,
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const source_fmt = std.fmt.comptimePrint("({s}/{s}:{}) ", .{ source.file, source.fn_name, source.line });
    std.log.defaultLog(message_level, scope, source_fmt ++ format, args);
}
