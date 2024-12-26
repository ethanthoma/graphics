const std = @import("std");

const Vec3 = @import("math.zig").Vec3;
const Chunk = @import("Chunk.zig");
const Mesh = @import("Mesh.zig");

pub const ChunkManager = @This();

const RENDER_DISTANCE = 5;

allocator: std.mem.Allocator,

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
    var mesh_iter = self.chunk_meshes.iterator();
    while (mesh_iter.next()) |entry| {
        self.allocator.free(entry.value_ptr.points);
        self.allocator.free(entry.value_ptr.indices);
        self.allocator.free(entry.value_ptr.instances);
    }
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
        var y = min[1];
        while (y <= max[1]) : (y += 1) {
            var x = min[0];
            while (x <= max[0]) : (x += 1) {
                const pos = Vec3(i32){ x, y, z };

                // Skip if chunk is already loaded
                if (self.chunks.contains(pos)) continue;
                needs_new_mesh = true;

                // Create and initialize new chunk
                var chunk = Chunk.init(pos);
                try self.chunks.put(pos, chunk);

                // Generate and store mesh for the new chunk
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
