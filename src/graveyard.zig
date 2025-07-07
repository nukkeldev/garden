//! This file records cool but now unused functions from this codebase.

const std = @import("std");

pub fn filterFlattenedData(
    comptime Data: type,
    comptime Len: type,
    allocator: std.mem.Allocator,
    /// The expected size of each flattened data element.
    expected_elem_len: comptime_int,
    raw_data_elem_lens: []const Len,
    raw_data: []const Data,
    out_invalid_elems: ?*[]usize,
) !struct { usize, []Data } {
    // Assert the size of the raw data to match that of the element lengths given.
    if (@import("root").DEBUG) {
        var len: usize = 0;
        for (raw_data_elem_lens) |n| len += @intCast(n);
        try std.testing.expectEqual(len, raw_data.len);
    }

    // Copy the valid data into a new buffer with the same length.
    const data = try allocator.alloc(Data, raw_data.len);
    var invalid_elems = std.ArrayList(usize).init(allocator);

    const valid_data_len = outer: {
        var valid_data_len: usize = 0;
        var raw_data_copy_start, var raw_data_copy_end = [_]usize{ 0, 0 };
        var last_valid_elem_len_idx, var last_copy_idx = [_]usize{ 0, 0 };
        for (raw_data_elem_lens, 0..) |elem_len, elem_len_idx| {
            if (elem_len != expected_elem_len) {
                const copy_len = (elem_len_idx - last_valid_elem_len_idx) * expected_elem_len;
                raw_data_copy_end = raw_data_copy_start + copy_len;

                @memcpy(
                    data[last_copy_idx .. last_copy_idx + copy_len],
                    raw_data[raw_data_copy_start..raw_data_copy_end],
                );

                raw_data_copy_start = raw_data_copy_end + @as(usize, @intCast(elem_len));
                last_copy_idx += copy_len;

                valid_data_len += copy_len;
                last_valid_elem_len_idx = elem_len_idx + 1;
                try invalid_elems.append(elem_len_idx);
            }
        } else {
            const copy_len = (raw_data_elem_lens.len - last_valid_elem_len_idx) * expected_elem_len;
            raw_data_copy_end = raw_data_copy_start + copy_len;

            @memcpy(
                data[last_copy_idx .. last_copy_idx + copy_len],
                raw_data[raw_data_copy_start..raw_data_copy_end],
            );

            valid_data_len += copy_len;
        }

        break :outer valid_data_len;
    };

    if (out_invalid_elems) |ptr| {
        ptr.* = try allocator.dupe(usize, invalid_elems.items);
    }
    invalid_elems.deinit();

    return .{ valid_data_len, @ptrCast(data) };
}
