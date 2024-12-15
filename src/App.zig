const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Renderer = @import("Renderer.zig");
const Camera = @import("Camera.zig");

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

const App = @This();

self: *App,
allocator: std.mem.Allocator,
window: glfw.Window,
device: *gpu.Device,
queue: *gpu.Queue,
surface: *gpu.Surface,
surface_format: gpu.TextureFormat,
renderer: ?Renderer,

width: u32,
height: u32,
camera: Camera,

resize_context: struct {
    device: *gpu.Device,
    surface: *gpu.Surface,
    surface_format: gpu.TextureFormat,
},

pub fn init(allocator: std.mem.Allocator) !*App {
    var app = try allocator.create(App);

    app.self = app;
    app.allocator = allocator;
    app.renderer = null;
    app.width = 640;
    app.height = 480;
    app.camera = Camera{};

    try initWindowAndDevice(app);
    std.debug.print("setup renderer...", .{});
    app.renderer = Renderer.init(app.device, app.queue, app.surface_format, app.width, app.height);

    return app;
}

fn initWindowAndDevice(app: *App) !void {
    // init glfw
    glfw.setErrorCallback(errorCallback);
    if (!glfw.init(.{})) {
        std.debug.print("Failed to initialize GLFW\n", .{});
    }
    errdefer glfw.terminate();

    // Create instance
    const instance = gpu.Instance.create(null) orelse {
        std.debug.print("Failed to create gpu instance\n", .{});
        return Error.FailedToCreateInstance;
    };
    defer instance.release();

    // Open window
    app.window = glfw.Window.create(app.width, app.height, "VOXEL", null, null, .{
        .resizable = false,
        .client_api = .no_api,
    }) orelse {
        std.debug.print("Failed to open window\n", .{});
        return Error.FailedToOpenWindow;
    };
    errdefer app.window.destroy();

    // Create surface
    app.surface = try glfwGetWGPUSurface(instance, app.window) orelse {
        return Error.FailedToGetSurface;
    };
    errdefer app.surface.release();

    // Get adapter
    const adapter_response = instance.requestAdapterSync(&.{
        .compatible_surface = app.surface,
    });
    const adapter: *gpu.Adapter = switch (adapter_response.status) {
        .success => adapter_response.adapter.?,
        else => return Error.FailedToGetAdapter,
    };
    defer adapter.release();

    // Get device
    const device_response = adapter.requestDeviceSync(&.{
        .label = "My Device",
        .required_limits = &getRequiredLimits(adapter),
    });
    app.device = switch (device_response.status) {
        .success => device_response.device.?,
        else => return Error.FailedToGetDevice,
    };

    // Get queue
    app.queue = app.device.getQueue() orelse return Error.FailedToGetQueue;

    // Configure surface
    var capabilites: gpu.SurfaceCapabilities = .{};
    app.surface.getCapabilities(adapter, &capabilites);
    app.surface_format = capabilites.formats[0];

    app.resize_context = .{
        .device = app.device,
        .surface = app.surface,
        .surface_format = app.surface_format,
    };

    app.window.setUserPointer(app);
    app.window.setFramebufferSizeCallback(onWindowResize);

    const size = app.window.getFramebufferSize();
    onWindowResize(app.window, size.width, size.height);
}

pub fn deinit(self: *App) void {
    self.renderer.?.deinit();
    self.surface.release();
    self.queue.release();
    self.surface.release();
    self.device.release();
    self.window.destroy();
    glfw.terminate();
    self.self.allocator.destroy(self.self);
}

pub fn run(self: *App) void {
    glfw.pollEvents();

    const time: f32 = @floatCast(glfw.getTime());

    try self.renderer.?.renderFrame(self.device, self.surface, self.queue, time, self.camera);

    self.surface.present();

    _ = self.device.poll(true, null);
}

pub fn isRunning(self: *App) bool {
    return !glfw.Window.shouldClose(self.window);
}

fn getRequiredLimits(adapter: *gpu.Adapter) gpu.RequiredLimits {
    var supported_limits: gpu.SupportedLimits = .{
        .limits = .{},
    };

    _ = adapter.getLimits(&supported_limits);

    var required_limits: gpu.RequiredLimits = .{
        .limits = .{},
    };

    required_limits.limits.max_vertex_attributes = 2;
    required_limits.limits.max_vertex_buffers = 1;
    required_limits.limits.max_inter_stage_shader_components = 3;

    required_limits.limits.max_buffer_size = 15 * 5 * @sizeOf(f32);
    required_limits.limits.max_vertex_buffer_array_stride = 6 * @sizeOf(f32);

    required_limits.limits.max_bind_groups = 1;
    required_limits.limits.max_uniform_buffers_per_shader_stage = 1;
    required_limits.limits.max_uniform_buffer_binding_size = 52 * 4;

    required_limits.limits.min_uniform_buffer_offset_alignment = supported_limits.limits.min_uniform_buffer_offset_alignment;
    required_limits.limits.min_storage_buffer_offset_alignment = supported_limits.limits.min_storage_buffer_offset_alignment;

    return required_limits;
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

fn onWindowResize(window: glfw.Window, width: u32, height: u32) void {
    const app: *App = window.getUserPointer(App) orelse return;

    app.width = width;
    app.height = height;

    std.debug.print("resized {}, {}\n", .{ width, height });

    app.surface.configure(&.{
        .device = app.device,
        .format = app.surface_format,
        .width = width,
        .height = height,
    });

    if (app.renderer) |*renderer| renderer.updateScale(app.queue, width, height);
}
