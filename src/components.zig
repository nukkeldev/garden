const zm = @import("zm");

pub const Transform1 = struct { x: zm.Vec3f = .{ 0, 0, 0 }, r: zm.Vec3f = .{ 0, 0, 0 } };
pub const Transform2 = struct { v: zm.Vec3f = .{ 0, 0, 0 }, vr: zm.Vec3f = .{ 0, 0, 0 } };
pub const Transform3 = struct { a: zm.Vec3f = .{ 0, 0, 0 }, ar: zm.Vec3f = .{ 0, 0, 0 } };
