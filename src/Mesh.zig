const std = @import("std");

const math = @import("math.zig");
const Vec3f = math.Vec3(f32);
const Mat4x4 = math.Mat4x4;

const Mesh = @This();

pub const Point = extern struct {
    position: Position,
    color: Color,

    pub const Position = Vec3f;
    pub const Color = Vec3f;
};

pub const Index = [3]u16;

pub const Uniform = struct {
    projection: Mat4x4 align(16) = @splat(0),
    view: Mat4x4 align(16) = @splat(0),
    _padding: u1 align(4) = undefined,
};

pub const Instance = Mat4x4;

points: []const Point,
indices: []const Index,
instances: []const Instance,
uniform: Uniform,

pub fn makeInstance(position: Vec3f) Instance {
    return math.Mat4x4{
        1,           0,           0,           0,
        0,           1,           0,           0,
        0,           0,           1,           0,
        position[0], position[1], position[2], 1,
    };
}

pub fn getMaxBufferSize(mesh: Mesh) usize {
    var max_buffer_size: usize = 0;

    inline for (comptime std.meta.fields(Mesh)) |field| {
        const value = @field(mesh, field.name);

        const buffer_size = switch (@typeInfo(field.type)) {
            .pointer => |ptr| switch (ptr.size) {
                .Slice => value.len * @sizeOf(ptr.child),
                else => @compileError("shaders do not support pointers"),
            },
            else => @sizeOf(field.type),
        };

        max_buffer_size = if (buffer_size > max_buffer_size) buffer_size else max_buffer_size;
    }

    return max_buffer_size;
}

pub fn getMaxUniformBufferBindingSize(mesh: Mesh) usize {
    _ = mesh;

    return @sizeOf(Uniform);
}
