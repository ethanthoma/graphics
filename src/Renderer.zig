const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Renderer = @This();

pipeline: *gpu.RenderPipeline,
layout: *gpu.PipelineLayout,
bind_group_layout: *gpu.BindGroupLayout,
index_count: u32,
index_buffer: *gpu.Buffer,
point_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,

const mesh = struct {
    const Point = extern struct {
        position: Position,
        color: Color,

        const Position = [2]f32;
        const Color = [3]f32;
    };

    const Index = [3]u16;

    const Time = f32;

    const points = [_]Point{
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
        .{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
        .{ .position = .{ -0.5, 0.5 }, .color = .{ 1.0, 1.0, 1.0 } },
    };

    const indices = [_]Index{
        .{ 0, 1, 2 },
        .{ 0, 2, 3 },
    };

    const time = [1]Time{1};
};

pub fn init(device: *gpu.Device, queue: *gpu.Queue, surface_format: gpu.TextureFormat) Renderer {
    var renderer: Renderer = undefined;

    std.debug.print("createShaderModule\n", .{});
    const shader_module = device.createShaderModule(&gpu.shaderModuleWGSLDescriptor(.{
        .code = @embedFile("./shader.wgsl"),
    })).?;
    defer shader_module.release();

    // create render pipeline
    std.debug.print("color_targets\n", .{});
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

    std.debug.print("attributes\n", .{});
    const attributes = &comptime retval: {
        const fields = @typeInfo(mesh.Point).@"struct".fields;

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

            offset += @sizeOf(field.type);
        }

        break :retval _attributes;
    };

    const entries = &[_]gpu.BindGroupLayoutEntry{.{
        .binding = 0,
        .visibility = gpu.ShaderStage.vertex,
        .buffer = .{
            .type = .uniform,
            .min_binding_size = @sizeOf(mesh.Time),
        },
        .sampler = .{},
        .texture = .{},
        .storage_texture = .{},
    }};

    std.debug.print("createBindGroupLayout\n", .{});
    renderer.bind_group_layout = device.createBindGroupLayout(&.{
        .label = "my bind group",
        .entry_count = entries.len,
        .entries = entries.ptr,
    }).?;

    const bind_group_layouts = &[_]*const gpu.BindGroupLayout{renderer.bind_group_layout};

    std.debug.print("createPipelineLayout\n", .{});
    renderer.layout = device.createPipelineLayout(&.{
        .label = "my pipeline layout",
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = bind_group_layouts.ptr,
    }).?;

    std.debug.print("createRenderPipeline\n", .{});
    renderer.pipeline = device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &[_]gpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(mesh.Point),
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

    renderer.index_count = mesh.indices.len * @typeInfo(mesh.Index).array.len;
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
        .size = mesh.indices.len * @sizeOf(mesh.Index),
    }).?;
    queue.writeBuffer(index_buffer, 0, &mesh.indices, mesh.indices.len * @sizeOf(mesh.Index));

    return index_buffer;
}

fn initPointBuffer(device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const point_buffer = device.createBuffer(&.{
        .label = "point buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.vertex,
        .size = mesh.points.len * @sizeOf(mesh.Point),
    }).?;
    queue.writeBuffer(point_buffer, 0, &mesh.points, mesh.points.len * @sizeOf(mesh.Point));

    return point_buffer;
}

fn initUniformBuffer(device: *gpu.Device, queue: *gpu.Queue) *gpu.Buffer {
    const uniform_buffer = device.createBuffer(&.{
        .label = "time buffer",
        .usage = gpu.BufferUsage.copy_dst | gpu.BufferUsage.uniform,
        .size = @sizeOf(mesh.Time),
    }).?;
    queue.writeBuffer(uniform_buffer, 0, &mesh.time, @sizeOf(mesh.Time));

    return uniform_buffer;
}

fn initBindGroup(device: *gpu.Device, bind_group_layout: *gpu.BindGroupLayout, uniform_buffer: *gpu.Buffer) *gpu.BindGroup {
    const entries = &[_]gpu.BindGroupEntry{.{
        .binding = 0,
        .buffer = uniform_buffer,
        .size = @sizeOf(mesh.Time),
    }};

    return device.createBindGroup(&.{
        .label = "bind group",
        .layout = bind_group_layout,
        .entry_count = entries.len,
        .entries = entries.ptr,
    }).?;
}

pub fn renderFrame(renderer: Renderer, device: *gpu.Device, surface: *gpu.Surface, queue: *gpu.Queue, time: f32) !void {
    // update uniform_buffer
    queue.writeBuffer(renderer.uniform_buffer, 0, &time, @sizeOf(@TypeOf(time)));

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
        .label = "my redner pass",
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

pub fn deinit(renderer: Renderer) void {
    renderer.bind_group.release();
    renderer.uniform_buffer.release();
    renderer.point_buffer.release();
    renderer.index_buffer.release();
    renderer.layout.release();
    renderer.bind_group_layout.release();
    renderer.pipeline.release();
}
