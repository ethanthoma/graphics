pub const Vec3 = @Vector(3, f32);
pub const Mat4x4 = @Vector(16, f32);

pub fn normalize(v: Vec3) Vec3 {
    return v / @as(Vec3, @splat(@sqrt(@reduce(.Add, v * v))));
}

// https://geometrian.com/programming/tutorials/cross-product/index.php
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    const tmp0 = @shuffle(f32, a, undefined, @Vector(3, i8){ 1, 2, 0 });
    const tmp1 = @shuffle(f32, b, undefined, @Vector(3, i8){ 2, 0, 1 });
    const tmp2 = tmp0 * b;
    const tmp3 = tmp0 * tmp1;
    const tmp4 = @shuffle(f32, tmp2, undefined, @Vector(3, i8){ 1, 2, 0 });

    return tmp3 - tmp4;
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}
