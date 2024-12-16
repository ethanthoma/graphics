const std = @import("std");

const Mesh = @import("Mesh.zig");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4x4 = math.Mat4x4;

const CHUNK_SIZE = 2;

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

pub fn generateMesh(self: *Chunk, position: @Vector(3, i32), allocator: std.mem.Allocator) !Mesh {
    const front_face = &[_]Vec3{
        .{ -0.5, -0.5, 0.5 },
        .{ 0.5, -0.5, 0.5 },
        .{ 0.5, 0.5, 0.5 },
        .{ -0.5, 0.5, 0.5 },
    };
    const back_face = &[_]Vec3{
        .{ 0.5, -0.5, -0.5 },
        .{ -0.5, -0.5, -0.5 },
        .{ -0.5, 0.5, -0.5 },
        .{ 0.5, 0.5, -0.5 },
    };
    const right_face = &[_]Vec3{
        .{ 0.5, -0.5, 0.5 },
        .{ 0.5, -0.5, -0.5 },
        .{ 0.5, 0.5, -0.5 },
        .{ 0.5, 0.5, 0.5 },
    };
    const left_face = &[_]Vec3{
        .{ -0.5, -0.5, -0.5 },
        .{ -0.5, -0.5, 0.5 },
        .{ -0.5, 0.5, 0.5 },
        .{ -0.5, 0.5, -0.5 },
    };
    const top_face = &[_]Vec3{
        .{ -0.5, 0.5, 0.5 },
        .{ 0.5, 0.5, 0.5 },
        .{ 0.5, 0.5, -0.5 },
        .{ -0.5, 0.5, -0.5 },
    };
    const bottom_face = &[_]Vec3{
        .{ -0.5, -0.5, -0.5 },
        .{ 0.5, -0.5, -0.5 },
        .{ 0.5, -0.5, 0.5 },
        .{ -0.5, -0.5, 0.5 },
    };

    var points = std.ArrayList(Mesh.Point).init(allocator);
    var indices = std.ArrayList(Mesh.Index).init(allocator);

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (self.data[x][y][z] != .solid) continue;

                const block_pos = position * @as(@Vector(3, i32), @splat(CHUNK_SIZE)) + @Vector(3, i32){ @intCast(x), @intCast(y), @intCast(z) };

                const color = Vec3{ 0, 0.8, 0 };

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

fn addFace(points: *std.ArrayList(Mesh.Point), indices: *std.ArrayList(Mesh.Index), position: @Vector(3, i32), face_vertices: []const Vec3, color: Vec3) !void {
    const base_index: u16 = @truncate(points.items.len);

    for (face_vertices) |vertex| {
        const point = Mesh.Point{
            .position = @as(@Vector(3, f32), @floatFromInt(position)) + vertex,
            .color = color,
        };

        try points.append(point);
    }

    // Add indices for the face (two triangles)
    try indices.append(.{ @intCast(base_index + 0), @intCast(base_index + 1), @intCast(base_index + 2) });
    try indices.append(.{ @intCast(base_index + 0), @intCast(base_index + 2), @intCast(base_index + 3) });
}
