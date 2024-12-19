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

pub fn init() Chunk {
    var chunk = Chunk{
        .data = undefined,
    };

    chunk.generateChunk();

    return chunk;
}

fn generateChunk(self: *Chunk) void {
    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (y == 0) {
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
        .{ 0.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
    };
    const back_face = &[_]Vec3f{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
    };
    const right_face = &[_]Vec3f{
        .{ 1.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 1.0, 1.0, 1.0 },
    };
    const left_face = &[_]Vec3f{
        .{ 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 1.0, 1.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const top_face = &[_]Vec3f{
        .{ 0.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 1.0 },
        .{ 1.0, 1.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const bottom_face = &[_]Vec3f{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
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
    var indices = std.ArrayList(Mesh.Index).init(allocator);
    defer indices.deinit();

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (self.data[x][y][z] != .solid) continue;

                const block_pos = position * @as(@Vector(3, i32), @splat(CHUNK_SIZE)) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };

                const color = colors[@as(usize, @intCast(@reduce(.Add, position))) % colors.len];

                try addFace(&points, &indices, block_pos, front_face, color);
                try addFace(&points, &indices, block_pos, back_face, color);
                try addFace(&points, &indices, block_pos, right_face, color);
                try addFace(&points, &indices, block_pos, left_face, color);
                try addFace(&points, &indices, block_pos, top_face, color);
                try addFace(&points, &indices, block_pos, bottom_face, color);
            }
        }
    }

    std.debug.print("Generated mesh with {} vertices and {} indices\n", .{ points.items.len, indices.items.len });

    var instances = try allocator.alloc(Mesh.Instance, 1);
    instances[0] = Mesh.makeInstance(.{ 0, 0, 0 });

    return Mesh{
        .points = try points.toOwnedSlice(),
        .indices = try indices.toOwnedSlice(),
        .instances = instances,
        .uniform = .{},
    };
}

fn addFace(points: *std.ArrayList(Mesh.Point), indices: *std.ArrayList(Mesh.Index), position: Vec3i, face_vertices: []const Vec3f, color: Vec3f) !void {
    const base_index: u16 = @truncate(points.items.len);

    for (face_vertices) |vertex| {
        const point = Mesh.Point{
            .position = @as(Vec3f, @floatFromInt(position)) + vertex,
            .color = color,
        };

        try points.append(point);
    }

    // Add indices for the face (two triangles)
    try indices.append(.{ @intCast(base_index + 0), @intCast(base_index + 1), @intCast(base_index + 2) });
    try indices.append(.{ @intCast(base_index + 0), @intCast(base_index + 2), @intCast(base_index + 3) });
}
