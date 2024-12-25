const std = @import("std");

const math = @import("math.zig");
const Vec3f = math.Vec3(f32);
const Vec2f = math.Vec2(f32);
const Mat4x4 = math.Mat4x4;

const Camera = @This();

position: Vec3f = .{ 0, 5, 0 },
up: Vec3f = .{ 0, 1, 0 },
fov: f32 = 45.0 * std.math.pi / 180.0,
aspect: f32 = 16 / 9,
near: f32 = 0.1,
far: f32 = 100,
yaw: f32 = -90.0,
pitch: f32 = 0.0,

pub fn getViewMatrix(self: Camera) Mat4x4(f32) {
    const front = self.getFront();
    const s = math.normalize(math.cross(front, self.up));
    const u = math.cross(s, front);

    return .{ .data = .{
        s[0],                        u[0],                        -front[0],                      0.0,
        s[1],                        u[1],                        -front[1],                      0.0,
        s[2],                        u[2],                        -front[2],                      0.0,
        -math.dot(s, self.position), -math.dot(u, self.position), math.dot(front, self.position), 1.0,
    } };
}

pub fn getProjectionMatrix(self: Camera) Mat4x4(f32) {
    const f = 1.0 / @tan(self.fov / 2.0);

    return .{ .data = .{
        f / self.aspect, 0.0, 0.0,                                                   0.0,
        0.0,             f,   0.0,                                                   0.0,
        0.0,             0.0, (self.far + self.near) / (self.near - self.far),       -1.0,
        0.0,             0.0, (2.0 * self.far * self.near) / (self.near - self.far), 0.0,
    } };
}

pub fn moveRelative(self: *Camera, velocity: Vec3f) void {
    const front = self.getFront();
    const right = math.normalize(math.cross(front, self.up));

    const planar_movement = Vec3f{
        right[0] * velocity[0] + front[0] * velocity[2],
        right[1] * velocity[0] + front[1] * velocity[2],
        right[2] * velocity[0] + front[2] * velocity[2],
    };

    const movement = planar_movement + Vec3f{ 0, velocity[1], 0 };
    self.position += movement;
}

pub fn getFront(self: Camera) Vec3f {
    return .{
        @cos(self.yaw * std.math.pi / 180.0) * @cos(self.pitch * std.math.pi / 180.0),
        @sin(self.pitch * std.math.pi / 180.0),
        @sin(self.yaw * std.math.pi / 180.0) * @cos(self.pitch * std.math.pi / 180.0),
    };
}

pub fn rotate(self: *Camera, rotation: Vec2f) void {
    self.yaw += rotation[0];
    self.pitch += rotation[1];
    self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);
}

pub fn lookAt(self: *Camera, target: Vec3f) void {
    const direction = target - self.position;

    const length = @sqrt(direction[0] * direction[0] + direction[2] * direction[2]);
    self.pitch = std.math.atan2(direction[1], length) * 180.0 / std.math.pi;

    self.yaw = std.math.atan2(direction[2], direction[0]) * 180.0 / std.math.pi;

    self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);
}
