const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

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

var mesh = Mesh{
    .points = ([_]Mesh.Point{
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        .{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
        .{ .position = .{ -0.5, 0.5 }, .color = .{ 1.0, 1.0, 1.0 } },
    })[0..],

    .indices = ([_]Mesh.Index{
        .{ 0, 1, 2 },
        .{ 0, 2, 3 },
    })[0..],

    .uniform = .{},
};

pub fn init(device: *gpu.Device, queue: *gpu.Queue, surface_format: gpu.TextureFormat) Renderer {
    var renderer: Renderer = undefined;

    const shader_module = device.createShaderModule(&gpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })).?;
    defer shader_module.release();

    // create render pipeline
    const color_targets = &[_]gpu.ColorTargetState{
        gpu.ColorTargetState{
            .format = surface_format,
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

        var offset = 0;
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
                .offset = offset,
                .shader_location = i,
            };

            // TODO: use @offsetOf
            offset += @sizeOf(field.type);
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

    renderer.bind_group_layout = device.createBindGroupLayout(&.{
        .label = "my bind group",
        .entry_count = entries.len,
        .entries = entries.ptr,
    }).?;

    const bind_group_layouts = &[_]*const gpu.BindGroupLayout{renderer.bind_group_layout};

    renderer.layout = device.createPipelineLayout(&.{
        .label = "my pipeline layout",
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = bind_group_layouts.ptr,
    }).?;

    renderer.pipeline = device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
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
        .primitive = gpu.PrimitiveState{},
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
    renderer.index_buffer = initIndexBuffer(device, queue);
    renderer.point_buffer = initPointBuffer(device, queue);
    renderer.uniform_buffer = initUniformBuffer(device, queue);
    renderer.bind_group = initBindGroup(device, renderer.bind_group_layout, renderer.uniform_buffer);

    return renderer;
}

fn initIndexBuffer(device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const index_buffer = device.createBuffer(&.{
        .label = "index buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.index,
        .size = mesh.indices.len * @sizeOf(Mesh.Index),
    }).?;
    queue.writeBuffer(index_buffer, 0, mesh.indices.ptr, mesh.indices.len * @sizeOf(Mesh.Index));

    return index_buffer;
}

fn initPointBuffer(device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const point_buffer = device.createBuffer(&.{
        .label = "point buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
        .size = mesh.points.len * @sizeOf(Mesh.Point),
    }).?;
    queue.writeBuffer(point_buffer, 0, mesh.points.ptr, mesh.points.len * @sizeOf(Mesh.Point));

    return point_buffer;
}

fn initUniformBuffer(device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
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

pub fn renderFrame(renderer: Renderer, device: *gpu.Device, surface: *gpu.Surface, queue: *gpu.Queue, time: f32) !void {
    // update time
    mesh.uniform.time = time;
    queue.writeBuffer(
        renderer.uniform_buffer,
        @offsetOf(Mesh.Uniform, "time"),
        &mesh.uniform.time,
        @sizeOf(@TypeOf(mesh.uniform.time)),
    );

    // setup target view
    const next_texture = getCurrentTextureView(surface) catch return;
    defer next_texture.release();

    // setup encoder
    const encoder = device.createCommandEncoder(&.{
        .label = "my command encoder",
    }).?;
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

    queue.submit(&[_]*const gpu.CommandBuffer{command});
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

pub fn updateScale(renderer: Renderer, queue: *gpu.Queue, width: u32, height: u32) void {
    mesh.uniform.scale = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    std.debug.print("scale: {}\n", .{mesh.uniform.scale});

    queue.writeBuffer(
        renderer.uniform_buffer,
        @offsetOf(Mesh.Uniform, "scale"),
        &mesh.uniform.scale,
        @sizeOf(@TypeOf(mesh.uniform.scale)),
    );
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