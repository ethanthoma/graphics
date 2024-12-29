const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const math = @import("math.zig");
const Mat4x4 = math.Mat4x4;
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");
const Shader = @import("shader.zig").Shader(Mesh);
const DataType = math.DataType;
const BufferTypeClass = @import("buffer.zig").BufferTypeClass;

const Renderer = @This();

const Error = error{
    FailedToCreateShaderModule,
    FailedToGetCurrentTexture,
    FailedToCreateCommandEncoder,
    FailedToCreateTexture,
    FailedToCreateView,
    FailedToCreateRenderPipeline,
    FailedToCreatePipelineLayout,
    FailedToBeginRenderPass,
    FailedToFinishEncoder,
};

pipeline: *gpu.RenderPipeline,
layout: *gpu.PipelineLayout,
shader: Shader,

depth_texture: *gpu.Texture,
depth_view: *gpu.TextureView,

width: u32,
height: u32,

pub fn init(allocator: std.mem.Allocator, mesh: Mesh, graphics: Graphics, width: u32, height: u32) !Renderer {
    var self: Renderer = undefined;

    self.width = width;
    self.height = height;

    try self.initDepth(graphics);

    std.debug.print("loading shader...\n", .{});
    const shader_module = graphics.device.createShaderModule(&gpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })) orelse return Error.FailedToCreateShaderModule;
    defer shader_module.release();
    std.debug.print("shader loaded\n", .{});

    // create render pipeline
    const color_targets = &[_]gpu.ColorTargetState{
        gpu.ColorTargetState{
            .format = graphics.surface_format,
            .blend = &gpu.BlendState{
                .color = gpu.BlendComponent{
                    .operation = .add,
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
                .alpha = gpu.BlendComponent{
                    .operation = .add,
                    .src_factor = .zero,
                    .dst_factor = .one,
                },
            },
        },
    };

    const point_attributes = &comptime getAttributes(Mesh.Point, 0);

    const buffers = &getVertexBufferLayouts(&[_]type{
        Mesh.Point,
    }, [_][]const gpu.VertexAttribute{
        point_attributes,
    });

    self.shader = try Shader.init(&graphics);

    try self.shader.addBuffer(allocator, mesh.points);
    try self.shader.addBuffer(allocator, mesh.camera);

    const texture = Mesh.Texture{
        .size = .{ 256, 256 },
        .data = &blk: {
            const border = 3;

            var pixels: [256 * 256]Mesh.Texture.Color = undefined;
            for (0..256) |y| for (0..256) |x| {
                pixels[y * 256 + x] = .{
                    0,
                    192,
                    0,
                    255,
                };

                if (x < border or x >= 256 - border or y < border or y >= 256 - border) {
                    pixels[y * 256 + x] = .{ 0, 0, 0, 255 };
                }
            };
            break :blk pixels;
        },
    };
    try self.shader.addTexture(allocator, graphics, texture);

    try self.shader.addBuffer(allocator, mesh.storage);

    const bind_group_layouts = &[_]*const gpu.BindGroupLayout{self.shader.bind_group_layout};

    self.layout = graphics.device.createPipelineLayout(&.{
        .label = "my pipeline layout",
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = bind_group_layouts.ptr,
    }) orelse return Error.FailedToCreatePipelineLayout;

    self.pipeline = graphics.device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = buffers.len,
            .buffers = buffers.ptr,
        },
        .primitive = gpu.PrimitiveState{
            .cull_mode = .back,
        },
        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = @intFromBool(true),
            .depth_compare = .less,
            .stencil_front = .{},
            .stencil_back = .{},
        },
        .fragment = &gpu.FragmentState{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = color_targets.ptr,
        },
        .multisample = gpu.MultisampleState{},
        .layout = self.layout,
    }) orelse return Error.FailedToCreateRenderPipeline;

    return self;
}

