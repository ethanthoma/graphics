pub const DataType = enum {
    Vector,
    Matrix,
};

pub fn Vec2(comptime T: type) type {
    return @Vector(2, T);
}

pub fn Vec3(comptime T: type) type {
    return @Vector(3, T);
}

pub fn normalize(v: Vec3(f32)) Vec3(f32) {
    return v / @as(Vec3(f32), @splat(@sqrt(@reduce(.Add, v * v))));
}

// https://geometrian.com/programming/tutorials/cross-product/index.php
pub fn cross(a: Vec3(f32), b: @TypeOf(a)) @TypeOf(a) {
    const tmp0 = @shuffle(f32, a, undefined, @Vector(3, i8){ 1, 2, 0 });
    const tmp1 = @shuffle(f32, b, undefined, @Vector(3, i8){ 2, 0, 1 });
    const tmp2 = tmp0 * b;
    const tmp3 = tmp0 * tmp1;
    const tmp4 = @shuffle(f32, tmp2, undefined, @Vector(3, i8){ 1, 2, 0 });

    return tmp3 - tmp4;
}

pub fn dot(a: Vec3(f32), b: Vec3(f32)) f32 {
    return @reduce(.Add, a * b);
}

pub fn Mat4x4(comptime T: type) type {
    return extern struct {
        pub const data_type: DataType = .Matrix;
        pub const shape = .{ 4, 4 };

        data: @Vector(16, T) = @splat(0),
    };
}
