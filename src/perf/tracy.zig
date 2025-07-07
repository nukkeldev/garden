// Forked with love from zig's repo.
// https://github.com/ziglang/zig/blob/c96c913bab00bcae42991244381ddcc8b2377552/src/tracy.zig

const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build-opts");

pub const enable = if (builtin.is_test) false else build_opts.enable_tracy;
const enable_callstack = build_opts.enable_tracy_callstack;

const CALLSTACK_DEPTH = 10;

// -- Abstractions -- //

const mem = std.mem;
const Allocator = mem.Allocator;

const log = std.log.scoped(.tracy);

pub const FnZone = if (enable) ___my_tracy_fn_zone else struct {
    /// Initializes a `FnZone`; pushing an initial zone.
    pub fn init(comptime _: std.builtin.SourceLocation, comptime _: [:0]const u8) @This() {
        return .{};
    }

    /// Push a zone.
    pub fn push(_: *@This(), comptime _: std.builtin.SourceLocation, comptime _: [:0]const u8) void {}

    /// End the last-pushed and replace it.
    pub fn replace(_: *@This(), comptime _: std.builtin.SourceLocation, comptime _: [:0]const u8) void {}

    /// Pop the last-pushed zone.
    pub fn pop(_: *@This()) void {}

    /// End all active zones.
    pub fn end(_: *@This()) void {}
};

/// A `Ctx` stack.
const ___my_tracy_fn_zone = struct {
    /// The maximum number of zones allowed in a `FnZone`.
    const MAX_ZONES = 16;

    next_zone_index: usize = 0,
    zones: [MAX_ZONES]Ctx = undefined,

    /// Initializes a `FnZone`; pushing an initial zone.
    pub fn init(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) ___my_tracy_fn_zone {
        var fz = ___my_tracy_fn_zone{};
        fz.push(src, name);
        return fz;
    }

    /// Push a zone.
    pub fn push(self: *___my_tracy_fn_zone, comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) void {
        if (@import("root").DEBUG and self.next_zone_index == MAX_ZONES) @panic("Too many nested zones!");

        self.zones[self.next_zone_index] = traceNamed(src, name);
        self.next_zone_index += 1;
    }

    /// End the last-pushed and replace it.
    pub fn replace(self: *___my_tracy_fn_zone, comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) void {
        self.pop();
        self.push(src, name);
    }

    /// Pop the last-pushed zone.
    pub fn pop(self: *___my_tracy_fn_zone) void {
        if (self.next_zone_index == 0) return;

        self.next_zone_index -= 1;
        self.zones[self.next_zone_index].end();
    }

    /// End all active zones.
    pub fn end(self: *___my_tracy_fn_zone) void {
        while (self.next_zone_index > 0) self.pop();
    }
};

// -- FFI -- //

const ___tracy_c_zone_context = extern struct {
    id: u32,
    active: c_int,

    pub inline fn end(self: @This()) void {
        ___tracy_emit_zone_end(self);
    }

    pub inline fn addText(self: @This(), text: []const u8) void {
        ___tracy_emit_zone_text(self, text.ptr, text.len);
    }

    pub inline fn setName(self: @This(), name: []const u8) void {
        ___tracy_emit_zone_name(self, name.ptr, name.len);
    }

    pub inline fn setColor(self: @This(), color: u32) void {
        ___tracy_emit_zone_color(self, color);
    }

    pub inline fn setValue(self: @This(), value: u64) void {
        ___tracy_emit_zone_value(self, value);
    }
};

pub const Ctx = if (enable) ___tracy_c_zone_context else struct {
    pub inline fn end(self: @This()) void {
        _ = self;
    }

    pub inline fn addText(self: @This(), text: []const u8) void {
        _ = self;
        _ = text;
    }

    pub inline fn setName(self: @This(), name: []const u8) void {
        _ = self;
        _ = name;
    }

    pub inline fn setColor(self: @This(), color: u32) void {
        _ = self;
        _ = color;
    }

    pub inline fn setValue(self: @This(), value: u64) void {
        _ = self;
        _ = value;
    }
};

