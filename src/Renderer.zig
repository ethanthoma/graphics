const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const math = @import("math.zig");
const Mat4x4 = math.Mat4x4;
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");

const Renderer = @This();

pipeline: *gpu.RenderPipeline,
layout: *gpu.PipelineLayout,
bind_group_layout: *gpu.BindGroupLayout,
index_count: u32,
index_buffer: *gpu.Buffer,
point_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,

width: u32,
height: u32,

pub fn init(mesh: Mesh, graphics: Graphics, width: u32, height: u32) Renderer {
    var renderer: Renderer = undefined;

    renderer.width = width;
    renderer.height = height;

    const shader_module = graphics.device.createShaderModule(&gpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })).?;
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
                    .array => |arr| blk: {
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

    const entries = &[_]gpu.BindGroupLayoutEntry{.{
        .binding = 0,
        .visibility = gpu.ShaderStage.vertex | gpu.ShaderStage.fragment,
        .buffer = .{
            .type = .uniform,
            .min_binding_size = @sizeOf(Mesh.Uniform),
        },
        .sampler = .{},
        .texture = .{},
        .storage_texture = .{},
    }};

    renderer.bind_group_layout = graphics.device.createBindGroupLayout(&.{
        .label = "my bind group",
        .entry_count = entries.len,
        .entries = entries.ptr,
    }).?;

    const bind_group_layouts = &[_]*const gpu.BindGroupLayout{renderer.bind_group_layout};

    renderer.layout = graphics.device.createPipelineLayout(&.{
        .label = "my pipeline layout",
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = bind_group_layouts.ptr,
    }).?;

    renderer.pipeline = graphics.device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &[_]gpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(Mesh.Point),
                .attribute_count = attributes.len,
                .attributes = attributes,
            }},
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
        .layout = renderer.layout,
    }).?;

    renderer.index_count = @intCast(mesh.indices.len * @typeInfo(Mesh.Index).array.len);
    renderer.index_buffer = initIndexBuffer(mesh, graphics.device, graphics.queue);
    renderer.point_buffer = initPointBuffer(mesh, graphics.device, graphics.queue);
    renderer.uniform_buffer = initUniformBuffer(mesh, graphics.device, graphics.queue);
    renderer.bind_group = initBindGroup(graphics.device, renderer.bind_group_layout, renderer.uniform_buffer);

    return renderer;
}

fn initIndexBuffer(mesh: Mesh, device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const index_buffer = device.createBuffer(&.{
        .label = "index buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.index,
        .size = mesh.indices.len * @sizeOf(Mesh.Index),
    }).?;
    queue.writeBuffer(index_buffer, 0, mesh.indices.ptr, mesh.indices.len * @sizeOf(Mesh.Index));

    return index_buffer;
}

fn initPointBuffer(mesh: Mesh, device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const point_buffer = device.createBuffer(&.{
        .label = "point buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
        .size = mesh.points.len * @sizeOf(Mesh.Point),
    }).?;
    queue.writeBuffer(point_buffer, 0, mesh.points.ptr, mesh.points.len * @sizeOf(Mesh.Point));

    return point_buffer;
}

fn initUniformBuffer(mesh: Mesh, device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const uniform_buffer = device.createBuffer(&.{
        .label = "uniform buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.uniform,
        .size = @sizeOf(Mesh.Uniform),
    }).?;
    queue.writeBuffer(uniform_buffer, 0, &mesh.uniform, @sizeOf(Mesh.Uniform));

    return uniform_buffer;
}

fn initBindGroup(device: *gpu.Device, bind_group_layout: *gpu.BindGroupLayout, uniform_buffer: *gpu.Buffer) *gpu.BindGroup {
    const entries = &[_]gpu.BindGroupEntry{.{
        .binding = 0,
        .buffer = uniform_buffer,
        .size = @sizeOf(Mesh.Uniform),
    }};

    return device.createBindGroup(&.{
        .label = "bind group",
        .layout = bind_group_layout,
        .entry_count = entries.len,
        .entries = entries.ptr,
    }).?;
}

