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

pub fn Shader(Type: type) type {
    // TODO: T.buffer_type should become shader_type and buffer_type should be a subtype of .buffer
    const Buffers, const Constants, const Binds, const Textures = struct {
        fn find(
            comptime T: type,
            comptime arr: []type,
            comptime cond: fn (comptime S: type) bool,
        ) []type {
            var arr_new = arr;
            return switch (@typeInfo(T)) {
                .pointer => |info| find(info.child, arr, cond),
                .@"struct", .@"union" => if (cond(T)) blk: {
                    break :blk add(arr, T);
                } else for (std.meta.fields(T)) |field| {
                    arr_new = find(field.type, arr_new, cond);
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

        fn buffers(comptime T: type) bool {
            return @hasDecl(T, "shader_type") and T.shader_type == .buffer;
        }

        fn constants(comptime T: type) bool {
            return @hasDecl(T, "shader_type") and T.shader_type == .constant;
        }

        fn binds(comptime T: type) bool {
            return @hasDecl(T, "binding");
        }

        fn textures(comptime T: type) bool {
            return @hasDecl(T, "shader_type") and T.shader_type == .texture;
        }

        fn make(
            comptime cond: fn (comptime T: type) bool,
        ) []const type {
            const tmp = find(Type, &[_]type{}, cond);
            var final: [tmp.len]type = undefined;
            for (tmp, 0..) |value, index| final[index] = value;
            const retval = final;
            return &retval;
        }

        const Self = .{ make(buffers), make(constants), make(binds), make(textures) };
    }.Self;

    //    @compileLog(Buffers, Constants, Binds, Textures);

    const bind_group_layout_entries = &comptime blk: {
        var bind_group_layout_entries: [Binds.len]gpu.BindGroupLayoutEntry = undefined;

        break :blk for (Binds, 0..) |Bind, index| {
            if (!@hasDecl(Bind, "visibility"))
                @compileError(std.fmt.comptimePrint(
                    "set visibility in {}",
                    .{Bind},
                ));

            var entry: gpu.BindGroupLayoutEntry = .{
                .binding = Bind.binding,
                .visibility = Bind.visibility,
            };

            if (Bind.shader_type == .texture) {
                entry.texture = .{
                    .sample_type = .float,
                    .view_dimension = .@"2d",
                    .multisampled = @intFromBool(false),
                };
            } else switch (Bind.buffer_type) {
                .uniform => entry.buffer = .{
                    .type = .uniform,
                    .min_binding_size = @sizeOf(Bind),
                },
                .storage => entry.buffer = .{
                    .type = .storage,
                    .min_binding_size = @sizeOf(Bind),
                },
                else => unreachable,
            }

            bind_group_layout_entries[index] = entry;
        } else bind_group_layout_entries;
    };

    return struct {
        const Self = @This();

        graphics: *const Graphics,

        buffers: [Buffers.len]?*gpu.Buffer = .{null} ** Buffers.len,

        texture_context: [Textures.len]?struct { *gpu.Texture, *gpu.TextureView } = .{null} ** Textures.len,

        constant_context: [Constants.len]?struct { *anyopaque, usize } = .{null} ** Constants.len,

        binding_ptrs: [Binds.len]*anyopaque = undefined,
        bind_group_entries: [Binds.len]?gpu.BindGroupEntry = .{null} ** Binds.len,

        bind_group_layout: *gpu.BindGroupLayout = undefined,
        bind_group: *gpu.BindGroup = undefined,

        pub fn init(graphics: *const Graphics) !Self {
            var self: Self = .{ .graphics = graphics };

            self.bind_group_layout = graphics.device.createBindGroupLayout(&.{
                .label = gpu.StringView.fromSlice("bind group"),
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
                    var entries: [Binds.len]gpu.BindGroupEntry = undefined;
                    for (self.bind_group_entries, &entries) |from, *to| to.* = from.?;
                    break :blk entries;
                };

                self.bind_group = self.graphics.device.createBindGroup(&.{
                    .label = gpu.StringView.fromSlice("bind group"),
                    .layout = self.bind_group_layout,
                    .entry_count = entries.len,
                    .entries = entries.ptr,
                }) orelse return Error.FailedToCreateBindGroup;
            }

            return retval;
        }
        const DrawInfo = struct {
            index_count: usize = 0,
            index_type_len: usize = 1,
            instance_buffer: ?*gpu.Buffer = null,
            instance_count: usize = 1,
            vertex_count: usize = 0,
            indirect_buffer: ?*gpu.Buffer = null,
        };

        pub fn render(self: *const Self, render_pass: *gpu.RenderPassEncoder) void {
            var draw_info: DrawInfo = .{};

            // TODO: this is ugly
            inline for (Buffers, self.buffers) |Buffer, buffer| {
                if (buffer != null) {
                    switch (Buffer.buffer_type) {
                        .index => {
                            const data_type: gpu.IndexFormat = switch (@typeInfo(std.meta.fields(Buffer)[0].type)) {
                                .array => |t| blk: {
                                    draw_info.index_type_len *= t.len;

                                    break :blk switch (t.child) {
                                        u16 => .uint16,
                                        else => @compileError(std.fmt.comptimePrint(
                                            "unsupported index data type {}",
                                            .{t.child},
                                        )),
                                    };
                                },
                                .int => |t| blk: {
                                    if (t.bits == 16 and t.signedness == .unsigned) break :blk .uint16;
                                    @compileError(std.fmt.comptimePrint(
                                        "unsupported index data type {}",
                                        .{t},
                                    ));
                                },
                                else => |t| @compileError(std.fmt.comptimePrint(
                                    "unsupported index data type {}",
                                    .{t},
                                )),
                            };
                            render_pass.setIndexBuffer(buffer.?, data_type, 0, buffer.?.getSize());

                            draw_info.index_count = buffer.?.getSize() / @sizeOf(Buffer);
                        },
                        .instance, .vertex => |buf_type| {
                            render_pass.setVertexBuffer(getSlot(Buffer), buffer.?, 0, buffer.?.getSize());

                            if (buf_type == .instance) {
                                const instance_count = buffer.?.getSize() / @sizeOf(Buffer);

                                draw_info.instance_count = @max(instance_count, draw_info.instance_count);

                                if (@hasDecl(Buffer, "vertex_count")) draw_info.vertex_count = Buffer.vertex_count;
                            }
                            if (buf_type == .vertex) draw_info.vertex_count = buffer.?.getSize() / @sizeOf(Buffer);
                        },
                        .indirect => {
                            draw_info.indirect_buffer = buffer;
                        },
                        else => {},
                    }
                }
            }

            render_pass.setBindGroup(0, self.bind_group, 0, null);

            //TODO: handle multiple constants
            //FIX: this
            if (Constants.len == 1) {
                const Constant = Constants[0];

                if (self.constant_context[0]) |context| {
                    const data, const size = context;

                    if (size != 0) {
                        const ptr: [*]const Constant = @ptrCast(@alignCast(data));

                        for (0..size) |index| {
                            render_pass.setPushConstants(
                                Constant.visibility,
                                0,
                                @sizeOf(Constant),
                                &ptr[index],
                            );

                            render_pass.drawIndirect(
                                draw_info.indirect_buffer.?,
                                index * @sizeOf(Mesh.Indirect),
                            );
                        }
                    }
                }
            } else draw(draw_info, render_pass);
        }

        fn draw(draw_info: DrawInfo, render_pass: *gpu.RenderPassEncoder) void {
            if (draw_info.indirect_buffer) |buffer| {
                render_pass.drawIndirect(buffer, 0);
            } else if (draw_info.index_count != 0) {
                const index_count: u32 = @intCast(draw_info.index_count);
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
                for (Buffers) |Buffer| {
                    if (T == Buffer) return slot;
                    switch (Buffer.buffer_type) {
                        .vertex, .instance => slot += 1,
                        else => continue,
                    }
                } else @compileError("slot only defined for vertex and instance");
            }
        }

        pub fn set(self: *Self, allocator: std.mem.Allocator, data: anytype) !void {
            const shader_type = comptime getShaderType(@TypeOf(data)) orelse
                @compileError(std.fmt.comptimePrint(
                    "type {} is not a shader type",
                    .{@TypeOf(data)},
                ));

            switch (shader_type) {
                .constant => try self.setConstant(allocator, data),
                .buffer => try self.setBuffer(allocator, data),
                .texture => try self.setTexture(allocator, data),
            }
        }

        fn setConstant(self: *Self, allocator: std.mem.Allocator, data: anytype) !void {
            const index, const is_container = inline for (Constants, 0..) |Constant, index| {
                switch (@typeInfo(@TypeOf(data))) {
                    .pointer => |ptr| if (ptr.child == Constant) break .{ index, true },
                    .@"struct" => if (@TypeOf(data) == Constant) break .{ index, false },
                    else => continue,
                }
            } else @compileError(std.fmt.comptimePrint(
                "type {} is not included in Constants",
                .{@TypeOf(data)},
            ));

            const Constant = Constants[index];

            if (self.constant_context[index]) |context| {
                const ptr, const size = context;
                if (size == 0) {
                    allocator.destroy(@as(*Constant, @ptrCast(@alignCast(ptr))));
                } else {
                    allocator.free(@as([*]const Constant, @ptrCast(@alignCast(ptr)))[0..size]);
                }
                self.constant_context[index] = null;
            }

            const ptr = if (is_container)
                (try allocator.dupe(Constant, data)).ptr
            else blk: {
                const ptr = try allocator.create(Constant);
                ptr.* = data;
                break :blk ptr;
            };

            const size = if (is_container) data.len else 0;

            self.constant_context[index] = .{ @ptrCast(ptr), size };
        }

        fn setBuffer(self: *Self, allocator: std.mem.Allocator, data: anytype) !void {
            const index, const is_container = inline for (Buffers, 0..) |Buffer, index| {
                switch (@typeInfo(@TypeOf(data))) {
                    .pointer => |ptr| if (ptr.child == Buffer) break .{ index, true },
                    .@"struct" => if (@TypeOf(data) == Buffer) break .{ index, false },
                    else => continue,
                }
            } else @compileError(std.fmt.comptimePrint(
                "type {} is not included in Buffers",
                .{@TypeOf(data)},
            ));

            if (self.buffers[index]) |buffer| {
                self.graphics.queue.submit(&.{});
                buffer.destroy();
                buffer.release();
                self.buffers[index] = null;
            }

            const Buffer = Buffers[index];

            const label = std.fmt.comptimePrint("{s} {s} buffer", .{
                @typeName(@TypeOf(data)),
                @tagName(Buffer.buffer_type),
            });

            const buffer_size = if (Buffer == @TypeOf(data))
                @sizeOf(Buffer)
            else if (is_container)
                data.len * @sizeOf(Buffer);

            const usage = switch (Buffer.buffer_type) {
                .vertex, .instance => gpu.BufferUsages.vertex,
                .index => gpu.BufferUsages.index,
                .uniform => gpu.BufferUsages.uniform,
                .storage => gpu.BufferUsages.storage,
                .indirect => gpu.BufferUsages.indirect,
                else => @compileError("unsupported buffer type"),
            } | gpu.BufferUsages.copy_dst;

            std.debug.print("creating {s} with size {}...\n", .{ label, buffer_size });
            const buffer = self.graphics.device.createBuffer(&.{
                .label = gpu.StringView.fromSlice(label),
                .usage = usage,
                .size = buffer_size,
            }) orelse return Error.FailedToCreateBuffer;
            std.debug.print("created\n", .{});

            const ptr = if (is_container)
                try allocator.dupe(Buffer, data)
            else blk: {
                const ptr = try allocator.create(@TypeOf(data));
                ptr.* = data;
                break :blk ptr;
            };

            // handle bind-able buffers
            if (@hasDecl(Buffer, "binding")) {
                const binding_index = getBindingIndex(Buffer);
                self.binding_ptrs[binding_index] = @ptrCast(ptr);

                self.bind_group_entries[binding_index] = .{
                    .binding = Buffer.binding,
                    .buffer = buffer,
                    .size = buffer_size,
                };

                _ = try self.tryInitBindGroup();
            }

            std.debug.print("writing to {s} buffer...\n", .{@typeName(Buffer)});
            self.graphics.queue.writeBuffer(buffer, 0, @ptrCast(ptr), buffer_size);
            std.debug.print("writen\n", .{});

            self.buffers[index] = buffer;
        }

        fn getBindingIndex(comptime T: type) comptime_int {
            return inline for (Binds, 0..) |Bind, index| {
                switch (@typeInfo(T)) {
                    .pointer => |ptr| if (ptr.child == Bind) break index,
                    .@"struct" => if (T == Bind) break index,
                    else => continue,
                }
            } else @compileError(std.fmt.comptimePrint(
                "type {} is not included in Binds",
                .{T},
            ));
        }

        fn setTexture(
            self: *Self,
            allocator: std.mem.Allocator,
            data: anytype,
        ) !void {
            const Texture = @TypeOf(data);

            const binding_index = getBindingIndex(Texture);

            const index = inline for (Textures, 0..) |T, index| {
                if (T == Texture) break index;
            } else @compileError(std.fmt.comptimePrint(
                "type of texture data {} does not exist in Textures",
                .{Texture},
            ));

            const texture = try allocator.create(Texture);
            texture.* = data;

            const width, const height = @as(Texture, data).size;
            const format = Texture.format;

            // TODO: a lot of config can move into the Texture type
            const gpu_texture = self.graphics.device.createTexture(&.{
                .usage = gpu.TextureUsages.texture_binding | gpu.TextureUsages.copy_dst,
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

            self.graphics.queue.writeTexture(
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

        // TODO: enable for storage buffers as well
        // TODO: currently assumes Uniform stored is a struct not a slice
        pub fn update(
            self: *const Self,
            graphics: Graphics,
            Uniform: type,
            comptime field_tag: std.meta.FieldEnum(Uniform),
            data: std.meta.fieldInfo(Uniform, field_tag).type,
        ) void {
            const buffer_index = inline for (Buffers, 0..) |Buffer, index| {
                if (Buffer == Uniform) break index;
            } else @compileError(std.fmt.comptimePrint(
                "type {} is not included in Buffers",
                .{Uniform},
            ));

            assert(Uniform.buffer_type == .uniform);

            const binding_index = getBindingIndex(Uniform);

            const uniform: *Uniform = @ptrCast(@alignCast(self.binding_ptrs[binding_index]));

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
    };
}

fn getShaderType(comptime T: type) ?enum { buffer, constant, texture } {
    switch (@typeInfo(T)) {
        .pointer => |info| return getShaderType(info.child),
        .@"struct", .@"enum", .@"union" => {
            if (@hasDecl(T, "shader_type") and T.shader_type == .texture) return .texture;
            if (@hasDecl(T, "shader_type") and T.shader_type == .buffer) return .buffer;
            if (@hasDecl(T, "shader_type") and T.shader_type == .constant) return .constant;

            return for (std.meta.fields(T)) |field| {
                if (getShaderType(field.type)) |S| break S;
            } else null;
        },
        else => return null,
    }
}
