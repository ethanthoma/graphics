const Mesh = @This();

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4x4 = math.Mat4x4;

pub const Point = extern struct {
    position: Position,
    color: Color,

    pub const Position = [3]f32;
    pub const Color = [3]f32;
};

pub const Index = [3]u16;

pub const Uniform = struct {
    projection: Mat4x4 align(16) = @splat(0),
    view: Mat4x4 align(16) = @splat(0),
    model: Mat4x4 align(16) = @splat(0),
    _padding: u1 align(4) = undefined,
};

points: []const Point,
indices: []const Index,
uniform: Uniform,
