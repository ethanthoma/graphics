const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const math = @import("math.zig");
const Mat4x4 = math.Mat4x4;
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");
const Shader = @import("Shader.zig");

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

pub fn init(mesh: Mesh, graphics: Graphics, width: u32, height: u32) !Renderer {
    var self: Renderer = undefined;

    self.width = width;
    self.height = height;

    try self.initDepth(graphics);

    const shader_module = graphics.device.createShaderModule(&gpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })) orelse return Error.FailedToCreateShaderModule;
    defer shader_module.release();

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

    const attributes = &comptime retval: {
        const fields = @typeInfo(Mesh.Point).@"struct".fields;

        var _attributes: [fields.len]gpu.VertexAttribute = undefined;

        for (fields, 0..) |field, i| {
            const field_type = @typeInfo(field.type);

            _attributes[i] = .{
                .format = switch (field_type) {
                    .vector => |arr| blk: {
                        if ((arr.len == 2) and (arr.child == f32)) break :blk .float32x2;
                        if ((arr.len == 3) and (arr.child == f32)) break :blk .float32x3;
                        @compileError("unsupported type for vertex data");
                    },
                    else => @compileError("unsupported type for vertex data"),
                },
                .offset = @offsetOf(Mesh.Point, field.name),
                .shader_location = i,
            };
        }

        break :retval _attributes;
    };

    const instance_attributes = &[_]gpu.VertexAttribute{
        .{
            .format = .float32x4,
            .offset = @sizeOf(f32) * 0,
            .shader_location = 2,
        },
        .{
            .format = .float32x4,
            .offset = @sizeOf(f32) * 4,
            .shader_location = 3,
        },
        .{
            .format = .float32x4,
            .offset = @sizeOf(f32) * 8,
            .shader_location = 4,
        },
        .{
            .format = .float32x4,
            .offset = @sizeOf(f32) * 12,
            .shader_location = 5,
        },
    };

    const buffers = &[_]gpu.VertexBufferLayout{ .{
        .array_stride = @sizeOf(Mesh.Point),
        .attribute_count = attributes.len,
        .attributes = attributes.ptr,
    }, .{
        .array_stride = @sizeOf(Mesh.Instance),
        .attribute_count = instance_attributes.len,
        .attributes = instance_attributes.ptr,
        .step_mode = .instance,
    } };

    self.shader = try Shader.init(mesh, graphics);

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

pub fn render(self: Renderer, graphics: Graphics, mesh: *Mesh, time: f32, camera: Camera) !void {
    _ = time;

    // update camera
    mesh.uniform.projection = camera.getProjectionMatrix();
    graphics.queue.writeBuffer(
        self.shader.uniform_buffer,
        @offsetOf(Mesh.Uniform, "projection"),
        &mesh.uniform.projection,
        @sizeOf(@TypeOf(mesh.uniform.projection)),
    );

    mesh.uniform.view = camera.getViewMatrix();
    graphics.queue.writeBuffer(
        self.shader.uniform_buffer,
        @offsetOf(Mesh.Uniform, "view"),
        &mesh.uniform.view,
        @sizeOf(@TypeOf(mesh.uniform.view)),
    );

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
        .size = .{
            .width = self.width,
            .height = self.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth24_plus,
        .usage = gpu.TextureUsage.render_attachment,
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
