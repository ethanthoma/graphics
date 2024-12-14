const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Renderer = @import("Renderer.zig");

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

window: glfw.Window,
device: *gpu.Device,
queue: *gpu.Queue,
surface: *gpu.Surface,
surface_format: gpu.TextureFormat,
renderer: Renderer,

pub fn init() !App {
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

    const renderer = Renderer.init(device, queue, surface_format);

    return .{
        .window = window,
        .device = device,
        .queue = queue,
        .surface = surface,
        .surface_format = surface_format,
        .renderer = renderer,
    };
}

pub fn deinit(self: *App) void {
    self.renderer.deinit();
    self.surface.release();
    self.queue.release();
    self.surface.release();
    self.device.release();
    self.window.destroy();
    glfw.terminate();
}

pub fn run(self: *App) void {
    glfw.pollEvents();

    try self.renderer.renderFrame(self.device, self.surface, self.queue);

    self.surface.present();

    _ = self.device.poll(true, null);
}

pub fn isRunning(self: *App) bool {
    return !glfw.Window.shouldClose(self.window);
}

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
