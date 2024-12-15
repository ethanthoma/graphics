const Mesh = @This();

pub const Point = extern struct {
    position: Position,
    color: Color,

    pub const Position = [2]f32;
    pub const Color = [3]f32;
};

pub const Index = [3]u16;

pub const Uniform = struct {
    time: f32 align(4) = 1,
    scale: f32 align(4) = 1,
    _padding_1: u1 align(4) = undefined,
};

points: []const Point,
indices: []const Index,
uniform: Uniform,
