// pub fn Vec(comptime T: type, N: comptime_int) type {
//     return struct {};
// }

/// Column-Major N x N Matrix
pub fn Mat(comptime T: type, N: comptime_int) type {
    return struct {
        m: [COLS][ROWS]T,

        const ROWS = N;
        const COLS = N;

        const Self = @This();

        pub const zero = Self{ .m = [COLS][ROWS]T{.{0} ** ROWS} ** COLS };
        pub const identity = Self{ .m = [COLS][ROWS]T{ .{1} ++ .{0} ** 3, .{0} ++ .{1} ++ .{0} ** 2, .{0} ** 2 ++ .{1} ++ .{0}, .{0} ** 3 ++ .{1} } };

        pub fn mul(a: *const Self, b: *const Self) Self {
            var result = Self.zero;

            // For each item of the matrix, set the resultant item to the dot product of a's corresponding column and b's corresponding row.
            for (0..COLS) |col| {
                for (0..ROWS) |row| {
                    result.m[col][row] = 0;
                    inline for (0..N) |i| {
                        result.m[col][row] += a.m[i][row] * b.m[col][i];
                    }
                }
            }

            return result;
        }

        pub fn set(mat: *Self, col: usize, row: usize, value: f32) void {
            mat.m[col][row] = value;
        }

        pub fn get(mat: *const Self, col: usize, row: usize) void {
            return mat.m[col][row];
        }
    };
}

const Mat4 = Mat(f32, 4);

test "mat4" {
    var a = Mat4.zero;
    a.set(3, 0, 1);
    const b = Mat4.identity;

    @import("std").debug.print("{any}\n", .{a.mul(&b)});
}
