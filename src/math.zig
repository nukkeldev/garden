const std = @import("std");

/// N x M Matrix
/// (Internally) Column-Major
pub fn Mat(comptime T: type, N: comptime_int, M: comptime_int) type {
    const base = extern struct {
        m: [M][N]T,

        pub const TYPE = T;
        pub const ROWS = N;
        pub const COLS = M;

        const Self = @This();

        // Constants

        pub const zero = Self{ .m = [1][N]T{.{0} ** N} ** M };
        pub const one = Self{ .m = [1][N]T{.{1} ** N} ** M };

        pub const identity = b: {
            var res = Self.zero;
            if (N == M) {
                for (0..N) |i| {
                    res.set(i, i, 1);
                }
            }
            break :b res;
        };

        // Operations

        /// Returns the matrix multiplication of A, an N x M matrix, and B, an M x P matrix.
        pub fn mul(A: anytype, B: anytype) getProductType(@TypeOf(A), @TypeOf(B)) {
            const ResT = getProductType(@TypeOf(A), @TypeOf(B));
            var result = ResT.zero;

            // For each item of the matrix, set the resultant item to the dot product of a's corresponding column and b's corresponding row.
            for (0..ResT.COLS) |col| {
                for (0..ResT.ROWS) |row| {
                    result.m[col][row] = 0;
                    inline for (0..ResT.COLS) |i| {
                        result.m[col][row] += A.m[i][row] * B.m[col][i];
                    }
                }
            }

            return result;
        }

        /// Returns the transpose of `self`, swapping columns with rows.
        pub fn transpose(self: *const Self) Mat(T, M, N) {
            var result = Mat(T, M, N).zero;

            for (0..COLS) |col| {
                for (0..ROWS) |row| {
                    result.m[row][col] = self.m[col][row];
                }
            }

            return result;
        }

        // Helper Functions

        pub fn scale(x: T, y: T, z: T) Self {
            return Self{ .m = [COLS][ROWS]T{
                .{ x, 0, 0, 0 },
                .{ 0, y, 0, 0 },
                .{ 0, 0, z, 0 },
                .{ 0, 0, 0, 1 },
            } };
        }

        pub fn translation(x: T, y: T, z: T) Self {
            return Self{ .m = [COLS][ROWS]T{
                .{ 1, 0, 0, x },
                .{ 0, 1, 0, y },
                .{ 0, 0, 1, z },
                .{ 0, 0, 0, 1 },
            } };
        }

        pub fn rotateX(radians: T) Self {
            // zig fmt: off
            return Self{ .m = [COLS][ROWS]T{
                .{ 1,             0,              0, 0 },
                .{ 0, @cos(radians), -@sin(radians), 0 },
                .{ 0, @sin(radians),  @cos(radians), 0 },
                .{ 0,             0,              0, 1 },
            } };
            // zig fmt: on
        }

        pub fn rotateY(radians: T) Self {
            // zig fmt: off
            return Self{ .m = [COLS][ROWS]T{
                .{  @cos(radians), 0, @sin(radians), 0 },
                .{              0, 1,             0, 0 },
                .{ -@sin(radians), 0, @cos(radians), 0 },
                .{              0, 0,             0, 1 },
            } };
            // zig fmt: on
        }

        pub fn rotateZ(radians: T) Self {
            // zig fmt: off
            return Self{ .m = [COLS][ROWS]T{
                .{ @cos(radians), -@sin(radians), 0, 0 },
                .{ @sin(radians),  @cos(radians), 0, 0 },
                .{             0,              0, 1, 0 },
                .{             0,              0, 0, 1 },
            } };
            // zig fmt: on
        }

        pub fn _rotateAround(axis: Mat(T, N, 1), radians: T) Self {
            _ = axis;
            _ = radians;

            @panic("Not yet implemented.");
        }

        // Lower-Level Interactions

        /// Sets the matrix's element at [`row`, `column`] to `value`.
        pub fn set(self: *Self, col: usize, row: usize, value: T) void {
            self.m[col][row] = value;
        }

        /// Returns the matrix's element at [`row`, `column`].
        pub fn get(self: *const Self, col: usize, row: usize) T {
            return self.m[col][row];
        }

        // Comptime Checks

        /// Expects `ty` to be a matrix type (or a pointer of one).
        fn expectMatrix(comptime ty: type) type {
            var mat: type = ty;

            // If the supplied is a matrix, get to the child non-pointer type.
            b: switch (@typeInfo(ty)) {
                .pointer => |p| {
                    mat = p.child;
                    continue :b @typeInfo(mat);
                },
                .@"struct" => break :b,
                else => @compileError("Not struct :("),
            }

            // Check for the matrix's marker.
            if (!@hasDecl(mat, "__matrix")) {
                @compileError("Supplied type is not a matrix.");
            }

            // Return the matrix type.
            return mat;
        }

        /// Returns the resultant matrix type from multiplying a and b.
        fn getProductType(comptime a: type, comptime b: type) type {
            // Check if our two arguments are matricies and, if so, return the underlying matrix type (pointerless).
            const A = expectMatrix(a);
            const B = expectMatrix(b);

            // Check compatibility for matrix multiplication.
            if (A.TYPE != B.TYPE) @compileError("Matricies underlying types don't match.");
            if (A.COLS != B.ROWS) @compileError("Matricies have incompatible dimensions.");

            // Return the resultant type.
            return Mat(A.TYPE, A.ROWS, B.COLS);
        }

        /// An indicator to mark this type as a matrix.
        pub const __matrix = 0;
    };

    return base;
}

pub const Mat4 = Mat(f32, 4, 4);
pub const Vec4 = Mat(f32, 4, 1);

test "matrix multiplication" {}