pub inline fn trace(comptime src: std.builtin.SourceLocation) Ctx {
    if (!enable) return .{};

    const global = struct {
        const loc: ___tracy_source_location_data = .{
            .name = null,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
    };

    if (enable_callstack) {
        return ___tracy_emit_zone_begin_callstack(&global.loc, CALLSTACK_DEPTH, 1);
    } else {
        return ___tracy_emit_zone_begin(&global.loc, 1);
    }
}

pub inline fn traceNamed(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Ctx {
    if (!enable) return .{};

    const global = struct {
        const loc: ___tracy_source_location_data = .{
            .name = name.ptr,
            .function = src.fn_name.ptr,
            .file = src.file.ptr,
            .line = src.line,
            .color = 0,
        };
    };

    if (enable_callstack) {
        return ___tracy_emit_zone_begin_callstack(&global.loc, CALLSTACK_DEPTH, 1);
    } else {
        return ___tracy_emit_zone_begin(&global.loc, 1);
    }
}

pub fn tracyAllocator(allocator: std.mem.Allocator) TracyAllocator(null) {
    return TracyAllocator(null).init(allocator);
}

pub fn TracyAllocator(comptime name: ?[:0]const u8) type {
    return struct {
        parent_allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(parent_allocator: std.mem.Allocator) Self {
            return .{
                .parent_allocator = parent_allocator,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }

        fn allocFn(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const result = self.parent_allocator.rawAlloc(len, alignment, ret_addr);
            if (result) |memory| {
                if (len != 0) {
                    if (name) |n| {
                        allocNamed(memory, len, n);
                    } else {
                        alloc(memory, len);
                    }
                }
            } else {
                messageColor("allocation failed", 0xFF0000);
            }
            return result;
        }

        fn resizeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.parent_allocator.rawResize(memory, alignment, new_len, ret_addr)) {
                if (name) |n| {
                    freeNamed(memory.ptr, n);
                    allocNamed(memory.ptr, new_len, n);
                } else {
                    free(memory.ptr);
                    alloc(memory.ptr, new_len);
                }

                return true;
            }

            // during normal operation the compiler hits this case thousands of times due to this
            // emitting messages for it is both slow and causes clutter
            return false;
        }

        fn remapFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr)) |new_memory| {
                if (name) |n| {
                    freeNamed(memory.ptr, n);
                    allocNamed(new_memory, new_len, n);
                } else {
                    free(memory.ptr);
                    alloc(new_memory, new_len);
                }
                return new_memory;
            } else {
                messageColor("reallocation failed", 0xFF0000);
                return null;
            }
        }

        fn freeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.parent_allocator.rawFree(memory, alignment, ret_addr);
            // this condition is to handle free being called on an empty slice that was never even allocated
            // example case: `std.process.getSelfExeSharedLibPaths` can return `&[_][:0]u8{}`
            if (memory.len != 0) {
                if (name) |n| {
                    freeNamed(memory.ptr, n);
                } else {
                    free(memory.ptr);
                }
            }
        }
    };
}

// This function only accepts comptime-known strings, see `messageCopy` for runtime strings
pub inline fn message(comptime msg: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_messageL(msg.ptr, if (enable_callstack) CALLSTACK_DEPTH else 0);
}

// This function only accepts comptime-known strings, see `messageColorCopy` for runtime strings
pub inline fn messageColor(comptime msg: [:0]const u8, color: u32) void {
    if (!enable) return;
    ___tracy_emit_messageLC(msg.ptr, color, if (enable_callstack) CALLSTACK_DEPTH else 0);
}

pub inline fn messageCopy(msg: []const u8) void {
    if (!enable) return;
    ___tracy_emit_message(msg.ptr, msg.len, if (enable_callstack) CALLSTACK_DEPTH else 0);
}

pub inline fn messageColorCopy(msg: [:0]const u8, color: u32) void {
    if (!enable) return;
    ___tracy_emit_messageC(msg.ptr, msg.len, color, if (enable_callstack) CALLSTACK_DEPTH else 0);
}

pub inline fn frameMark() void {
    if (!enable) return;
    ___tracy_emit_frame_mark(null);
}

pub inline fn frameMarkNamed(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark(name.ptr);
}

