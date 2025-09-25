const std = @import("std");

const glfw = @import("zglfw");
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

pub fn init(mesh: Mesh, window: *glfw.Window) !Graphics {
    _ = mesh; // TODO: Re-enable once limits API is stable
    // create instance
    const instance = gpu.Instance.create(null) orelse return Error.FailedToCreateInstance;
    defer instance.release();

    // create surface
    const surface = try glfwGetWGPUSurface(instance, window) orelse return Error.FailedToCreateSurface;
    errdefer surface.release();

    // get adapter
    const adapter_response = instance.requestAdapterSync(&.{ .compatible_surface = surface }, 1000000);
    const adapter: *gpu.Adapter = switch (adapter_response.status) {
        .success => adapter_response.adapter.?,
        else => return Error.FailedToGetAdapter,
    };
    defer adapter.release();

    // get device
    const required_features = &[_]gpu.FeatureName{
        .vertex_writable_storage,
        .push_constants,
        .indirect_first_instance,
    };

    const push_constant_size = Mesh.getMaxPushSize();
    var native_limits = gpu.WGPUNativeLimits{
        .max_push_constant_size = push_constant_size,
        .max_non_sampler_bindings = gpu.U32_MAX,
    };
    const required_limits = gpu.Limits{ .next_in_chain = @ptrCast(&native_limits) };

    const device_response = adapter.requestDeviceSync(instance, &gpu.DeviceDescriptor{
        .label = gpu.StringView.fromSlice("main device"),
        .required_limits = &required_limits,
        .required_features = required_features.ptr,
        .required_feature_count = required_features.len,
    }, 1000000);

    const device = switch (device_response.status) {
        .success => device_response.device.?,
        else => return Error.FailedToGetDevice,
    };
    errdefer device.release();

    // get queue
    const queue = device.getQueue() orelse return Error.FailedToGetQueue;

    // configure surface
    var capabilites = gpu.SurfaceCapabilities{
        .usages = 0,
        .format_count = 0,
        .formats = undefined,
        .present_mode_count = 0,
        .present_modes = undefined,
        .alpha_mode_count = 0,
        .alpha_modes = undefined,
    };
    _ = surface.getCapabilities(adapter, &capabilites);
    const surface_format = capabilites.formats[0];

    return .{
        .device = device,
        .queue = queue,
        .surface = surface,
        .surface_format = surface_format,
    };
}

fn getRequiredLimits(mesh: Mesh, adapter: *gpu.Adapter) gpu.RequiredLimits {
    _ = mesh;
    var supported_limits: gpu.SupportedLimits = .{
        .limits = .{},
    };

    _ = adapter.getLimits(&supported_limits);

    var required_limits: gpu.RequiredLimits = .{
        .limits = .{},
    };

    // TODO: automate this; mostly just needs type information from shader.zig
    required_limits.limits.max_vertex_attributes = 13;
    // std.meta.fields(Mesh.Point).len;
    required_limits.limits.max_vertex_buffers = Mesh.getMaxVertexBuffers();
    required_limits.limits.max_inter_stage_shader_components = 13; // from shader code itself

    // this needs to know an upper bound on my vertices
    required_limits.limits.max_buffer_size = Mesh.getMaxBufferSize();
    // should be derived from shader types passed into Graphics struct
    required_limits.limits.max_vertex_buffer_array_stride = Mesh.getMaxVertexBufferArrayStride();

    required_limits.limits.max_texture_array_layers = 1;
    required_limits.limits.max_sampled_textures_per_shader_stage = 1;

    required_limits.limits.max_bind_groups = 1; // manual for now
    required_limits.limits.max_bindings_per_bind_group = 3;

    required_limits.limits.max_uniform_buffers_per_shader_stage = 3; // same
    required_limits.limits.max_uniform_buffer_binding_size = Mesh.getMaxUniformBufferBindingSize();

    required_limits.limits.max_storage_buffers_per_shader_stage = 3;
    required_limits.limits.max_storage_buffer_binding_size = Mesh.getMaxStorageBufferBindingSize();
    required_limits.limits.max_storage_textures_per_shader_stage = 3;
    required_limits.limits.max_dynamic_storage_buffers_per_pipeline_layout = 3;

    required_limits.limits.min_uniform_buffer_offset_alignment = supported_limits.limits.min_uniform_buffer_offset_alignment;
    required_limits.limits.min_storage_buffer_offset_alignment = supported_limits.limits.min_storage_buffer_offset_alignment;

    return required_limits.withNativeLimits(
        .{
            .max_push_constant_size = Mesh.getMaxPushSize(),
            .max_non_sampler_bindings = 0,
        },
    );
}

pub fn deinit(self: *Graphics) void {
    self.surface.release();
    self.queue.release();
    self.device.release();
}

extern fn glfwGetWaylandDisplay() ?*anyopaque;
extern fn glfwGetWaylandWindow(window: *anyopaque) ?*anyopaque;

fn glfwGetWGPUSurface(instance: *gpu.Instance, window: *glfw.Window) !?*gpu.Surface {
    const builtin = @import("builtin");

    if (builtin.target.os.tag == .linux) {
        const wayland_display = glfwGetWaylandDisplay();
        const wayland_surface = glfwGetWaylandWindow(@ptrCast(window));

        if (wayland_display != null and wayland_surface != null) {
            const descriptor = gpu.surfaceDescriptorFromWaylandSurface(.{
                .display = wayland_display.?,
                .surface = wayland_surface.?,
            });
            return instance.createSurface(&descriptor);
        }

        std.debug.print("Error: Wayland display/surface not available\n", .{});
    }

    return Error.FailedToCreateSurface;
}
