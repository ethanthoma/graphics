const std = @import("std");

const gpu = @import("wgpu");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec3f = math.Vec3(f32);
const Mat4x4 = math.Mat4x4;

const Mesh = @This();

pub const MAX_BUFFER_SIZE = 16 ^ 3 * @sizeOf(Point) * 5 ^ 3;

pub const Point = struct {
    pub const shader_type = .buffer;
    pub const buffer_type = .instance;
    pub const vertex_count = 6;

    voxel: packed struct {
        position: Position,
        normal: Normal,
        texture: Point.Texture,
    } align(4),

    pub const Position = Vec3(u6);

    pub const Normal = enum(u3) {
        right,
        left,
        up,
        down,
        front,
        back,
    };

    pub const Texture = enum(u7) {
        grass,
    };
};

pub const Camera = struct {
    pub const shader_type = .buffer;
    pub const buffer_type = .uniform;
    pub const bind_group = 0;
    pub const binding = 0;
    pub const visibility = gpu.ShaderStages.vertex | gpu.ShaderStages.fragment;

    projection: Mat4x4(f32) = .{},
    view: Mat4x4(f32) = .{},
};

pub const Texture = struct {
    pub const shader_type = .texture;
    pub const buffer_type = .texture;
    pub const bind_group = 0;
    pub const binding = 1;
    pub const format: gpu.TextureFormat = .rgba8_unorm;
    pub const visibility = gpu.ShaderStages.fragment;

    size: [2]usize,
    data: []const Color,

    pub const Color = @Vector(4, u8);
};

pub const Chunk = struct {
    pub const shader_type = .constant;
    pub const visibility = gpu.ShaderStages.vertex;

    position: Vec3(i32),
};

pub const Indirect = packed struct(u128) {
    pub const shader_type = .buffer;
    pub const buffer_type = .indirect;

    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

allocator: std.mem.Allocator,
points: []const Point,
camera: Camera,
texture: Texture = .{ .size = undefined, .data = undefined },
chunks: []const Chunk,
indirects: []const Indirect,

pub fn init(allocator: std.mem.Allocator, points: []const Point) Mesh {
    return .{
        .allocator = allocator,
        .points = allocator.dupe(Point, points),
        .uniform = .{},
    };
}

pub fn deinit(self: *const Mesh) void {
    self.allocator.free(self.points);
}

// TODO: this should be user defined in the struct type
pub fn getMaxBufferSize() comptime_int {
    const chunk_dim = (2 * @import("ChunkManager.zig").RENDER_DISTANCE) + 1;
    const chunk_size = @import("Chunk.zig").CHUNK_SIZE;

    const point = @sizeOf(Point);
    const voxel = 6 * point;
    const chunk = (chunk_size * chunk_size * chunk_size) * voxel;
    const world = chunk * (chunk_dim * chunk_dim * chunk_dim);
    return world;
}

// TODO: requirements like these can be auto-generated via shader.zig

pub fn getMaxUniformBufferBindingSize() comptime_int {
    var size = 0;
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        const field = @field(@This(), decl.name);

        if (@TypeOf(field) != type) continue;
        if (!@hasDecl(field, "buffer_type")) continue;
        if (field.buffer_type != .uniform) continue;

        size += @sizeOf(field);
    }
    return size;
}

pub fn getMaxVertexBufferArrayStride() comptime_int {
    var stride = 0;
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        const field = @field(@This(), decl.name);

        if (@TypeOf(field) != type) continue;
        if (!@hasDecl(field, "buffer_type")) continue;
        if (field.buffer_type != .vertex and field.buffer_type != .instance) continue;

        for (std.meta.fields(field)) |sub_field| {
            if (stride < @sizeOf(sub_field.type)) stride = @sizeOf(sub_field.type);
        }
    }

    return stride;
}

pub fn getMaxStorageBufferBindingSize() comptime_int {
    const chunk_dim = (2 * @import("ChunkManager.zig").RENDER_DISTANCE) + 1;

    return @sizeOf(Mesh.Chunk) * (chunk_dim * chunk_dim * chunk_dim);
}

pub fn getMaxVertexBuffers() comptime_int {
    var count = 0;
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        const field = @field(@This(), decl.name);

        if (@TypeOf(field) != type) continue;
        if (!@hasDecl(field, "buffer_type")) continue;
        if (field.buffer_type != .vertex and field.buffer_type != .instance) continue;

        count += 1;
    }
    return count;
}

pub fn getMaxPushSize() comptime_int {
    var size = 0;
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        const field = @field(@This(), decl.name);

        if (@TypeOf(field) != type) continue;
        if (!@hasDecl(field, "shader_type")) continue;
        if (field.shader_type != .constant) continue;

        size += @sizeOf(field);
    }
    return size;
}
