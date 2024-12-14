const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");

const gpu = @import("wgpu");

const Error = error{
    FailedToInitializeGLFW,
    FailedToOpenWindow,
    FailedToCreateInstance,
    FailedToGetSurface,
    FailedToGetAdapter,
    FailedToGetDevice,
    FailedToGetQueue,
    FailedToGetWaylandDisplay,
    FailedToGetWaylandWindow,
    FailedToGetTextureView,
    FailedToGetCurrentTexture,
};

fn errorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

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

pub const App = struct {
    const Self = @This();

    window: glfw.Window,
    device: *gpu.Device,
    queue: *gpu.Queue,
    surface: *gpu.Surface,
    surface_format: gpu.TextureFormat,
    pipeline: *gpu.RenderPipeline,
    index_count: u32 = mesh.indices.len * @typeInfo(mesh.Index).array.len,
    index_buffer: *gpu.Buffer,
    point_buffer: *gpu.Buffer,

    pub fn init() !Self {
        glfw.setErrorCallback(errorCallback);
        if (!glfw.init(.{})) {
            std.debug.print("Failed to initialize GLFW\n", .{});
        }
        errdefer glfw.terminate();

        // Open window
        std.debug.print("Opening window\n", .{});

        const window: glfw.Window = glfw.Window.create(640, 480, "VOXEL", null, null, .{
            .resizable = false,
            .client_api = .no_api,
        }) orelse {
            std.debug.print("Failed to open window\n", .{});
            return Error.FailedToOpenWindow;
        };
        errdefer glfw.Window.destroy(window);

        const size = window.getFramebufferSize();

        // Create instance
        std.debug.print("Creating instance\n", .{});

        const instance = gpu.Instance.create(null) orelse {
            std.debug.print("Failed to create gpu instance\n", .{});
            return Error.FailedToCreateInstance;
        };
        defer instance.release();

        // Create surface
        std.debug.print("Creating surface\n", .{});

        const surface: *gpu.Surface = try glfwGetWGPUSurface(instance, window) orelse {
            return Error.FailedToGetSurface;
        };
        errdefer surface.release();

        // Get adapter
        std.debug.print("Get adapter\n", .{});

        const adapter_response = instance.requestAdapterSync(&.{
            .compatible_surface = surface,
        });
        const adapter: *gpu.Adapter = switch (adapter_response.status) {
            .success => adapter_response.adapter.?,
            else => return Error.FailedToGetAdapter,
        };
        defer adapter.release();

        // Get device
        std.debug.print("Get device\n", .{});

        const device_response = adapter.requestDeviceSync(&.{
            .label = "My Device",
            .required_limits = &getRequiredLimits(adapter),
        });
        const device: *gpu.Device = switch (device_response.status) {
            .success => device_response.device.?,
            else => return Error.FailedToGetDevice,
        };

        // Get queue
        std.debug.print("Get queue\n", .{});

        const queue = device.getQueue() orelse return Error.FailedToGetQueue;

        // Configure surface
        std.debug.print("Configure surface\n", .{});

        var capabilites: gpu.SurfaceCapabilities = .{};
        surface.getCapabilities(adapter, &capabilites);
        const surface_format = capabilites.formats[0];

        surface.configure(&.{
            .device = device,
            .format = surface_format,
            .width = size.width,
            .height = size.height,
        });

        const pipeline = initPipeline(device, surface_format);
        const index_buffer = initIndexBuffer(device, queue);
        const point_buffer = initPointBuffer(device, queue);

        return Self{
            .window = window,
            .device = device,
            .queue = queue,
            .surface = surface,
            .surface_format = surface_format,
            .pipeline = pipeline,
            .index_buffer = index_buffer,
            .point_buffer = point_buffer,
        };
    }

    fn initPipeline(device: *gpu.Device, surface_format: gpu.TextureFormat) *gpu.RenderPipeline {
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

        return device.createRenderPipeline(&gpu.RenderPipelineDescriptor{
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

    pub fn deinit(self: *Self) void {
        self.index_buffer.release();
        self.point_buffer.release();
        self.pipeline.release();
        self.surface.release();
        self.queue.release();
        self.surface.release();
        self.device.release();
        self.window.destroy();
        glfw.terminate();
    }

    pub fn run(self: *Self) void {
        glfw.pollEvents();

        // setup target view
        const next_texture = self.getNextSurfaceTextureView() catch return;
        defer next_texture.release();

        // setup encoder
        const encoder = self.device.createCommandEncoder(&.{
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

        render_pass.setPipeline(self.pipeline);
        render_pass.setVertexBuffer(0, self.point_buffer, 0, self.point_buffer.getSize());
        render_pass.setIndexBuffer(self.index_buffer, .uint16, 0, self.index_buffer.getSize());
        render_pass.drawIndexed(self.index_count, 1, 0, 0, 0);
        render_pass.end();
        render_pass.release();

        const command = encoder.finish(&.{
            .label = "command buffer",
        }).?;
        defer command.release();

        self.queue.submit(&[_]*const gpu.CommandBuffer{command});

        self.surface.present();

        _ = self.device.poll(true, null);
    }

    fn getNextSurfaceTextureView(self: *Self) !*gpu.TextureView {
        var surface_texture: gpu.SurfaceTexture = undefined;

        self.surface.getCurrentTexture(&surface_texture);

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
                return Error.FailedToGetCurrentTexture;
            },
        }
    }

    pub fn isRunning(self: *Self) bool {
        return !glfw.Window.shouldClose(self.window);
    }
};

fn getRequiredLimits(adapter: *gpu.Adapter) gpu.RequiredLimits {
    var supportedLimits: gpu.SupportedLimits = .{
        .limits = .{},
    };

    _ = adapter.getLimits(&supportedLimits);

    var requiredLimits: gpu.RequiredLimits = .{
        .limits = .{},
    };

    requiredLimits.limits.max_vertex_attributes = 2;
    requiredLimits.limits.max_vertex_buffers = 1;
    requiredLimits.limits.max_buffer_size = @typeInfo(mesh.Index).array.len * mesh.indices.len * @sizeOf(mesh.Point);
    requiredLimits.limits.max_vertex_buffer_array_stride = @sizeOf(mesh.Point);
    requiredLimits.limits.max_inter_stage_shader_components = 3;

    requiredLimits.limits.min_uniform_buffer_offset_alignment = supportedLimits.limits.min_uniform_buffer_offset_alignment;
    requiredLimits.limits.min_storage_buffer_offset_alignment = supportedLimits.limits.min_storage_buffer_offset_alignment;

    return requiredLimits;
}

// wayland only
fn glfwGetWGPUSurface(instance: *gpu.Instance, window: glfw.Window) !?*gpu.Surface {
    const Native = glfw.Native(.{ .wayland = true });

    return instance.createSurface(&.{
        .next_in_chain = &(gpu.SurfaceDescriptorFromWaylandSurface{
            .display = Native.getWaylandDisplay(),
            .surface = Native.getWaylandWindow(window),
        }).chain,
        .label = null,
    });
}
