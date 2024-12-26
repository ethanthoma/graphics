const std = @import("std");

const Vec3 = @import("math.zig").Vec3;
const Chunk = @import("Chunk.zig");
const Mesh = @import("Mesh.zig");
const Noise = @import("noise.zig").Noise;

pub const ChunkManager = @This();

const RENDER_DISTANCE = 5;

allocator: std.mem.Allocator,

noise: Noise = Noise.init(12345),
chunks: std.AutoArrayHashMap(Vec3(i32), Chunk),
chunk_meshes: std.AutoArrayHashMap(Vec3(i32), Mesh),

pub fn init(allocator: std.mem.Allocator) ChunkManager {
    return .{
        .allocator = allocator,
        .chunks = std.AutoArrayHashMap(Vec3(i32), Chunk).init(allocator),
        .chunk_meshes = std.AutoArrayHashMap(Vec3(i32), Mesh).init(allocator),
    };
}

pub fn deinit(self: *ChunkManager) void {
    for (self.chunk_meshes.values()) |*mesh| mesh.deinit();
    self.chunk_meshes.deinit();
    self.chunks.deinit();
    self.allocator.destroy(self);
}

pub fn update(self: *ChunkManager, position: Vec3(f32)) !?Mesh {
    const position_chunk = .{
        @divFloor(@as(i32, @intFromFloat(position[0])), Chunk.CHUNK_SIZE),
        @divFloor(@as(i32, @intFromFloat(position[1])), Chunk.CHUNK_SIZE),
        @divFloor(@as(i32, @intFromFloat(position[2])), Chunk.CHUNK_SIZE),
    };

    const min = Vec3(i32){
        position_chunk[0] - RENDER_DISTANCE,
        position_chunk[1] - RENDER_DISTANCE,
        position_chunk[2] - RENDER_DISTANCE,
    };
    const max = Vec3(i32){
        position_chunk[0] + RENDER_DISTANCE,
        position_chunk[1] + RENDER_DISTANCE,
        position_chunk[2] + RENDER_DISTANCE,
    };

    if (try self.loadChunksInRange(min, max) or
        try self.unloadChunksOutOfRange(min, max))
        return try self.getMergedMesh();

    return null;
}

fn loadChunksInRange(self: *ChunkManager, min: Vec3(i32), max: Vec3(i32)) !bool {
    var needs_new_mesh = false;

    var z = min[2];
    while (z <= max[2]) : (z += 1) {
        var y = @min(min[1], 0);
        const max_y = @min(max[1], 0);
        while (y <= max_y) : (y += 1) {
            var x = min[0];
            while (x <= max[0]) : (x += 1) {
                const pos = Vec3(i32){ x, y, z };

                if (self.chunks.contains(pos)) continue;
                needs_new_mesh = true;

                var chunk: Chunk = .{ .data = undefined };
                self.generateChunkTerrain(pos, &chunk.data);
                try self.chunks.put(pos, chunk);

                const mesh = try chunk.generateMesh(self.allocator, pos);
                try self.chunk_meshes.put(pos, mesh);
            }
        }
    }

    return needs_new_mesh;
}

fn unloadChunksOutOfRange(self: *ChunkManager, min: Vec3(i32), max: Vec3(i32)) !bool {
    var needs_new_mesh = false;

    var chunk_iter = self.chunks.iterator();
    while (chunk_iter.next()) |entry| {
        const pos = entry.key_ptr.*;

        if (pos[0] < min[0] or pos[0] > max[0] or
            pos[1] < min[1] or pos[1] > max[1] or
            pos[2] < min[2] or pos[2] > max[2])
        {
            if (self.chunk_meshes.getPtr(pos)) |mesh| {
                mesh.deinit();
                needs_new_mesh = true;
            }

            _ = self.chunk_meshes.swapRemove(pos);
            _ = self.chunks.swapRemove(pos);
        }
    }

    return needs_new_mesh;
}

pub fn getMergedMesh(self: *ChunkManager) !Mesh {
    var all_points = std.ArrayList(Mesh.Point).init(self.allocator);
    defer all_points.deinit();

    var mesh_iter = self.chunk_meshes.iterator();
    while (mesh_iter.next()) |entry| {
        const mesh = entry.value_ptr;
        try all_points.appendSlice(mesh.points);
    }

    return .{
        .allocator = self.allocator,
        .points = try all_points.toOwnedSlice(),
        .instances = try self.allocator.dupe(
            Mesh.Instance,
            &[_]Mesh.Instance{Mesh.makeInstance(.{ 0, 0, 0 })},
        ),
        .uniform = .{},
    };
}

pub fn generateChunkTerrain(
    self: *const ChunkManager,
    chunk_pos: Vec3(i32),
    data: *[Chunk.CHUNK_SIZE][Chunk.CHUNK_SIZE][Chunk.CHUNK_SIZE]Chunk.Block,
) void {
    const base_x = chunk_pos[0] * Chunk.CHUNK_SIZE;
    const base_z = chunk_pos[2] * Chunk.CHUNK_SIZE;

    for (0..Chunk.CHUNK_SIZE) |x| {
        for (0..Chunk.CHUNK_SIZE) |z| {
            const world_x = base_x + @as(i32, @intCast(x));
            const world_z = base_z + @as(i32, @intCast(z));
            const height = self.getTerrainHeight(world_x, world_z);

            for (0..Chunk.CHUNK_SIZE) |y| {
                const world_y = chunk_pos[1] * Chunk.CHUNK_SIZE + @as(i32, @intCast(y));
                data[x][y][z] = if (world_y <= height) .solid else .air;
            }
        }
    }
}

fn getTerrainHeight(self: *const ChunkManager, x: i32, z: i32) i32 {
    const scale = 0.05;
    const height_scale = -20.0;

    const noise_val = self.noise.octaves2d(
        @as(f32, @floatFromInt(x)) * scale,
        @as(f32, @floatFromInt(z)) * scale,
        4,
        0.5,
    );

    return @intFromFloat(noise_val * height_scale);
}
