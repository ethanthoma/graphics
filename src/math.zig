pub const Vec3 = @Vector(3, f32);
pub const Mat4x4 = @Vector(16, f32);

pub fn normalize(v: Vec3) Vec3 {
    return v / @as(Vec3, @splat(@sqrt(@reduce(.Add, v * v))));
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}
