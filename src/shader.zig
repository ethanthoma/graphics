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

    const textureCount = blk: {
        var count = 0;
        break :blk inline for (BufferTypes) |BufferType| switch (BufferType.buffer_type) {
            .texture => count += 1,
            else => {},
        } else count;
    };

    const bind_group_layout_entries = &comptime outer: {
        var bind_group_layout_entries: [uniformCount + textureCount]gpu.BindGroupLayoutEntry = undefined;
        var index = 0;
        for (BufferTypes) |BufferType| {
            bind_group_layout_entries[index] = switch (BufferType.buffer_type) {
                .uniform => inner: {
                    defer index += 1;

                    const visibility = if (@hasDecl(BufferType, "visibility"))
                        BufferType.visibility
                    else
                        gpu.ShaderStage.vertex | gpu.ShaderStage.fragment;

                    break :inner .{
                        .binding = BufferType.binding,
                        .visibility = visibility,
                        .buffer = .{
                            .type = .uniform,
                            .min_binding_size = @sizeOf(BufferType),
                        },
                        .sampler = .{},
                        .texture = .{},
                        .storage_texture = .{},
                    };
                },
                .texture => inner: {
                    defer index += 1;

                    const visibility = if (@hasDecl(BufferType, "visibility"))
                        BufferType.visibility
                    else
                        gpu.ShaderStage.fragment;

                    break :inner .{
                        .binding = BufferType.binding,
                        .visibility = visibility,
                        .buffer = .{},
                        .sampler = .{},
                        .texture = .{
                            .sample_type = .float,
                        },
                        .storage_texture = .{},
                    };
                },
                else => continue,
            };
        }

        break :outer bind_group_layout_entries;
    };

    const DrawInfo = struct {
        index_size: usize = 1,
        index_buffer: ?*gpu.Buffer = null,
        index_type_len: usize = 1,
        instance_buffer: ?*gpu.Buffer = null,
        instance_count: usize = 1,
        vertex_count: usize = 0,
    };

    return struct {
        const Self = @This();

        pub usingnamespace for (BufferTypes) |BufferType| {
            switch (BufferType.buffer_type) {
                .uniform => break struct {
                    pub fn addUniform(
                        self: *Self,
                        allocator: std.mem.Allocator,
                        graphics: Graphics,
                        data: anytype,
                    ) !void {
                        const Uniform = @TypeOf(data);

                        const index = getUniformIndex(Uniform);

                        const uniform = try allocator.create(Uniform);
                        uniform.* = data;

                        self.uniforms[index] = uniform;

                        const buffer_index = inline for (BufferTypes, 0..) |_BufferType, i|
                            if (_BufferType == Uniform) break i;

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
                },
                else => {},
            }
        } else struct {};

        pub usingnamespace for (BufferTypes) |BufferType| {
            switch (BufferType.buffer_type) {
                .texture => break struct {
                    pub fn addTexture(
                        self: *Self,
                        allocator: std.mem.Allocator,
                        graphics: Graphics,
                        data: anytype,
                    ) !void {
                        const Texture = @TypeOf(data);

                        const index = getTextureIndex(Texture);

                        const texture = try allocator.create(Texture);
                        texture.* = data;

                        self.textures[index] = texture;

                        const width, const height = @as(Texture, data).size;
                        const format = Texture.format;

                        const gpu_texture = graphics.device.createTexture(&.{
                            .usage = gpu.TextureUsage.texture_binding | gpu.TextureUsage.copy_dst,
                            .size = .{
                                .width = @intCast(width),
                                .height = @intCast(height),
                            },
                            .format = format,
                            .mip_level_count = 1,
                            .sample_count = 1,
                        }) orelse return Error.FailedToCreateTexture;

                        const gpu_texture_view = gpu_texture.createView(&.{
                            .format = format,
                            .dimension = .@"2d",
                            .array_layer_count = 1,
                            .mip_level_count = 1,
                        }) orelse return Error.FailedToCreateView;

                        self.texture_context[index] = .{ gpu_texture, gpu_texture_view };

                        const bytes = std.mem.sliceAsBytes(@as(Texture, data).data);

                        const bytes_per_row = bytes.len / height;
                        const rows_per_image = height;

                        graphics.queue.writeTexture(
                            &.{ .texture = gpu_texture, .origin = .{} },
                            bytes.ptr,
                            bytes.len,
                            &.{
                                .bytes_per_row = @intCast(bytes_per_row),
                                .rows_per_image = @intCast(rows_per_image),
                            },
                            &.{ .width = @intCast(width), .height = @intCast(height) },
                        );

                        self.bind_group_entries[uniformCount + index] = .{
                            .binding = Texture.binding,
                            .texture_view = gpu_texture_view,
                        };

                        _ = try tryInitBindGroup(self, graphics);
                    }

                    fn getTextureIndex(Texture: type) comptime_int {
                        comptime var index = 0;
                        inline for (BufferTypes) |_BufferType| {
                            switch (_BufferType.buffer_type) {
                                .texture => {
                                    if (Texture == _BufferType) break;
                                    index += 1;
                                },
                                else => {},
                            }
                        } else @compileError(std.fmt.comptimePrint(
                            "Passed in Texture data {} doesn't match BufferTypes",
                            .{Texture},
                        ));
                        return index;
                    }
                },
                else => {},
            }
        } else struct {};

        buffers: [BufferTypes.len]?*gpu.Buffer = .{null} ** BufferTypes.len,

        uniforms: [uniformCount]*anyopaque = undefined,
        textures: [textureCount]*anyopaque = undefined,

        bind_group_entries: [uniformCount + textureCount]?gpu.BindGroupEntry = .{null} ** (uniformCount + textureCount),

        texture_context: [textureCount]?struct { *gpu.Texture, *gpu.TextureView } = .{null} ** textureCount,

        bind_group_layout: *gpu.BindGroupLayout = undefined,
        bind_group: *gpu.BindGroup = undefined,

        pub fn init(graphics: Graphics) !Self {
            var self: Self = .{};

            self.bind_group_layout = graphics.device.createBindGroupLayout(&.{
                .label = "my bind group",
                .entry_count = bind_group_layout_entries.len,
                .entries = bind_group_layout_entries.ptr,
            }) orelse return Error.FailedToCreateBindGroupLayout;

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

                self.bind_group = graphics.device.createBindGroup(&.{
                    .label = "bind group",
                    .layout = self.bind_group_layout,
                    .entry_count = entries.len,
                    .entries = entries.ptr,
                }) orelse return Error.FailedToCreateBindGroup;
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

            for (&self.texture_context) |maybe_texture_context| if (maybe_texture_context) |texture_context| {
                const texture, const texture_view = texture_context;
                texture_view.release();
                texture.destroy();
                texture.release();
            };

            self.bind_group_layout.release();
        }

        pub fn render(self: *const Self, render_pass: *gpu.RenderPassEncoder) void {
            var draw_info: DrawInfo = .{};

            inline for (self.buffers, 0..) |buffer, index| {
                if (buffer != null) {
                    switch (BufferTypes[index].buffer_type) {
                        .index => {
                            const data_type: gpu.IndexFormat = switch (@typeInfo(std.meta.fields(BufferTypes[index])[0].type)) {
                                .array => |t| blk: {
                                    draw_info.index_type_len *= t.len;

                                    break :blk switch (t.child) {
                                        u16 => .uint16,
                                        else => @compileError(std.fmt.comptimePrint(
                                            "Unsupported index data type {}",
                                            .{t.child},
                                        )),
                                    };
                                },
                                .int => |t| blk: {
                                    if (t.bits == 16 and t.signedness == .unsigned) break :blk .uint16;
                                    @compileError(std.fmt.comptimePrint(
                                        "Unsupported index data type {}",
                                        .{t},
                                    ));
                                },
                                else => |t| @compileError(std.fmt.comptimePrint(
                                    "Unsupported index data type {}",
                                    .{t},
                                )),
                            };
                            render_pass.setIndexBuffer(buffer.?, data_type, 0, buffer.?.getSize());

                            draw_info.index_buffer = buffer;
                            draw_info.index_size = @sizeOf(BufferTypes[index]);
                        },
                        .instance, .vertex => |buf_type| {
                            const slot = BufferTypes[index].slot;
                            render_pass.setVertexBuffer(slot, buffer.?, 0, buffer.?.getSize());

                            if (buf_type == .instance) draw_info.instance_count = buffer.?.getSize() / @sizeOf(BufferTypes[index]);
                            if (buf_type == .vertex) draw_info.vertex_count = buffer.?.getSize() / @sizeOf(BufferTypes[index]);
                        },
                        .uniform, .texture => {},
                    }
                }
            }

            render_pass.setBindGroup(0, self.bind_group, 0, null);

            if (draw_info.index_buffer) |buffer| {
                const index_count: u32 = @intCast(buffer.getSize() / draw_info.index_size);
                const instance_count: u32 = @intCast(draw_info.instance_count);

                render_pass.drawIndexed(index_count, instance_count, 0, 0, 0);
            } else {
                const vertex_count: u32 = @intCast(draw_info.vertex_count);
                const instance_count: u32 = @intCast(draw_info.instance_count);

                render_pass.draw(vertex_count, instance_count, 0, 0);
            }
        }

        pub fn addBuffer(self: *Self, graphics: Graphics, data: anytype) !void {
            if (@typeInfo(@TypeOf(data)) != .pointer) @compileError("Buffer data shoud be a slice");

            const BufferType = @typeInfo(@TypeOf(data)).pointer.child;
            const index = inline for (BufferTypes, 0..) |_BufferType, i| {
                if (BufferType == _BufferType) break i;
            } else @compileError("Removed buffer type is not one of the passed in shader types");

            if (self.buffers[index]) |buffer| {
                graphics.queue.submit(&[_]*const gpu.CommandBuffer{});
                buffer.destroy();
                buffer.release();
                self.buffers[index] = null;
            }

            self.buffers[index] = try createBuffer(graphics, data);
        }

        fn createBuffer(graphics: Graphics, data: anytype) !*gpu.Buffer {
            const BufferType = @typeInfo(@TypeOf(data)).pointer.child;

            inline for (BufferTypes) |_BufferType| {
                if (BufferType == _BufferType) break;
            } else @compileError(std.fmt.comptimePrint(
                "Buffer data was of type {} but expected one of {any}",
                .{ BufferType, BufferTypes },
            ));

            const usage = switch (BufferType.buffer_type) {
                .vertex, .instance => gpu.BufferUsage.vertex,
                .index => gpu.BufferUsage.index,
                .uniform, .texture => @compileError("Do not use addBuffer for uniforms or textures"),
            } | gpu.BufferUsage.copy_dst;

            std.debug.print("creating {s} buffer with size {}...\n", .{ @typeName(BufferType), data.len * @sizeOf(BufferType) });
            const buffer = graphics.device.createBuffer(&.{
                .label = std.fmt.comptimePrint("{s} buffer", .{@typeName(BufferType)}),
                .usage = usage,
                .size = data.len * @sizeOf(BufferType),
            }) orelse return Error.FailedToCreateBuffer;
            std.debug.print("created\n", .{});

            std.debug.print("writing to {s} buffer...\n", .{@typeName(BufferType)});
            graphics.queue.writeBuffer(
                buffer,
                0,
                data.ptr,
                data.len * @sizeOf(BufferType),
            );
            std.debug.print("writen\n", .{});

            return buffer;
        }
    };
}