fn createRotationMatrix(time: f32) Mat4x4 {
    // Rotate around Y axis
    const cy = @cos(time);
    const sy = @sin(time);
    const ry = Mat4x4{
        cy,  0.0, sy,  0.0,
        0.0, 1.0, 0.0, 0.0,
        -sy, 0.0, cy,  0.0,
        0.0, 0.0, 0.0, 1.0,
    };

    // Rotate around X axis
    const cx = @cos(time * 0.5);
    const sx = @sin(time * 0.5);
    const rx = Mat4x4{
        1.0, 0.0, 0.0, 0.0,
        0.0, cx,  sx,  0.0,
        0.0, -sx, cx,  0.0,
        0.0, 0.0, 0.0, 1.0,
    };

    // Multiply matrices (rx * ry)
    var result: Mat4x4 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            var sum: f32 = 0.0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                sum += rx[i * 4 + k] * ry[k * 4 + j];
            }
            result[i * 4 + j] = sum;
        }
    }

    return result;
}

pub fn renderFrame(renderer: Renderer, graphics: Graphics, mesh: *Mesh, time: f32, camera: Camera) !void {
    // update camera
    mesh.uniform.projection = camera.getProjectionMatrix();
    graphics.queue.writeBuffer(
        renderer.uniform_buffer,
        @offsetOf(Mesh.Uniform, "projection"),
        &mesh.uniform.projection,
        @sizeOf(@TypeOf(mesh.uniform.projection)),
    );

    mesh.uniform.view = camera.getViewMatrix();
    graphics.queue.writeBuffer(
        renderer.uniform_buffer,
        @offsetOf(Mesh.Uniform, "view"),
        &mesh.uniform.view,
        @sizeOf(@TypeOf(mesh.uniform.view)),
    );

    // model for cube
    mesh.uniform.model = createRotationMatrix(time);
    graphics.queue.writeBuffer(
        renderer.uniform_buffer,
        @offsetOf(Mesh.Uniform, "model"),
        &mesh.uniform.model,
        @sizeOf(@TypeOf(mesh.uniform.model)),
    );

    // setup target view
    const next_texture = getCurrentTextureView(graphics.surface) catch return;
    defer next_texture.release();

    // setup encoder
    const encoder = graphics.device.createCommandEncoder(&.{
        .label = "my command encoder",
    }).?;
    defer encoder.release();

    // setup renderpass
    const color_attachments = &[_]gpu.ColorAttachment{.{
        .view = next_texture,
        .depth_slice = 0,
        .clear_value = gpu.Color{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
    }};

    const depth_texture = graphics.device.createTexture(&.{
        .size = .{
            .width = renderer.width,
            .height = renderer.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth24_plus,
        .usage = gpu.TextureUsage.render_attachment,
    }).?;
    defer depth_texture.release();

    const depth_view = depth_texture.createView(&.{
        .format = .depth24_plus,
        .dimension = .@"2d",
        .array_layer_count = 1,
        .mip_level_count = 1,
    }).?;
    defer depth_view.release();

    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor{
        .label = "my render pass",
        .color_attachment_count = color_attachments.len,
        .color_attachments = color_attachments.ptr,
        .depth_stencil_attachment = &.{
            .view = depth_view,
            .depth_clear_value = 1.0,
            .depth_load_op = .clear,
            .depth_store_op = .store,
        },
    }).?;

    render_pass.setPipeline(renderer.pipeline);
    render_pass.setVertexBuffer(0, renderer.point_buffer, 0, renderer.point_buffer.getSize());
    render_pass.setIndexBuffer(renderer.index_buffer, .uint16, 0, renderer.index_buffer.getSize());
    render_pass.setBindGroup(0, renderer.bind_group, 0, null);
    render_pass.drawIndexed(renderer.index_count, 1, 0, 0, 0);
    render_pass.end();
    render_pass.release();

    const command = encoder.finish(&.{
        .label = "command buffer",
    }).?;
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
        }).?,
        else => {
            std.debug.print("Failed to get current texture: {}\n", .{surface_texture.status});
            return error.FailedToGetCurrentTexture;
        },
    }
}

pub fn updateScale(renderer: *Renderer, queue: *gpu.Queue, width: u32, height: u32) void {
    _ = queue;
    renderer.width = width;
    renderer.height = height;
}

pub fn deinit(renderer: Renderer) void {
    renderer.bind_group.release();
    renderer.uniform_buffer.release();
    renderer.point_buffer.release();
    renderer.index_buffer.release();
    renderer.layout.release();
    renderer.bind_group_layout.release();
    renderer.pipeline.release();
}
