const std = @import("std");
const assert = @import("std").debug.assert;

const gpu = @import("wgpu");

const Mesh = @import("Mesh.zig");
const Graphics = @import("Graphics.zig");

const Error = error{
    FailedToCreateBuffer,
    FailedToCreateTexture,
    FailedToCreateView,
    FailedToCreateBindGroupLayout,
    FailedToCreateBindGroup,
};

pub fn Shader(BufferTypes: []const type) type {
    return struct {
        const Self = @This();

        mesh: Mesh,
        buffers: [BufferTypes.len]?*gpu.Buffer = .{null} ** BufferTypes.len,

        uniform_buffer: *gpu.Buffer,

        texture: *gpu.Texture,
        texture_view: *gpu.TextureView,

        bind_group_layout: *gpu.BindGroupLayout,
        bind_group: *gpu.BindGroup,

        pub fn init(mesh: Mesh, graphics: Graphics) !Self {
            var self: Self = undefined;

            self.buffers = .{null} ** BufferTypes.len;

            self.mesh = mesh;

            try addBuffer(&self, graphics, mesh.points);
            try addBuffer(&self, graphics, mesh.instances);
            try addBuffer(&self, graphics, mesh.indices);

            try initUniformBuffer(&self, graphics);
            try initTexture(&self, graphics);

            try initBindGroupLayout(&self, graphics);
            try initBindGroup(&self, graphics);

            return self;
        }

        pub fn deinit(self: *const Self) void {
            self.bind_group.release();

            for (&self.buffers) |maybe_buffer| {
                if (maybe_buffer) |buffer| {
                    buffer.destroy();
                    buffer.release();
                }
            }

            self.uniform_buffer.destroy();
            self.uniform_buffer.release();

            self.texture_view.release();
            self.texture.destroy();
            self.texture.release();

            self.bind_group_layout.release();
        }

        pub fn render(self: *const Self, render_pass: *gpu.RenderPassEncoder) void {
            inline for (self.buffers, 0..) |buffer, index| {
                if (buffer != null) {
                    switch (BufferTypes[index].buffer_type) {
                        .index => {
                            const data_type: gpu.IndexFormat = switch (@typeInfo(std.meta.fields(BufferTypes[index])[0].type)) {
                                .array => |t| switch (t.child) {
                                    u16 => .uint16,
                                    else => @compileError(std.fmt.comptimePrint(
                                        "Unsupported index data type {}",
                                        .{t.child},
                                    )),
                                },
                                else => |t| @compileError(std.fmt.comptimePrint(
                                    "Unsupported index data type {}",
                                    .{t},
                                )),
                            };
                            render_pass.setIndexBuffer(buffer.?, data_type, 0, buffer.?.getSize());
                        },
                        .instance, .vertex => {
                            const slot = BufferTypes[index].slot;
                            render_pass.setVertexBuffer(slot, buffer.?, 0, buffer.?.getSize());
                        },
                    }
                }
            }

            render_pass.setBindGroup(0, self.bind_group, 0, null);
            render_pass.drawIndexed(
                @intCast(self.mesh.indices.len * @typeInfo(std.meta.fields(Mesh.Index)[0].type).array.len),
                @intCast(self.mesh.instances.len),
                0,
                0,
                0,
            );
        }

        pub fn addBuffer(self: *Self, graphics: Graphics, data: anytype) !void {
            if (@typeInfo(@TypeOf(data)) != .pointer) @compileError("Buffer data shoud be a slice");

            const meta = inline for (BufferTypes, 0..) |BufferType, i| {
                if (BufferType == @typeInfo(@TypeOf(data)).pointer.child) {
                    break .{ BufferType, i };
                }
            } else {
                @compileError(std.fmt.comptimePrint(
                    "Buffer data was of type {} but expected one of {any}",
                    .{ @typeInfo(@TypeOf(data)).pointer.child, BufferTypes },
                ));
            };
            const BufferType, const index = meta;

            const usage = switch (BufferType.buffer_type) {
                .vertex, .instance => gpu.BufferUsage.vertex,
                .index => gpu.BufferUsage.index,
            } | gpu.BufferUsage.copy_dst;

            self.buffers[index] = graphics.device.createBuffer(&.{
                .label = std.fmt.comptimePrint("{s} buffer", .{@typeName(BufferType)}),
                .usage = usage,
                .size = data.len * @sizeOf(BufferType),
            }) orelse return Error.FailedToCreateBuffer;

            graphics.queue.writeBuffer(
                self.buffers[index].?,
                0,
                data.ptr,
                data.len * @sizeOf(BufferType),
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
    };
}
