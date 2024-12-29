const std = @import("std");

const gpu = @import("wgpu");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec3f = math.Vec3(f32);
const Mat4x4 = math.Mat4x4;

const Mesh = @This();
const BufferTypeClass = @import("buffer.zig").BufferTypeClass;

pub const MAX_BUFFER_SIZE = 16 ^ 3 * @sizeOf(Point) * 5 ^ 3;

pub const Point = struct {
    pub const buffer_type: BufferTypeClass = .instance;
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
    pub const buffer_type: BufferTypeClass = .uniform;
    pub const bind_group = 0;
    pub const binding = 0;
    pub const visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment;

    projection: Mat4x4(f32) align(16) = .{},
    view: Mat4x4(f32) align(16) = .{},
    _padding: u1 align(16) = undefined,
};

pub const Texture = struct {
    pub const buffer_type: BufferTypeClass = .texture;
    pub const bind_group = 0;
    pub const binding = 1;
    pub const format: gpu.TextureFormat = .rgba8_unorm;
    pub const visibility = gpu.ShaderStage.fragment;

    size: [2]usize,
    data: []const Color,

    pub const Color = @Vector(4, u8);
};

pub const Chunk = struct {
    pub const buffer_type: BufferTypeClass = .storage;
    pub const bind_group = 0;
    pub const binding = 2;
    pub const visibility = gpu.ShaderStage.fragment;

    position: Vec3(i32) align(16),
    _padding: u1 align(16) = undefined,
};

allocator: std.mem.Allocator,
points: []const Point,
camera: Camera,
texture: Texture = .{ .size = undefined, .data = undefined },
storage: []const Chunk = &[_]Chunk{.{ .position = .{ 0, 0, 0 } }},

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
    const Render_Distance = @import("ChunkManager.zig").RENDER_DISTANCE;

    const point = @sizeOf(Point);
    const voxel = 6 * point;
    const chunk = (16 * 16 * 16) * voxel;
    const world = chunk * (((2 * Render_Distance) - 1) * ((2 * Render_Distance) - 1) * ((2 * Render_Distance) - 1));
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

pub fn maxVertexBufferArrayStride() comptime_int {
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
    return 1000;
}