pub fn render(self: Renderer, graphics: Graphics, time: f32, camera: Camera) !void {
    _ = time;

    // update camera
    self.shader.update(graphics, Mesh.Camera, .projection, camera.getProjectionMatrix());
    self.shader.update(graphics, Mesh.Camera, .view, camera.getViewMatrix());

    // setup target view
    const next_texture = getCurrentTextureView(graphics.surface) catch return;
    defer next_texture.release();

    // setup encoder
    const encoder = graphics.device.createCommandEncoder(&.{
        .label = "my command encoder",
    }) orelse return Error.FailedToCreateCommandEncoder;
    defer encoder.release();

    // setup renderpass
    const color_attachments = &[_]gpu.ColorAttachment{.{
        .view = next_texture,
        .depth_slice = 0,
        .clear_value = gpu.Color{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
    }};

    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor{
        .label = "my render pass",
        .color_attachment_count = color_attachments.len,
        .color_attachments = color_attachments.ptr,
        .depth_stencil_attachment = &.{
            .view = self.depth_view,
            .depth_clear_value = 1.0,
            .depth_load_op = .clear,
            .depth_store_op = .store,
        },
    }) orelse return Error.FailedToBeginRenderPass;

    render_pass.setPipeline(self.pipeline);
    self.shader.render(render_pass);
    render_pass.end();
    render_pass.release();

    const command = encoder.finish(&.{
        .label = "command buffer",
    }) orelse return Error.FailedToFinishEncoder;
    defer command.release();

    graphics.queue.submit(&[_]*const gpu.CommandBuffer{command});
}

fn getCurrentTextureView(surface: *gpu.Surface) !*gpu.TextureView {
    var surface_texture: gpu.SurfaceTexture = undefined;

    surface.getCurrentTexture(&surface_texture);

    switch (surface_texture.status) {
        .success => return surface_texture.texture.createView(&.{
            .label = "Surface texture view",
            .format = surface_texture.texture.getFormat(),
            .dimension = .@"2d",
            .mip_level_count = 1,
            .array_layer_count = 1,
        }) orelse Error.FailedToCreateView,
        else => {
            std.debug.print("Failed to get current texture: {}\n", .{surface_texture.status});
            return Error.FailedToGetCurrentTexture;
        },
    }
}

fn initDepth(self: *Renderer, graphics: Graphics) !void {
    self.depth_texture = graphics.device.createTexture(&.{
        .usage = gpu.TextureUsage.render_attachment,
        .size = .{
            .width = self.width,
            .height = self.height,
        },
        .format = .depth24_plus,
    }) orelse return Error.FailedToCreateTexture;

    self.depth_view = self.depth_texture.createView(&.{
        .format = .depth24_plus,
        .dimension = .@"2d",
        .array_layer_count = 1,
        .mip_level_count = 1,
    }) orelse return Error.FailedToCreateView;
}

fn deinitDepth(self: *const Renderer) void {
    self.depth_view.release();
    self.depth_texture.destroy();
    self.depth_texture.release();
}

pub fn updateScale(self: *Renderer, graphics: Graphics, width: u32, height: u32) !void {
    self.width = width;
    self.height = height;

    self.deinitDepth();
    try self.initDepth(graphics);
}

pub fn deinit(self: Renderer) void {
    self.layout.release();
    self.pipeline.release();
    self.deinitDepth();
    self.shader.deinit();
}

fn attributeCount(comptime vertex_type: type) comptime_int {
    const fields = @typeInfo(vertex_type).@"struct".fields;

    var attribute_count = 0;

    for (fields) |field| {
        switch (@typeInfo(field.type)) {
            .vector => attribute_count += 1,
            .@"struct" => |t| {
                switch (t.layout) {
                    .@"packed" => attribute_count += 1,
                    else => {
                        if (!@hasDecl(field.type, "data_type")) @compileError("Data type of buffer must have decl data_type");
                        if (!@hasDecl(field.type, "shape")) @compileError("Data type of buffer must have decl shape");
                        if (std.meta.activeTag(@typeInfo(@TypeOf(field.type.shape))) != .@"struct") @compileError("Data type of buffer must have a shape tuple");
                        if (!@typeInfo(@TypeOf(field.type.shape)).@"struct".is_tuple) @compileError("Data type of buffer must have shape tuple longer than length 1");
                        attribute_count += field.type.shape.@"0";
                    },
                }
            },
            else => @compileError("unsupported type for vertex data"),
        }
    }

    return attribute_count;
}

