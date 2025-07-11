const std = @import("std");
const builtin = @import("builtin");

const CONFIGURATION_FILE = "build.cmake.json";
const BUILD_FOLDER = "external";

const Dependencies = struct {
    dependencies: []const Dependency,
};

const Dependency = struct {
    name: []const u8,
    url: []const u8,
    ref: []const u8,
    instructions: []const []const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // ---

    var dry_run = false;

    const args = try std.process.argsAlloc(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        }
    }

    if (dry_run) std.log.warn("This is a dry run.", .{});

    // ---

    var cwd = std.fs.cwd();

    var file_opt = cwd.openFile(CONFIGURATION_FILE, .{});
    const deps: Dependencies = outer: while (true) : (file_opt = cwd.openFile(CONFIGURATION_FILE, .{})) {
        const contents = try (file_opt catch |e| switch (e) {
            error.FileNotFound => {
                std.log.debug("No `" ++ CONFIGURATION_FILE ++ "` in this directory, moving up...", .{});
                cwd = try cwd.openDir("..", .{});
                continue;
            },
            else => return e,
        }).readToEndAlloc(allocator, std.math.maxInt(usize));

        break :outer try std.json.parseFromSliceLeaky(Dependencies, allocator, contents, .{ .ignore_unknown_fields = true });
    };

    // ---

    const git_version = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "version" } });
    std.log.debug("Using '{s}''.", .{std.mem.trim(u8, git_version.stdout, &std.ascii.whitespace)});

    // ---

    const build_folder = try cwd.makeOpenPath(BUILD_FOLDER, .{});
    try build_folder.setAsCwd();

    const build_folder_path = try build_folder.realpathAlloc(allocator, ".");
    std.log.info("Dependency Build Folder: '{s}''.", .{build_folder_path});

    for (deps.dependencies) |dep| {
        std.log.info("Processing dependency '{s}' from '{s}'.", .{ dep.name, dep.url });

        // ---

        const folder_already_exists = outer: {
            build_folder.access(dep.name, .{}) catch break :outer false;
            std.log.info(
                "Folder already exists so I am going to assume you have it previously cloned. " ++
                    "If this is wrong, then please delete the dependency's folder and re-run this tool.",
                .{},
            );
            break :outer true;
        };

        if (!folder_already_exists) {
            const clone_results = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "clone", dep.url },
            });

            if (clone_results.stderr.len > 0) {
                std.log.err(
                    "Cloning the dependency had an error!\n--\n{s}\n--\nSkipping dependency...",
                    .{std.mem.trim(u8, clone_results.stderr, &std.ascii.whitespace)},
                );
                continue;
            } else {
                std.log.info("Cloned '{s}' into '{s}'.", .{ dep.url, dep.name });
            }
        }

        // --

        const dep_builder_folder = try build_folder.openDir(dep.name, .{});
        try dep_builder_folder.setAsCwd();

        if (folder_already_exists) {
            const git_fetch_results = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "fetch" },
            });
            if (git_fetch_results.stderr.len > 0) {
                std.log.err(
                    "Fetching had an error!\n--\n{s}\n--\nSkipping dependency...",
                    .{std.mem.trim(u8, git_fetch_results.stderr, &std.ascii.whitespace)},
                );
                continue;
            } else {
                std.log.info("Fetched repostitory.", .{});
            }
        }

        const git_checkout_results = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "checkout", dep.ref },
        });
        if (std.mem.indexOf(u8, git_checkout_results.stderr, "HEAD is now at") == null) {
            std.log.err(
                "Checking the ref out had an error!\n--\n{s}\n--\nSkipping dependency...",
                .{std.mem.trim(u8, git_checkout_results.stderr, &std.ascii.whitespace)},
            );
            continue;
        } else {
            const trimmed = std.mem.trim(u8, git_checkout_results.stderr, &std.ascii.whitespace);
            std.log.info("Checked out '{s}'.\n--\n{s}\n--\n", .{ dep.ref, trimmed });
        }

        // ---

        std.log.info("Running build instructions...", .{});

        for (dep.instructions) |inst| {
            var instruction = std.ArrayList([]const u8).init(allocator);
            var split = std.mem.splitAny(u8, inst, &std.ascii.whitespace);
            while (split.next()) |arg| try instruction.append(arg);

            if (!dry_run) std.debug.print("\n---\n", .{});

            std.debug.print("  ", .{});
            for (instruction.items) |_inst| std.debug.print("{s} ", .{_inst});

            if (!dry_run) {
                std.debug.print("\n", .{});

                if (std.mem.eql(u8, instruction.items[0], "cd")) {
                    const new_cwd = try std.fs.cwd().openDir(instruction.items[1], .{});
                    try new_cwd.setAsCwd();
                    continue;
                }

                var child = std.process.Child.init(instruction.items, allocator);
                const term = try child.spawnAndWait();

                std.debug.print("\n---\n{s}: {}", .{ @tagName(term), switch (term) {
                    .Exited => |c| @as(usize, @intCast(c)),
                    .Signal => |c| @as(usize, @intCast(c)),
                    .Stopped => |c| @as(usize, @intCast(c)),
                    .Unknown => |c| @as(usize, @intCast(c)),
                } });
            }

            std.debug.print("\n", .{});
        }
    }
}
