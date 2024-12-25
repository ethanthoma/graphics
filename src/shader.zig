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
    const uniformCount = blk: {
        var count = 0;
        break :blk inline for (BufferTypes) |BufferType| switch (BufferType.buffer_type) {
            .uniform => count += 1,
            else => {},
        } else count;
    };

    const textureCount = 1;

    return struct {
        const Self = @This();

        pub usingnamespace for (BufferTypes) |BufferType| {
            switch (BufferType.buffer_type) {
                .uniform => break struct {
                    fn UniformType(index: usize) type {
                        var local_index = 0;
                        inline for (BufferTypes) |_BufferType| {
                            switch (_BufferType.buffer_type) {
                                .uniform => {
                                    if (index == local_index) return _BufferType;
                                    local_index += 1;
                                },
                                else => {},
                            }
                        } else @compileError("Passed in index out of bounds");
                    }

                    fn getUniformIndex(Uniform: type) comptime_int {
                        comptime var index = 0;
                        inline for (BufferTypes) |_BufferType| {
                            switch (_BufferType.buffer_type) {
                                .uniform => {
                                    if (Uniform == _BufferType) break;
                                    index += 1;
                                },
                                else => {},
                            }
                        } else @compileError(std.fmt.comptimePrint(
                            "Passed in Uniform data {} doesn't match BufferTypes",
                            .{Uniform},
                        ));
                        return index;
                    }

                    pub fn addUniform(self: *Self, allocator: std.mem.Allocator, graphics: Graphics, data: anytype) !void {
                        const index = getUniformIndex(@TypeOf(data));

                        const uniform = try allocator.create(@TypeOf(data));
                        uniform.* = data;

                        self.uniforms[index] = uniform;

                        const buffer_index = inline for (BufferTypes, 0..) |_BufferType, i|
                            if (_BufferType == @TypeOf(data)) break i;

                        const Uniform = @TypeOf(data);

                        const buffer = graphics.device.createBuffer(&.{
                            .label = std.fmt.comptimePrint("uniform {} buffer", .{Uniform}),
                            .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.uniform,
                            .size = @sizeOf(Uniform),
                        }) orelse return Error.FailedToCreateBuffer;

                        self.buffers[buffer_index] = buffer;

                        graphics.queue.writeBuffer(
                            buffer,
                            0,
                            self.uniforms[index],
                            @sizeOf(Uniform),
                        );

                        self.bind_group_entries[index] = .{
                            .binding = Uniform.binding,
                            .buffer = buffer,
                            .size = @sizeOf(Uniform),
                        };

                        _ = try tryInitBindGroup(self, graphics);
                    }

                    pub fn update(
                        self: *const Self,
                        graphics: Graphics,
                        Uniform: type,
                        comptime field_tag: std.meta.FieldEnum(Uniform),
                        data: std.meta.fieldInfo(Uniform, field_tag).type,
                    ) void {
                        const index = getUniformIndex(Uniform);
                        const buffer_index = inline for (BufferTypes, 0..) |_BufferType, i|
                            if (_BufferType == Uniform) break i;

                        const uniform: *Uniform = @alignCast(@ptrCast(self.uniforms[index]));

                        const field_name = @tagName(field_tag);
                        const field = &@field(uniform, field_name);

                        field.* = data;

                        graphics.queue.writeBuffer(
                            self.buffers[buffer_index].?,
                            @offsetOf(Uniform, field_name),
                            field,
                            @sizeOf(std.meta.fieldInfo(Uniform, field_tag).type),
                        );
                    }
                },
                else => {},
            }
        } else struct {};

        mesh: Mesh,
        buffers: [BufferTypes.len]?*gpu.Buffer = .{null} ** BufferTypes.len,

        uniforms: [uniformCount]*anyopaque = undefined,

        bind_group_entries: [uniformCount + textureCount]?gpu.BindGroupEntry = undefined,

        texture: *gpu.Texture,
        texture_view: *gpu.TextureView,

        bind_group_layout: *gpu.BindGroupLayout,
        bind_group: *gpu.BindGroup,

        pub fn init(mesh: Mesh, graphics: Graphics) !Self {
            var self: Self = undefined;

            self.buffers = .{null} ** BufferTypes.len;

            try initTexture(&self, graphics);

            self.bind_group_entries = .{null} ** (uniformCount + textureCount);
            self.bind_group_entries[uniformCount] = .{ .binding = 1, .texture_view = self.texture_view };

            self.mesh = mesh;

            try initBindGroupLayout(&self, graphics);

            return self;
        }

        fn tryInitBindGroup(self: *Self, graphics: Graphics) !bool {
            const retval = for (self.bind_group_entries) |entry| {
                if (entry) |_| {} else break false;
            } else true;

            if (retval) {
                const entries = &blk: {
                    var entries: [uniformCount + textureCount]gpu.BindGroupEntry = undefined;
                    for (self.bind_group_entries, &entries) |from, *to| to.* = from.?;
                    break :blk entries;
                };
                try self.initBindGroup(graphics, entries);
            }

            return retval;
        }

        pub fn deinit(self: *const Self) void {
            self.bind_group.release();

            for (&self.buffers) |maybe_buffer| {
                if (maybe_buffer) |buffer| {
                    buffer.destroy();
                    buffer.release();
                }
            }

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
                        .uniform => {},
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

            // std.debug.print("{}, {}\n", .{ (self.mesh.indices.len * @typeInfo(std.meta.fields(Mesh.Index)[0].type).array.len), self.mesh.indices.len });
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
                .uniform => gpu.BufferUsage.uniform,
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

        fn initBindGroup(self: *Self, graphics: Graphics, entries: []const gpu.BindGroupEntry) !void {
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
