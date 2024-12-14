const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Renderer = @This();

pipeline: *gpu.RenderPipeline,
index_count: u32,
index_buffer: *gpu.Buffer,
point_buffer: *gpu.Buffer,

const mesh = struct {
    const Point = extern struct {
        position: Position,
        color: Color,

        const Position = [2]f32;
        const Color = [3]f32;
    };

    const Index = [3]u16;

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

    const positions = blk: {
        var pos: [points.len]Point.Position = undefined;
        for (points, 0..) |p, i| pos[i] = p.position;
        break :blk pos;
    };

    const colors = blk: {
        var col: [points.len]Point.Color = undefined;
        for (points, 0..) |p, i| col[i] = p.color;
        break :blk col;
    };
};

pub fn init(device: *gpu.Device, queue: *gpu.Queue, surface_format: gpu.TextureFormat) Renderer {
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

    const attributes = &[_]gpu.VertexAttribute{
        .{
            .format = .float32x2,
            .offset = 0,
            .shader_location = 0,
        },
        .{
            .format = .float32x3,
            .offset = 2 * @sizeOf(f32),
            .shader_location = 1,
        },
    };

    const pipeline = device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &[_]gpu.VertexBufferLayout{.{
                .array_stride = 5 * @sizeOf(f32),
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
    }).?;

    return .{
        .pipeline = pipeline,
        .index_count = mesh.indices.len * @typeInfo(mesh.Index).array.len,
        .index_buffer = initIndexBuffer(device, queue),
        .point_buffer = initPointBuffer(device, queue),
    };
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

pub fn renderFrame(renderer: Renderer, device: *gpu.Device, surface: *gpu.Surface, queue: *gpu.Queue) !void {
    // setup target view
    const next_texture = getCurrentTextureView(surface) catch return;
    defer next_texture.release();

    // setup encoder
    const encoder = device.createCommandEncoder(&.{
        .label = "my command encoder",
    }).?;
    defer encoder.release();

    // setup renderpass
    const color_attachments = &[_]gpu.ColorAttachment{gpu.ColorAttachment{
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
    renderer.point_buffer.release();
    renderer.index_buffer.release();
    renderer.pipeline.release();
}
