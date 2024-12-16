const std = @import("std");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4x4 = math.Mat4x4;

const Camera = @This();

position: Vec3 = .{ 0, 0, 5 },
target: Vec3 = .{ 0, 0, 0 },
up: Vec3 = .{ 0, 1, 0 },
fov: f32 = 45.0 * std.math.pi / 180.0,
aspect: f32 = 16 / 9,
near: f32 = 0.1,
far: f32 = 100,

pub fn getViewMatrix(self: Camera) Mat4x4 {
    const f = math.normalize(self.target - self.position);
    const s = math.normalize(math.cross(f, self.up));
    const u = math.cross(s, f);

    return .{
        s[0],                        u[0],                        -f[0],                      0.0,
        s[1],                        u[1],                        -f[1],                      0.0,
        s[2],                        u[2],                        -f[2],                      0.0,
        -math.dot(s, self.position), -math.dot(u, self.position), math.dot(f, self.position), 1.0,
    };
}

pub fn getProjectionMatrix(self: Camera) Mat4x4 {
    const f = 1.0 / @tan(self.fov / 2.0);

    return .{
        f / self.aspect, 0.0, 0.0,                                                   0.0,
        0.0,             f,   0.0,                                                   0.0,
        0.0,             0.0, (self.far + self.near) / (self.near - self.far),       -1.0,
        0.0,             0.0, (2.0 * self.far * self.near) / (self.near - self.far), 0.0,
    };
}

pub fn moveRelative(self: *Camera, velocity: Vec3) void {
    const forward = math.normalize(self.target - self.position);

    const right = math.normalize(math.cross(forward, self.up));

    const movement = Vec3{
        right[0] * velocity[0] + forward[0] * velocity[1],
        right[1] * velocity[0] + forward[1] * velocity[1],
        right[2] * velocity[0] + forward[2] * velocity[1],
    };

    self.position += movement;
    self.target += movement;
}
