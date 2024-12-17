const std = @import("std");

const math = @import("math.zig");
const Vec3f = math.Vec3(f32);
const Vec2f = math.Vec2(f32);
const Mat4x4 = math.Mat4x4;

const Camera = @This();

position: Vec3f = .{ 0, 0, 16 },
target: Vec3f = .{ 0, 0, 0 },
up: Vec3f = .{ 0, 1, 0 },
fov: f32 = 45.0 * std.math.pi / 180.0,
aspect: f32 = 16 / 9,
near: f32 = 0.1,
far: f32 = 100,
yaw: f32 = -90.0,
pitch: f32 = 0.0,

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

pub fn moveRelative(self: *Camera, velocity: Vec3f) void {
    const forward = math.normalize(self.target - self.position);
    const right = math.normalize(math.cross(forward, self.up));

    const planar_movement = Vec3f{
        right[0] * velocity[0] + forward[0] * velocity[2],
        right[1] * velocity[0] + forward[1] * velocity[2],
        right[2] * velocity[0] + forward[2] * velocity[2],
    };

    const movement = planar_movement + Vec3f{ 0, velocity[1], 0 };

    self.position += movement;
    self.target += movement;
}

pub fn rotate(self: *Camera, rotation: Vec2f) void {
    self.yaw += rotation[0];
    self.pitch += rotation[1];

    self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);

    const direction = Vec3f{
        @cos(self.yaw * std.math.pi / 180.0) * @cos(self.pitch * std.math.pi / 180.0),
        @sin(self.pitch * std.math.pi / 180.0),
        @sin(self.yaw * std.math.pi / 180.0) * @cos(self.pitch * std.math.pi / 180.0),
    };

    self.target = self.position + direction;
}
