const std = @import("std");
pub const ztracy = @import("ztracy");

const mem = std.mem;
const Allocator = mem.Allocator;

pub const DEBUG = @import("builtin").mode == .Debug;

const log = std.log.scoped(.trace);

// Zoning

/// A `ztracy.ZoneCtx` stack.
pub const FnZone = struct {
    /// The maximum number of zones allowed in a `FnZone`.
    const MAX_ZONES = 16;

    next_zone_index: usize = 0,
    zones: [MAX_ZONES]ztracy.ZoneCtx = undefined,
    zone_names: [MAX_ZONES][*:0]const u8 = undefined,

    /// Initializes a `FnZone`; pushing an initial zone.
    pub fn init(comptime src: std.builtin.SourceLocation, name: [*:0]const u8) FnZone {
        var fz = FnZone{};
        fz.push(src, name);
        return fz;
    }

    /// Push a zone.
    pub fn push(self: *FnZone, comptime src: std.builtin.SourceLocation, name: [*:0]const u8) void {
        if (DEBUG and self.next_zone_index == MAX_ZONES) @panic("Too many nested zones!");

        // std.debug.print("pushing: {s}\n", .{name});

        self.zones[self.next_zone_index] = ztracy.ZoneN(src, name);
        self.zone_names[self.next_zone_index] = name;
        self.next_zone_index += 1;
    }

    /// End the last-pushed and replace it.
    pub fn replace(self: *FnZone, comptime src: std.builtin.SourceLocation, name: [*:0]const u8) void {
        self.pop();
        self.push(src, name);
    }

    /// Pop the last-pushed zone.
    pub fn pop(self: *FnZone) void {
        if (self.next_zone_index == 0) return;

        // std.debug.print("popping: {s}\n", .{self.zone_names[self.next_zone_index - 1]});

        self.next_zone_index -= 1;
        self.zones[self.next_zone_index].End();
    }

    /// End all active zones.
    pub fn end(self: *FnZone) void {
        while (self.next_zone_index > 0) self.pop();
    }
};

// Memory

/// A debug tracing arena allocator that tracks all allocations with Tracy
/// (via `ztracy`) and proxies them to an arena allocator.
pub const TracingArenaAllocator = struct {
    arena: std.heap.ArenaAllocator,

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(child_allocator: Allocator) @This() {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *@This()) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr_opt = self.arena.allocator().rawAlloc(len, alignment, return_address);
        if (DEBUG) if (ptr_opt) |ptr| ztracy.Alloc(@ptrCast(ptr), len);
        return ptr_opt;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const good = self.arena.allocator().rawResize(buf, alignment, new_len, return_address);
        if (DEBUG) if (good) {
            ztracy.Free(@ptrCast(buf));
            ztracy.Alloc(@ptrCast(buf), new_len);
        };
        return good;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr_opt = self.arena.allocator().rawRemap(memory, alignment, new_len, return_address);
        if (DEBUG) if (ptr_opt) |ptr| {
            ztracy.Free(@ptrCast(memory));
            ztracy.Alloc(@ptrCast(ptr), new_len);
        };
        return ptr_opt;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.arena.allocator().rawFree(buf, alignment, return_address);
        if (DEBUG) ztracy.Free(@ptrCast(buf));
    }
};
