const Mesh = @This();

pub const Point = extern struct {
    position: Position,
    color: Color,

    pub const Position = [2]f32;
    pub const Color = [3]f32;
};

pub const Index = [3]u16;

pub const Uniform = struct {
    color: [4]f32 align(16),
    time: f32 align(16) = 1,
    _padding: u1 align(16) = undefined,
};

points: []const Point,
indices: []const Index,
uniform: Uniform,
