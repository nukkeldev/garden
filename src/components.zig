const zm = @import("zm");

const Object = @import("object.zig").Object;

pub const Group_Transform = .{ Position, Velocity, Acceleration };

pub const Position = struct {
    x: zm.Vec3f = .{ 0, 0, 0 },
    r: zm.Vec3f = .{ 0, 0, 0 },

    pub fn forward(self: *const @This()) zm.Vec3f {
        return zm.Vec3f{
            @cos(self.r[1]) * @cos(self.r[0]),
            @sin(self.r[0]),
            @sin(self.r[1]) * @cos(self.r[0]),
        };
    }

    pub fn right(self: *const @This()) zm.Vec3f {
        return zm.Vec3f{
            @sin(self.r[1]),
            0.0,
            -@cos(self.r[1]),
        };
    }

    pub fn up(self: *const @This()) zm.Vec3f {
        const f = self.forward();
        const r = self.right();
        return zm.vec.cross(f, r);
    }
};
pub const Velocity = struct { v: zm.Vec3f = .{ 0, 0, 0 }, vr: zm.Vec3f = .{ 0, 0, 0 } };
pub const Acceleration = struct { a: zm.Vec3f = .{ 0, 0, 0 }, ar: zm.Vec3f = .{ 0, 0, 0 } };
pub const Scale = struct { scale: zm.Vec3f = .{ 1, 1, 1 } };
pub const Renderable = struct { objects: []Object };