fn getAttributes(
    comptime Vertex: type,
    comptime shader_location_offset: comptime_int,
) [attributeCount(Vertex)]gpu.VertexAttribute {
    const getFormat = struct {
        pub fn f(length: comptime_int, T: type) gpu.VertexFormat {
            if ((length == 1) and (T == u32)) return .uint32;
            if ((length == 2) and (T == f32)) return .float32x2;
            if ((length == 3) and (T == f32)) return .float32x3;
            if ((length == 4) and (T == f32)) return .float32x4;
            @compileError("unsupported type for vertex data");
        }
    }.f;

    return comptime blk: {
        if (!@hasDecl(Vertex, "buffer_type")) @compileError(std.fmt.comptimePrint(
            "Vertex type {} needs decl `buffer_type`",
            .{Vertex},
        ));
        if (@TypeOf(Vertex.buffer_type) != BufferTypeClass) @compileError(std.fmt.comptimePrint(
            "Vertex type {} needs decl `buffer_type` with type {}",
            .{ Vertex, BufferTypeClass },
        ));

        const fields = @typeInfo(Vertex).@"struct".fields;

        const AttributeUnion = union(enum) {
            attributes: []gpu.VertexAttribute,
            attribute: gpu.VertexAttribute,
        };

        var attribute_list: [fields.len]AttributeUnion = undefined;

        var attribute_count = 0;
        for (fields, 0..) |field, i| {
            switch (@typeInfo(field.type)) {
                .vector => |arr| {
                    attribute_list[i] = .{ .attribute = .{
                        .format = getFormat(arr.len, arr.child),
                        .offset = @offsetOf(Vertex, field.name),
                        .shader_location = shader_location_offset + attribute_count,
                    } };

                    attribute_count += 1;
                },
                .@"struct" => |t| {
                    switch (t.layout) {
                        .@"packed" => {
                            const T = std.meta.Int(.unsigned, 8 * @sizeOf(t.backing_integer.?));
                            attribute_list[i] = .{ .attribute = .{
                                .format = getFormat(1, T),
                                .offset = @offsetOf(Vertex, field.name),
                                .shader_location = shader_location_offset + attribute_count,
                            } };
                            attribute_count += 1;
                        },
                        else => {
                            assert(@hasDecl(field.type, "data_type"));
                            assert(@TypeOf(field.type.data_type) == DataType);
                            assert(field.type.data_type == .Matrix);

                            const shape = field.type.shape;

                            const T = @typeInfo(std.meta.fieldInfo(field.type, .data).type).vector.child;

                            var attributes: [shape.@"0"]gpu.VertexAttribute = undefined;

                            for (&attributes, 0..) |*a, col| {
                                a.* = .{
                                    .format = getFormat(shape.@"1", T),
                                    .offset = @offsetOf(Vertex, field.name) + (col * shape.@"1" * @sizeOf(T)),
                                    .shader_location = shader_location_offset + attribute_count,
                                };

                                attribute_count += 1;
                            }

                            attribute_list[i] = .{ .attributes = &attributes };
                        },
                    }
                },
                else => @compileError("unsupported type for vertex data"),
            }
        }

        var attributes: [attribute_count]gpu.VertexAttribute = undefined;

        var i = 0;
        for (attribute_list) |attribute_union| {
            switch (attribute_union) {
                .attribute => |a| {
                    attributes[i] = a;
                    i += 1;
                },
                .attributes => |as| {
                    for (as) |a| {
                        attributes[i] = a;
                        i += 1;
                    }
                },
            }
        }

        break :blk attributes;
    };
}

fn getVertexBufferLayoutCount(comptime Vertexs: []const type) comptime_int {
    var vertex_length = 0;
    for (Vertexs) |Vertex| {
        vertex_length += switch (Vertex.buffer_type) {
            .vertex, .instance => 1,
            else => 0,
        };
    }
    return vertex_length;
}

fn getVertexBufferLayouts(
    comptime Vertexs: []const type,
    buffer_attributes: [getVertexBufferLayoutCount(Vertexs)][]const gpu.VertexAttribute,
) [getVertexBufferLayoutCount(Vertexs)]gpu.VertexBufferLayout {
    var buffers: [getVertexBufferLayoutCount(Vertexs)]gpu.VertexBufferLayout = undefined;

    comptime var i = 0;
    inline for (Vertexs) |Vertex| {
        switch (Vertex.buffer_type) {
            .vertex, .instance => {},
            else => continue,
        }
        defer i += 1;

        const step_mode: gpu.VertexStepMode = switch (Vertex.buffer_type) {
            .vertex => .vertex,
            .instance => .instance,
            else => unreachable,
        };

        buffers[i] = .{
            .array_stride = @sizeOf(Vertex),
            .attribute_count = buffer_attributes[i].len,
            .attributes = buffer_attributes[i].ptr,
            .step_mode = step_mode,
        };
    }

    return buffers;
}
