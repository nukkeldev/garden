const zm = @import("zm");

pub const DynamicTransform = struct {
    translation: zm.Vec3f = @splat(0),
    rotation: zm.Vec3f = @splat(0),
    scale: zm.Vec3f = @splat(1),

    translational_velocity: zm.Vec3f = @splat(0),
    rotational_velocity: zm.Vec3f = @splat(0),
    scale_velocity: zm.Vec3f = @splat(0),

    translational_acceleration: zm.Vec3f = @splat(0),
    rotational_acceleration: zm.Vec3f = @splat(0),
    scale_acceleration: zm.Vec3f = @splat(0),

    /// Local +Z
    pub fn forward(t: *const @This()) zm.Vec3f {
        return zm.Vec3f{
            @cos(t.rotation[1]) * @cos(t.rotation[0]),
            @sin(t.rotation[0]),
            @sin(t.rotation[1]) * @cos(t.rotation[0]),
        };
    }

    // Local +X
    pub fn right(t: *const @This()) zm.Vec3f {
        return zm.Vec3f{
            @sin(t.rotation[1]),
            0.0,
            -@cos(t.rotation[1]),
        };
    }

    /// Local +Y
    pub fn up(t: *const @This()) zm.Vec3f {
        const f = t.forward();
        const r = t.right();
        return zm.vec.cross(f, r);
    }

    /// Returns a new t with all components multiplied by a scalar.
    pub fn times(t: *const @This(), scalar: f32) @This() {
        const splat: zm.Vec3f = @splat(scalar);
        return .{
            .translation = t.translation * splat,
            .rotation = t.rotation * splat,
            .scale = t.scale * splat,
        };
    }

    /// Sums all components of the two ts into a new one.
    pub fn sum(t: *const @This(), other: anytype) @This() {
        return .{
            .translation = t.translation + other.translation,
            .rotation = t.rotation + other.rotation,
            .scale = t.scale + other.scale,
        };
    }

    /// Sums all components of the two ts into the first one.
    pub fn sumInPlace(t: *@This(), other: anytype) void {
        t.translation += other.translation;
        t.rotation += other.rotation;
        t.scale += other.scale;
    }

    pub fn modelMatrix(t: *const @This()) zm.Mat4f {
        return zm.Mat4f.translationVec3(t.translation)
            .multiply(zm.Mat4f.rotation(zm.vec.right(f32), t.rotation[0]))
            .multiply(zm.Mat4f.rotation(zm.vec.up(f32), t.rotation[1]))
            .multiply(zm.Mat4f.rotation(zm.vec.forward(f32), t.rotation[2]))
            .multiply(zm.Mat4f.scaling(t.scale[0], t.scale[1], t.scale[2]));
    }

    pub fn update(t: *@This(), dt: f32) void {
        const dt_3: zm.Vec3f = @splat(dt);
        t.translational_velocity += t.translational_acceleration * dt_3;
        t.translation += t.translational_velocity * dt_3;
        t.rotational_velocity += t.rotational_acceleration * dt_3;
        t.rotation += t.rotational_velocity * dt_3;
        t.scale_velocity += t.scale_acceleration * dt_3;
        t.scale += t.scale_velocity * dt_3;
    }
};

pub const StaticTransform = struct {
    translation: zm.Vec3f = @splat(0),
    rotation: zm.Vec3f = @splat(0),
    scale: zm.Vec3f = @splat(1),
};
