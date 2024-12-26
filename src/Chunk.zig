const std = @import("std");

const Mesh = @import("Mesh.zig");
const math = @import("math.zig");
const Vec3f = math.Vec3(f32);
const Vec3i = math.Vec3(i32);
const Mat4x4 = math.Mat4x4;

pub const CHUNK_SIZE = 5;

const Block = enum {
    air,
    solid,
};

const Chunk = @This();

data: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block,

pub fn init(position: Vec3i) Chunk {
    var chunk = Chunk{
        .data = undefined,
    };

    chunk.generateChunk(position);

    return chunk;
}

fn generateChunk(self: *Chunk, position: Vec3i) void {
    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (y == 0 and position[1] == 0) {
                    self.data[x][y][z] = .solid;
                } else {
                    self.data[x][y][z] = .air;
                }
            }
        }
    }
}

pub fn generateMesh(self: *Chunk, allocator: std.mem.Allocator, position: Vec3i) !Mesh {
    const front_face = &[_]Vec3f{
        .{ 0.0, 0.0, 1.0 }, // Bottom-left
        .{ 1.0, 0.0, 1.0 }, // Bottom-right
        .{ 1.0, 1.0, 1.0 }, // Top-right
        .{ 0.0, 0.0, 1.0 }, // Bottom-left
        .{ 1.0, 1.0, 1.0 }, // Top-right
        .{ 0.0, 1.0, 1.0 }, // Top-left
    };
    const back_face = &[_]Vec3f{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
    };
    const right_face = &[_]Vec3f{
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 1.0 },
    };
    const left_face = &[_]Vec3f{
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const top_face = &[_]Vec3f{
        .{ 0.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const bottom_face = &[_]Vec3f{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
    };

    const colors = [_]Vec3f{
        .{ 0, 0.1, 0 },
        .{ 0, 0.2, 0 },
        .{ 0, 0.3, 0 },
        .{ 0, 0.4, 0 },
        .{ 0, 0.5, 0 },
        .{ 0, 0.6, 0 },
        .{ 0, 0.7, 0 },
        .{ 0, 0.8, 0 },
        .{ 0, 0.9, 0 },
        .{ 0, 1.0, 0 },
    };

    var points = std.ArrayList(Mesh.Point).init(allocator);
    defer points.deinit();

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (self.data[x][y][z] != .solid) continue;

                const block_pos_in_chunk: Vec3i = @intCast(@Vector(3, usize){ x, y, z });
                const block_pos = position * @as(Vec3i, @splat(CHUNK_SIZE)) + block_pos_in_chunk;

                const color = colors[@abs(@rem(@reduce(.Add, position), @as(i32, @intCast(colors.len))))];

                try addFace(&points, block_pos, front_face, color);
                try addFace(&points, block_pos, back_face, color);
                try addFace(&points, block_pos, right_face, color);
                try addFace(&points, block_pos, left_face, color);
                try addFace(&points, block_pos, top_face, color);
                try addFace(&points, block_pos, bottom_face, color);
            }
        }
    }

    if (points.items.len != 0)
        std.debug.print("Chunk {}: generated mesh with {} vertices\n", .{ position, points.items.len });

    var instances = try allocator.alloc(Mesh.Instance, 1);
    instances[0] = Mesh.makeInstance(.{ 0, 0, 0 });

    return Mesh{
        .allocator = allocator,
        .points = try points.toOwnedSlice(),
        .instances = instances,
        .uniform = .{},
    };
}

fn addFace(points: *std.ArrayList(Mesh.Point), position: Vec3i, vertices: []const Vec3f, color: Vec3f) !void {
    for (vertices) |vertex| {
        try points.append(.{
            .position = @as(Vec3f, @floatFromInt(position)) + vertex,
            .color = color,
        });
    }
}
