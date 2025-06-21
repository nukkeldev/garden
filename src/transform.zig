const zm = @import("zm");

/// 0th-Order 3D Transform.
pub const O0 = Transform(@splat(0), @splat(0), @splat(1));
/// 1st-Order (Velocity) 3D Transform.
pub const O1 = Transform(@splat(0), @splat(0), @splat(0));
/// 2nd-Order (Acceleration) 3D Transform.
pub const O2 = Transform(@splat(0), @splat(0), @splat(0));

pub const O012 = struct {
    o0: O0 = .{},
    o1: O1 = .{},
    o2: O2 = .{},

    /// Moves this struct forward by `dt` seconds.
    pub fn update(self: *@This(), dt: f32) void {
        self.o1.sumInPlace(&self.o2.times(dt));
        self.o0.sumInPlace(&self.o1.times(dt));
    }
};

/// A 3D transform.
pub fn Transform(
    comptime translation_default: zm.Vec3f,
    comptime rotation_default: zm.Vec3f,
    comptime scale_default: zm.Vec3f,
) type {
    return struct {
        translation: zm.Vec3f = translation_default,
        rotation: zm.Vec3f = rotation_default,
        scale: zm.Vec3f = scale_default,

        /// Local +Z
        pub fn forward(self: *const @This()) zm.Vec3f {
            return zm.Vec3f{
                @cos(self.rotation[1]) * @cos(self.rotation[0]),
                @sin(self.rotation[0]),
                @sin(self.rotation[1]) * @cos(self.rotation[0]),
            };
        }

        // Local +X
        pub fn right(self: *const @This()) zm.Vec3f {
            return zm.Vec3f{
                @sin(self.rotation[1]),
                0.0,
                -@cos(self.rotation[1]),
            };
        }

        /// Local +Y
        pub fn up(self: *const @This()) zm.Vec3f {
            const f = self.forward();
            const r = self.right();
            return zm.vec.cross(f, r);
        }

        /// Returns a new transform with all components multiplied by a scalar.
        pub fn times(self: *const @This(), scalar: f32) @This() {
            const splat: zm.Vec3f = @splat(scalar);
            return .{
                .translation = self.translation * splat,
                .rotation = self.rotation * splat,
                .scale = self.scale * splat,
            };
        }

        /// Sums all components of the two transforms into a new one.
        pub fn sum(self: *const @This(), other: anytype) @This() {
            return .{
                .translation = self.translation + other.translation,
                .rotation = self.rotation + other.rotation,
                .scale = self.scale + other.scale,
            };
        }

        /// Sums all components of the two transforms into the first one.
        pub fn sumInPlace(self: *@This(), other: anytype) void {
            self.translation += other.translation;
            self.rotation += other.rotation;
            self.scale += other.scale;
        }

        pub fn modelMatrix(self: *const @This()) zm.Mat4f {
            return zm.Mat4f.translationVec3(self.translation)
                .multiply(zm.Mat4f.rotation(zm.vec.right(f32), self.rotation[0]))
                .multiply(zm.Mat4f.rotation(zm.vec.up(f32), self.rotation[1]))
                .multiply(zm.Mat4f.rotation(zm.vec.forward(f32), self.rotation[2]))
                .multiply(zm.Mat4f.scaling(self.scale[0], self.scale[1], self.scale[2]));
        }
    };
}
