const gpu = @import("wgpu");

const Mesh = @import("Mesh.zig");
const Graphics = @import("Graphics.zig");

const Self = @This();

const Error = error{
    FailedToCreateBuffer,
    FailedToCreateTexture,
    FailedToCreateView,
    FailedToCreateBindGroupLayout,
    FailedToCreateBindGroup,
};

mesh: Mesh,

index_buffer: *gpu.Buffer,
point_buffer: *gpu.Buffer,
instance_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,

texture: *gpu.Texture,
texture_view: *gpu.TextureView,

bind_group_layout: *gpu.BindGroupLayout,
bind_group: *gpu.BindGroup,

pub fn init(mesh: Mesh, graphics: Graphics) !Self {
    var self: Self = undefined;

    self.mesh = mesh;

    try initIndexBuffer(&self, graphics);
    try initPointBuffer(&self, graphics);
    try initInstanceBuffer(&self, graphics);
    try initUniformBuffer(&self, graphics);

    try initTexture(&self, graphics);

    try initBindGroupLayout(&self, graphics);
    try initBindGroup(&self, graphics);

    return self;
}

pub fn deinit(self: *const Self) void {
    self.bind_group.release();

    self.uniform_buffer.destroy();
    self.uniform_buffer.release();
    self.point_buffer.destroy();
    self.point_buffer.release();
    self.index_buffer.destroy();
    self.index_buffer.release();

    self.texture_view.release();
    self.texture.destroy();
    self.texture.release();

    self.bind_group_layout.release();
}

pub fn render(self: *const Self, render_pass: *gpu.RenderPassEncoder) void {
    render_pass.setVertexBuffer(0, self.point_buffer, 0, self.point_buffer.getSize());
    render_pass.setVertexBuffer(1, self.instance_buffer, 0, self.instance_buffer.getSize());
    render_pass.setIndexBuffer(self.index_buffer, .uint16, 0, self.index_buffer.getSize());
    render_pass.setBindGroup(0, self.bind_group, 0, null);
    render_pass.drawIndexed(
        @intCast(self.mesh.indices.len * @typeInfo(Mesh.Index).array.len),
        @intCast(self.mesh.instances.len),
        0,
        0,
        0,
    );
}

fn initIndexBuffer(self: *Self, graphics: Graphics) !void {
    self.index_buffer = graphics.device.createBuffer(&.{
        .label = "index buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.index,
        .size = self.mesh.indices.len * @sizeOf(Mesh.Index),
    }) orelse return Error.FailedToCreateBuffer;

    graphics.queue.writeBuffer(
        self.index_buffer,
        0,
        self.mesh.indices.ptr,
        self.mesh.indices.len * @sizeOf(Mesh.Index),
    );
}

fn initPointBuffer(self: *Self, graphics: Graphics) !void {
    self.point_buffer = graphics.device.createBuffer(&.{
        .label = "point buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
        .size = self.mesh.points.len * @sizeOf(Mesh.Point),
    }) orelse return Error.FailedToCreateBuffer;

    graphics.queue.writeBuffer(
        self.point_buffer,
        0,
        self.mesh.points.ptr,
        self.mesh.points.len * @sizeOf(Mesh.Point),
    );
}

fn initUniformBuffer(self: *Self, graphics: Graphics) !void {
    self.uniform_buffer = graphics.device.createBuffer(&.{
        .label = "uniform buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.uniform,
        .size = @sizeOf(Mesh.Uniform),
    }) orelse return Error.FailedToCreateBuffer;

    graphics.queue.writeBuffer(
        self.uniform_buffer,
        0,
        &self.mesh.uniform,
        @sizeOf(Mesh.Uniform),
    );
}

fn initInstanceBuffer(self: *Self, graphics: Graphics) !void {
    self.instance_buffer = graphics.device.createBuffer(&.{
        .label = "instance buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
        .size = self.mesh.instances.len * @sizeOf(Mesh.Instance),
    }) orelse return Error.FailedToCreateBuffer;

    graphics.queue.writeBuffer(
        self.instance_buffer,
        0,
        self.mesh.instances.ptr,
        self.mesh.instances.len * @sizeOf(Mesh.Instance),
    );
}

fn initBindGroupLayout(self: *Self, graphics: Graphics) !void {
    const entries = &[_]gpu.BindGroupLayoutEntry{ .{
        .binding = 0,
        .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment,
        .buffer = .{
            .type = .uniform,
            .min_binding_size = @sizeOf(Mesh.Uniform),
        },
        .sampler = .{},
        .texture = .{},
        .storage_texture = .{},
    }, .{
        .binding = 1,
        .visibility = gpu.ShaderStage.fragment,
        .buffer = .{},
        .sampler = .{},
        .texture = .{
            .sample_type = .float,
        },
        .storage_texture = .{},
    } };

    self.bind_group_layout = graphics.device.createBindGroupLayout(&.{
        .label = "my bind group",
        .entry_count = entries.len,
        .entries = entries.ptr,
    }) orelse return Error.FailedToCreateBindGroupLayout;
}

fn initBindGroup(self: *Self, graphics: Graphics) !void {
    const entries = &[_]gpu.BindGroupEntry{ .{
        .binding = 0,
        .buffer = self.uniform_buffer,
        .size = @sizeOf(Mesh.Uniform),
    }, .{ .binding = 1, .texture_view = self.texture_view } };

    self.bind_group = graphics.device.createBindGroup(&.{
        .label = "bind group",
        .layout = self.bind_group_layout,
        .entry_count = entries.len,
        .entries = entries.ptr,
    }) orelse return Error.FailedToCreateBindGroup;
}

fn initTexture(self: *Self, graphics: Graphics) !void {
    const width = 256;
    const height = 256;
    const border = 3;

    self.texture = graphics.device.createTexture(&.{
        .usage = gpu.TextureUsage.texture_binding | gpu.TextureUsage.copy_dst,
        .size = .{
            .width = width,
            .height = height,
        },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
    }) orelse return Error.FailedToCreateTexture;

    self.texture_view = self.texture.createView(&.{
        .format = .rgba8_unorm,
        .dimension = .@"2d",
        .array_layer_count = 1,
        .mip_level_count = 1,
    }) orelse return Error.FailedToCreateView;

    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const color: *[4]u8 = @ptrCast(&pixels[(y * height + x) * 4]);

            color.* = .{
                0,
                192,
                0,
                255,
            };

            if (x < border or x >= width - border or y < border or y >= height - border) {
                color.* = .{ 0, 0, 0, 255 };
            }
        }
    }

    graphics.queue.writeTexture(
        &.{ .texture = self.texture, .origin = .{} },
        (&pixels).ptr,
        (&pixels).len,
        &.{ .bytes_per_row = 4 * width, .rows_per_image = height },
        &.{ .width = width, .height = height },
    );
}
