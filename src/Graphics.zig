const std = @import("std");

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Mesh = @import("Mesh.zig");

const Graphics = @This();

pub const Error = error{
    FailedToCreateInstance,
    FailedToCreateSurface,
    FailedToGetAdapter,
    FailedToGetDevice,
    FailedToGetQueue,
};

device: *gpu.Device,
queue: *gpu.Queue,
surface: *gpu.Surface,
surface_format: gpu.TextureFormat,

pub fn init(mesh: Mesh, window: glfw.Window) !Graphics {
    // create instance
    const instance = gpu.Instance.create(null) orelse return Error.FailedToCreateInstance;
    defer instance.release();

    // create surface
    const surface = try glfwGetWGPUSurface(instance, window) orelse return Error.FailedToCreateSurface;
    errdefer surface.release();

    // get adapter
    const adapter_response = instance.requestAdapterSync(&.{
        .compatible_surface = surface,
    });
    const adapter: *gpu.Adapter = switch (adapter_response.status) {
        .success => adapter_response.adapter.?,
        else => return Error.FailedToGetAdapter,
    };
    defer adapter.release();

    // get device
    const device_response = adapter.requestDeviceSync(&.{
        .label = "My Device",
        .required_limits = &getRequiredLimits(mesh, adapter),
    });
    const device = switch (device_response.status) {
        .success => device_response.device.?,
        else => return Error.FailedToGetDevice,
    };
    errdefer device.release();

    // get queue
    const queue = device.getQueue() orelse return Error.FailedToGetQueue;

    // configure surface
    var capabilites: gpu.SurfaceCapabilities = .{};
    surface.getCapabilities(adapter, &capabilites);
    const surface_format = capabilites.formats[0];

    return .{
        .device = device,
        .queue = queue,
        .surface = surface,
        .surface_format = surface_format,
    };
}

fn getRequiredLimits(mesh: Mesh, adapter: *gpu.Adapter) gpu.RequiredLimits {
    var supported_limits: gpu.SupportedLimits = .{
        .limits = .{},
    };

    _ = adapter.getLimits(&supported_limits);

    var required_limits: gpu.RequiredLimits = .{
        .limits = .{},
    };

    // TODO: automate this
    required_limits.limits.max_vertex_attributes = 6;
    // std.meta.fields(Mesh.Point).len;
    required_limits.limits.max_vertex_buffers = 2; // should find a way to automate this
    required_limits.limits.max_inter_stage_shader_components = 6; // from shader code itself

    required_limits.limits.max_buffer_size = mesh.getMaxBufferSize();
    required_limits.limits.max_vertex_buffer_array_stride = @sizeOf(Mesh.Instance);

    required_limits.limits.max_texture_array_layers = 1;
    required_limits.limits.max_sampled_textures_per_shader_stage = 1;

    required_limits.limits.max_bind_groups = 1; // manual for now
    required_limits.limits.max_uniform_buffers_per_shader_stage = 1; // same
    required_limits.limits.max_uniform_buffer_binding_size = mesh.getMaxUniformBufferBindingSize();

    required_limits.limits.min_uniform_buffer_offset_alignment = supported_limits.limits.min_uniform_buffer_offset_alignment;
    required_limits.limits.min_storage_buffer_offset_alignment = supported_limits.limits.min_storage_buffer_offset_alignment;

    return required_limits;
}

pub fn deinit(self: *Graphics) void {
    self.surface.release();
    self.queue.release();
    self.surface.release();
    self.device.release();
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
