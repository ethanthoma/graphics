const std = @import("std");

const Mesh = @import("Mesh.zig");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec3f = math.Vec3(f32);
const Vec3i = math.Vec3(i32);
const Mat4x4 = math.Mat4x4;

pub const CHUNK_SIZE = 32;

pub const Block = enum {
    air,
    solid,
};

const Chunk = @This();

data: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block,

pub fn init() Chunk {
    var chunk = Chunk{
        .data = undefined,
    };

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                chunk.data[x][y][z] = .air;
            }
        }
    }

    return chunk;
}

pub fn generateMesh(self: *Chunk, allocator: std.mem.Allocator, position: Vec3i) !?Mesh {
    var points = std.ArrayList(Mesh.Point){};
    defer points.deinit(allocator);

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (self.data[x][y][z] != .solid) continue;

                const block_pos = Vec3(u6){ @intCast(x), @intCast(y), @intCast(z) };

                try addFace(allocator, &points, block_pos, .right, .grass);
                try addFace(allocator, &points, block_pos, .left, .grass);
                try addFace(allocator, &points, block_pos, .up, .grass);
                try addFace(allocator, &points, block_pos, .down, .grass);
                try addFace(allocator, &points, block_pos, .front, .grass);
                try addFace(allocator, &points, block_pos, .back, .grass);
            }
        }
    }

    if (points.items.len == 0) return null;

    std.debug.print("Chunk {}: generated mesh with {} vertices\n", .{ position, points.items.len });

    const indirect = Mesh.Indirect{
        .vertex_count = 6,
        .instance_count = @intCast(points.items.len),
        .first_vertex = 0,
        .first_instance = 0,
    };

    return Mesh{
        .allocator = allocator,
        .points = try points.toOwnedSlice(allocator),
        .chunks = try allocator.dupe(Mesh.Chunk, &[_]Mesh.Chunk{.{ .position = position }}),
        .camera = .{},
        .indirects = try allocator.dupe(Mesh.Indirect, &[_]Mesh.Indirect{indirect}),
    };
}

fn addFace(
    allocator: std.mem.Allocator,
    points: *std.ArrayList(Mesh.Point),
    position: Vec3(u6),
    normal: Mesh.Point.Normal,
    texture: Mesh.Point.Texture,
) !void {
    try points.append(allocator, .{
        .voxel = .{
            .position = position,
            .normal = normal,
            .texture = texture,
        },
    });
}
