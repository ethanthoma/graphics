const std = @import("std");
const assert = @import("std").debug.assert;

const gpu = @import("wgpu");

const BufferTypeClass = @import("buffer.zig").BufferTypeClass;
const Mesh = @import("Mesh.zig");
const Graphics = @import("Graphics.zig");

const Error = error{
    FailedToCreateBuffer,
    FailedToCreateTexture,
    FailedToCreateView,
    FailedToCreateBindGroupLayout,
    FailedToCreateBindGroup,
};

pub fn Shader(Type: type) type {
    const BufferTypes = struct {
        fn find_types(comptime T: type, comptime arr: []type) []type {
            var arr_new = arr;
            return switch (@typeInfo(T)) {
                .pointer => |info| find_types(info.child, arr),
                .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "buffer_type")) blk: {
                    break :blk add(arr, T);
                } else for (std.meta.fields(T)) |field| {
                    arr_new = find_types(field.type, arr_new);
                } else arr_new,
                else => arr,
            };
        }

        fn add(comptime arr: []type, comptime BufferType: type) []type {
            var arr_new: [arr.len + 1]type = undefined;

            return for (arr, 0..) |value, index| {
                arr_new[index] = value;

                if (value == BufferType) break arr;
            } else blk: {
                arr_new[arr.len] = BufferType;
                break :blk &arr_new;
            };
        }

        fn buffer_types(comptime T: type) []const type {
            const tmp = find_types(T, &[_]type{});
            var final: [tmp.len]type = undefined;
            for (tmp, 0..) |value, index| final[index] = value;
            const retval = final;
            return &retval;
        }
    }.buffer_types(Type);

    const uniform_count = blk: {
        var count = 0;
        break :blk inline for (BufferTypes) |BufferType| switch (BufferType.buffer_type) {
            .uniform => count += 1,
            else => {},
        } else count;
    };

    const texture_count = blk: {
        var count = 0;
        break :blk inline for (BufferTypes) |BufferType| switch (BufferType.buffer_type) {
            .texture => count += 1,
            else => {},
        } else count;
    };

    const storage_count = blk: {
        var count = 0;
        break :blk inline for (BufferTypes) |BufferType| switch (BufferType.buffer_type) {
            .storage => count += 1,
            else => {},
        } else count;
    };

    const bind_count = uniform_count + texture_count + storage_count;

    const bind_group_layout_entries = &comptime outer: {
        var bind_group_layout_entries: [bind_count]gpu.BindGroupLayoutEntry = undefined;

        var index = 0;
        for (BufferTypes) |BufferType| {
            switch (BufferType.buffer_type) {
                .uniform, .texture, .storage => |bind| {
                    if (!@hasDecl(BufferType, "visibility"))
                        @compileError(std.fmt.comptimePrint(
                            "set visibility in {}",
                            .{BufferType},
                        ));

                    var entry: gpu.BindGroupLayoutEntry = .{
                        .binding = BufferType.binding,
                        .visibility = BufferType.visibility,
                        .buffer = .{},
                        .sampler = .{},
                        .texture = .{},
                        .storage_texture = .{},
                    };

                    switch (bind) {
                        .uniform => {
                            entry.buffer = .{
                                .type = .uniform,
                                .min_binding_size = @sizeOf(BufferType),
                            };
                        },
                        .texture => {
                            entry.texture = .{ .sample_type = .float };
                        },
                        .storage => {
                            entry.buffer = .{
                                .type = .storage,
                                .min_binding_size = @sizeOf(BufferType),
                            };
                        },
                        else => unreachable,
                    }

                    bind_group_layout_entries[index] = entry;
                    index += 1;
                },
                else => continue,
            }
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

        // TODO: make these less special like the storage buffer
        pub usingnamespace for (BufferTypes) |BufferType| {
            switch (BufferType.buffer_type) {
                .uniform => break struct {
                    pub fn update(
                        self: *const Self,
                        graphics: Graphics,
                        Uniform: type,
                        comptime field_tag: std.meta.FieldEnum(Uniform),
                        data: std.meta.fieldInfo(Uniform, field_tag).type,
                    ) void {
                        const buffer_index = inline for (BufferTypes, 0..) |_BufferType, i|
                            if (_BufferType == Uniform) break i;

                        const binding_index = bindingIndex(Uniform);

                        const uniform: *Uniform = @alignCast(@ptrCast(self.binding_ptrs[binding_index]));

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
                else => continue,
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

                        const binding_index = bindingIndex(Texture);

                        const index = getTextureIndex(Texture);

                        const texture = try allocator.create(Texture);
                        texture.* = data;

                        const width, const height = @as(Texture, data).size;
                        const format = Texture.format;

                        // TODO: a lot of config can move into the Texture type
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

                        self.binding_ptrs[binding_index] = @ptrCast(texture);

                        // TODO: texture buffer expects a `.data` field, no need to enforce
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

                        self.bind_group_entries[binding_index] = .{
                            .binding = Texture.binding,
                            .texture_view = gpu_texture_view,
                        };

                        // TODO: a SET would make this faster but unneeded rn
                        _ = try self.tryInitBindGroup();
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
                            "passed in Texture data {} doesn't match BufferTypes",
                            .{Texture},
                        ));
                        return index;
                    }
                },
                else => continue,
            }
        } else struct {};

        graphics: *const Graphics,

        buffers: [BufferTypes.len]?*gpu.Buffer = .{null} ** BufferTypes.len,

        binding_ptrs: [bind_count]*anyopaque = undefined,

        bind_group_entries: [bind_count]?gpu.BindGroupEntry = .{null} ** (bind_count),

        // TODO: maybe can merge with binding_ptrs? must be a way to track this and deinit properly
        texture_context: [texture_count]?struct { *gpu.Texture, *gpu.TextureView } = .{null} ** texture_count,

        bind_group_layout: *gpu.BindGroupLayout = undefined,
        bind_group: *gpu.BindGroup = undefined,

        pub fn init(graphics: *const Graphics) !Self {
            var self: Self = .{ .graphics = graphics };

            self.bind_group_layout = graphics.device.createBindGroupLayout(&.{
                .label = "bind group",
                .entry_count = bind_group_layout_entries.len,
                .entries = bind_group_layout_entries.ptr,
            }) orelse return Error.FailedToCreateBindGroupLayout;

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

            for (&self.texture_context) |maybe_texture_context| if (maybe_texture_context) |texture_context| {
                const texture, const texture_view = texture_context;
                texture_view.release();
                texture.destroy();
                texture.release();
            };

            self.bind_group_layout.release();
        }

        fn tryInitBindGroup(self: *Self) !bool {
            const retval = for (self.bind_group_entries) |entry| {
                if (entry) |_| {} else break false;
            } else true;

            if (retval) {
                const entries = &blk: {
                    var entries: [bind_count]gpu.BindGroupEntry = undefined;
                    for (self.bind_group_entries, &entries) |from, *to| to.* = from.?;
                    break :blk entries;
                };

                self.bind_group = self.graphics.device.createBindGroup(&.{
                    .label = "bind group",
                    .layout = self.bind_group_layout,
                    .entry_count = entries.len,
                    .entries = entries.ptr,
                }) orelse return Error.FailedToCreateBindGroup;
            }

            return retval;
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
                            render_pass.setVertexBuffer(getSlot(BufferTypes[index]), buffer.?, 0, buffer.?.getSize());

                            if (buf_type == .instance) {
                                draw_info.instance_count = buffer.?.getSize() / @sizeOf(BufferTypes[index]);

                                if (@hasDecl(BufferTypes[index], "vertex_count")) draw_info.vertex_count = BufferTypes[index].vertex_count;
                            }
                            if (buf_type == .vertex) draw_info.vertex_count = buffer.?.getSize() / @sizeOf(BufferTypes[index]);
                        },
                        else => {},
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

        fn getSlot(comptime T: type) comptime_int {
            comptime {
                var slot = 0;
                for (BufferTypes) |BufferType| {
                    if (T == BufferType) return slot;
                    switch (BufferType.buffer_type) {
                        .vertex, .instance => slot += 1,
                        else => {},
                    }
                } else @compileError("slot only defined for vertex and instance");
            }
        }

        pub fn addBuffer(self: *Self, allocator: std.mem.Allocator, data: anytype) !void {
            const buffer_index = bufferIndex(@TypeOf(data));

            if (self.buffers[buffer_index]) |buffer| {
                self.graphics.queue.submit(&[_]*const gpu.CommandBuffer{});
                buffer.destroy();
                buffer.release();
                self.buffers[buffer_index] = null;
            }

            self.buffers[buffer_index] = try self.createBuffer(allocator, data);
        }

        fn createBuffer(self: *Self, allocator: std.mem.Allocator, data: anytype) !*gpu.Buffer {
            const BufferType = findBufferType(@TypeOf(data)) orelse
                @compileError("data does not have buffer_type");

            const label = std.fmt.comptimePrint("{s} {s} buffer", .{
                @typeName(@TypeOf(data)),
                @tagName(BufferType.buffer_type),
            });

            const is_container = comptime isContainer(@TypeOf(data));

            const buffer_size = if (BufferType == @TypeOf(data))
                @sizeOf(BufferType)
            else if (is_container)
                data.len * @sizeOf(BufferType);

            const usage = switch (BufferType.buffer_type) {
                .vertex, .instance => gpu.BufferUsage.vertex,
                .index => gpu.BufferUsage.index,
                .uniform => gpu.BufferUsage.uniform,
                .storage => gpu.BufferUsage.storage,
                else => @compileError("unsupported buffer type"),
            } | gpu.BufferUsage.copy_dst;

            std.debug.print("creating {s} with size {}...\n", .{ label, buffer_size });
            const buffer = self.graphics.device.createBuffer(&.{
                .label = label,
                .usage = usage,
                .size = buffer_size,
            }) orelse return Error.FailedToCreateBuffer;
            std.debug.print("created\n", .{});

            const ptr = if (is_container)
                try allocator.dupe(BufferType, data)
            else blk: {
                const ptr = try allocator.create(@TypeOf(data));
                ptr.* = data;
                break :blk ptr;
            };

            // handle bind-able buffers
            if (@hasDecl(BufferType, "binding")) {
                const binding_index = bindingIndex(BufferType);
                self.binding_ptrs[binding_index] = @ptrCast(ptr);

                self.bind_group_entries[binding_index] = .{
                    .binding = BufferType.binding,
                    .buffer = buffer,
                    .size = buffer_size,
                };

                _ = try self.tryInitBindGroup();
            }

            std.debug.print("writing to {s} buffer...\n", .{@typeName(BufferType)});
            self.graphics.queue.writeBuffer(buffer, 0, @ptrCast(ptr), buffer_size);
            std.debug.print("writen\n", .{});

            return buffer;
        }

        fn isContainer(comptime T: type) bool {
            const BufferType = findBufferType(T) orelse
                @compileError("type T does not have buffer_type decl");

            return switch (@typeInfo(T)) {
                .pointer => |ptr| blk: {
                    if (ptr.child != BufferType)
                        @compileError("type T must be a buffer type, a slice/array of one, or a pointer to one");

                    if (ptr.size == .Slice) break :blk true;

                    break :blk false;
                },
                else => false,
            };
        }

        fn bufferIndex(comptime T: type) comptime_int {
            var index = 0;
            return for (std.meta.fields(Type)) |field| {
                if (field.type == T) break index else switch (@typeInfo(field.type)) {
                    .pointer => |ptr| {
                        if (bufferTypesContainType(ptr.child)) index += 1;
                    },
                    else => {
                        if (bufferTypesContainType(field.type)) index += 1;
                    },
                }
            } else @compileError("buffer type must be apart of your shader Type fields");
        }

        fn bindingIndex(comptime T: type) comptime_int {
            comptime var index = 0;
            index = for (BufferTypes) |BufferType| {
                if (T == BufferType) break index;
                switch (BufferType.buffer_type) {
                    .uniform, .storage, .texture => index += 1,
                    else => continue,
                }
            } else @compileError(std.fmt.comptimePrint(
                "Passed in type {} doesn't exist in BufferTypes",
                .{T},
            ));

            return index;
        }

        fn findBufferType(comptime T: type) ?type {
            return switch (@typeInfo(T)) {
                .pointer => |info| findBufferType(info.child),
                .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "buffer_type")) blk: {
                    if (!bufferTypesContainType(T)) @compileError("buffer type does not exist in BufferTypes");
                    break :blk T;
                } else for (std.meta.fields(T)) |field| {
                    if (findBufferType(field.type)) |S| break S;
                } else null,
                else => null,
            };
        }

        fn bufferTypesContainType(comptime T: type) bool {
            return for (BufferTypes) |BufferType| {
                if (T == BufferType) break true;
            } else false;
        }
    };
}