pub inline fn namedFrame(comptime name: [:0]const u8) Frame(name) {
    frameMarkStart(name);
    return .{};
}

pub fn Frame(comptime name: [:0]const u8) type {
    return struct {
        pub fn end(_: @This()) void {
            frameMarkEnd(name);
        }
    };
}

inline fn frameMarkStart(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark_start(name.ptr);
}

inline fn frameMarkEnd(comptime name: [:0]const u8) void {
    if (!enable) return;
    ___tracy_emit_frame_mark_end(name.ptr);
}

extern fn ___tracy_emit_frame_mark_start(name: [*:0]const u8) void;
extern fn ___tracy_emit_frame_mark_end(name: [*:0]const u8) void;

inline fn alloc(ptr: [*]u8, len: usize) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_alloc_callstack(ptr, len, CALLSTACK_DEPTH, 0);
    } else {
        ___tracy_emit_memory_alloc(ptr, len, 0);
    }
}

inline fn allocNamed(ptr: [*]u8, len: usize, comptime name: [:0]const u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_alloc_callstack_named(ptr, len, CALLSTACK_DEPTH, 0, name.ptr);
    } else {
        ___tracy_emit_memory_alloc_named(ptr, len, 0, name.ptr);
    }
}

inline fn free(ptr: [*]u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_free_callstack(ptr, CALLSTACK_DEPTH, 0);
    } else {
        ___tracy_emit_memory_free(ptr, 0);
    }
}

inline fn freeNamed(ptr: [*]u8, comptime name: [:0]const u8) void {
    if (!enable) return;

    if (enable_callstack) {
        ___tracy_emit_memory_free_callstack_named(ptr, CALLSTACK_DEPTH, 0, name.ptr);
    } else {
        ___tracy_emit_memory_free_named(ptr, 0, name.ptr);
    }
}

extern fn ___tracy_emit_zone_begin(
    srcloc: *const ___tracy_source_location_data,
    active: c_int,
) ___tracy_c_zone_context;
extern fn ___tracy_emit_zone_begin_callstack(
    srcloc: *const ___tracy_source_location_data,
    depth: c_int,
    active: c_int,
) ___tracy_c_zone_context;
extern fn ___tracy_emit_zone_text(ctx: ___tracy_c_zone_context, txt: [*]const u8, size: usize) void;
extern fn ___tracy_emit_zone_name(ctx: ___tracy_c_zone_context, txt: [*]const u8, size: usize) void;
extern fn ___tracy_emit_zone_color(ctx: ___tracy_c_zone_context, color: u32) void;
extern fn ___tracy_emit_zone_value(ctx: ___tracy_c_zone_context, value: u64) void;
extern fn ___tracy_emit_zone_end(ctx: ___tracy_c_zone_context) void;
extern fn ___tracy_emit_memory_alloc(ptr: *const anyopaque, size: usize, secure: c_int) void;
extern fn ___tracy_emit_memory_alloc_callstack(ptr: *const anyopaque, size: usize, depth: c_int, secure: c_int) void;
extern fn ___tracy_emit_memory_free(ptr: *const anyopaque, secure: c_int) void;
extern fn ___tracy_emit_memory_free_callstack(ptr: *const anyopaque, depth: c_int, secure: c_int) void;
extern fn ___tracy_emit_memory_alloc_named(ptr: *const anyopaque, size: usize, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_alloc_callstack_named(ptr: *const anyopaque, size: usize, depth: c_int, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_free_named(ptr: *const anyopaque, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_memory_free_callstack_named(ptr: *const anyopaque, depth: c_int, secure: c_int, name: [*:0]const u8) void;
extern fn ___tracy_emit_message(txt: [*]const u8, size: usize, callstack: c_int) void;
extern fn ___tracy_emit_messageL(txt: [*:0]const u8, callstack: c_int) void;
extern fn ___tracy_emit_messageC(txt: [*]const u8, size: usize, color: u32, callstack: c_int) void;
extern fn ___tracy_emit_messageLC(txt: [*:0]const u8, color: u32, callstack: c_int) void;
extern fn ___tracy_emit_frame_mark(name: ?[*:0]const u8) void;

const ___tracy_source_location_data = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};
