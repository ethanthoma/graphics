const std = @import("std");
const assert = std.debug.assert;

const glfw3 = @cImport({
    @cInclude("glfw3.h");
    @cDefine("GLFW_EXPOSE_NATIVE_WAYLAND", {});
    @cInclude("glfw3native.h");
});

const wgpu = @cImport({
    @cInclude("wgpu.h");
});

const glfw3_wgpu = @cImport({
    @cInclude("glfw3webgpu.h");
});

const Error = error{
    FailedToInitializeGLFW,
    FailedToOpenWindow,
    FailedToCreateInstance,
    FailedToGetAdapter,
    FailedToGetDevice,
    FailedToGetQueue,
    FailedToGetWaylandDisplay,
    FailedToGetWaylandWindow,
    FailedToGetTextureView,
    FailedToGetCurrentTexture,
};

pub const App = struct {
    const Self = @This();

    window: *glfw3.GLFWwindow,
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,
    surface: wgpu.WGPUSurface,
    surfaceFormat: wgpu.WGPUTextureFormat,
    pipeline: wgpu.WGPURenderPipeline,

    pub fn init() !Self {
        // Open window
        const retval = glfw3.glfwInit();
        if (retval == glfw3.GL_FALSE) {
            std.debug.print("Failed to initialize GLFW\n", .{});
            return Error.FailedToInitializeGLFW;
        }
        errdefer glfw3.glfwTerminate();

        // Set window hints BEFORE window creation
        glfw3.glfwWindowHint(glfw3.GLFW_CLIENT_API, glfw3.GLFW_NO_API);
        glfw3.glfwWindowHint(glfw3.GLFW_RESIZABLE, glfw3.GLFW_FALSE);

        std.debug.print("Opening window\n", .{});
        const window: *glfw3.GLFWwindow = glfw3.glfwCreateWindow(640, 480, "VOXEL", null, null) orelse {
            std.debug.print("Failed to open window\n", .{});
            return Error.FailedToOpenWindow;
        };
        errdefer glfw3.glfwDestroyWindow(window);

        // Create instance
        std.debug.print("Creating instance\n", .{});
        const instance: wgpu.WGPUInstance = wgpu.wgpuCreateInstance(&.{}) orelse {
            std.debug.print("Failed to create wgpu instance\n", .{});
            return Error.FailedToCreateInstance;
        };
        defer wgpu.wgpuInstanceRelease(instance);

        // Create surface
        std.debug.print("Creating surface\n", .{});
        const surface = try glfwGetWGPUSurface(instance, window);
        errdefer wgpu.wgpuSurfaceRelease(surface);

        // Get adapter
        std.debug.print("Get adapter\n", .{});
        const adapter = try requestAdapterSync(instance, &.{
            .nextInChain = null,
            .compatibleSurface = surface,
        }) orelse return Error.FailedToGetAdapter;
        defer wgpu.wgpuAdapterRelease(adapter);

        // Get device
        std.debug.print("Get device\n", .{});
        const deviceCallback = struct {
            pub fn onDeviceLost(reason: wgpu.WGPUDeviceLostReason, message: [*c]const u8, _: ?*anyopaque) callconv(.C) void {
                std.debug.print("Device lost: reason {} message: {s}\n", .{ reason, message });
            }
        };

        const device = requestDeviceSync(adapter, &.{
            .nextInChain = null,
            .label = "My Device",
            .requiredFeatureCount = 0,
            .requiredLimits = null,
            .defaultQueue = .{
                .nextInChain = null,
                .label = "The default queue",
            },
            .deviceLostCallback = deviceCallback.onDeviceLost,
        }) orelse return Error.FailedToGetDevice;

        // Get queue
        std.debug.print("Get queue\n", .{});
        const queue = wgpu.wgpuDeviceGetQueue(device) orelse return Error.FailedToGetQueue;

        // Configure surface
        std.debug.print("Configure surface\n", .{});

        var capabilites: wgpu.WGPUSurfaceCapabilities = .{};
        _ = wgpu.wgpuSurfaceGetCapabilities(surface, adapter, &capabilites); // returns false on failure
        const preferredFormat: wgpu.WGPUTextureFormat = capabilites.formats[0];

        wgpu.wgpuSurfaceConfigure(surface, &.{
            .nextInChain = null,
            .width = 640,
            .height = 480,
            .usage = wgpu.WGPUTextureUsage_RenderAttachment,
            .format = preferredFormat,
            .viewFormatCount = 0,
            .viewFormats = null,
            .device = device,
            .presentMode = wgpu.WGPUPresentMode_Fifo,
            .alphaMode = wgpu.WGPUCompositeAlphaMode_Auto,
        });

        glfw3.glfwShowWindow(window);

        const pipeline = initializePipeline(device, preferredFormat);

        return Self{
            .window = window,
            .device = device,
            .queue = queue,
            .surface = surface,
            .surfaceFormat = preferredFormat,
            .pipeline = pipeline,
        };
    }

    pub fn run(self: *Self) void {
        glfw3.glfwPollEvents();
        defer _ = wgpu.wgpuDevicePoll(self.device, 0, null);

        // setup target view
        const targetView = self.getNextSurfaceTextureView() catch return;
        defer wgpu.wgpuTextureViewRelease(targetView);

        // setup encoder
        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, &.{
            .nextInChain = null,
            .label = "my command encoder",
        });
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        // setup renderpass
        const renderPass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .nextInChain = null,
            .colorAttachmentCount = 1,
            .colorAttachments = &[_]wgpu.WGPURenderPassColorAttachment{.{
                .view = targetView,
                .resolveTarget = null,
                .loadOp = wgpu.WGPULoadOp_Clear,
                .storeOp = wgpu.WGPUStoreOp_Store,
                .clearValue = wgpu.WGPUColor{ .r = 0.9, .g = 0.1, .b = 0.2, .a = 1.0 },
            }},
            .depthStencilAttachment = null,
            .timestampWrites = null,
        });

        wgpu.wgpuRenderPassEncoderSetPipeline(renderPass, self.pipeline);

        wgpu.wgpuRenderPassEncoderDraw(renderPass, 3, 1, 0, 0);

        wgpu.wgpuRenderPassEncoderEnd(renderPass);
        wgpu.wgpuRenderPassEncoderRelease(renderPass);

        const command = wgpu.wgpuCommandEncoderFinish(encoder, &.{
            .nextInChain = null,
            .label = "command buffer",
        });
        defer wgpu.wgpuCommandBufferRelease(command);

        wgpu.wgpuQueueSubmit(self.queue, 1, &command);

        wgpu.wgpuSurfacePresent(self.surface);
    }

    fn getNextSurfaceTextureView(self: *Self) !wgpu.WGPUTextureView {
        var surfaceTexture: wgpu.WGPUSurfaceTexture = .{};

        wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &surfaceTexture);

        if (surfaceTexture.status != wgpu.WGPUSurfaceGetCurrentTextureStatus_Success) {
            std.debug.print("Failed to get current texture: {}\n", .{surfaceTexture.status});
            return Error.FailedToGetCurrentTexture;
        }

        return wgpu.wgpuTextureCreateView(surfaceTexture.texture, &.{
            .nextInChain = null,
            .label = "Surface texture view",
            .format = wgpu.wgpuTextureGetFormat(surfaceTexture.texture),
            .dimension = wgpu.WGPUTextureViewDimension_2D,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .baseArrayLayer = 0,
            .arrayLayerCount = 1,
            .aspect = wgpu.WGPUTextureAspect_All,
        });
    }

    fn initializePipeline(device: wgpu.WGPUDevice, surfaceFormat: wgpu.WGPUTextureFormat) wgpu.WGPURenderPipeline {
        // create shader module
        const shaderSource: [*c]const u8 = @ptrCast(@embedFile("shader"));

        const shaderCodeDesc: wgpu.WGPUShaderModuleWGSLDescriptor = .{
            .chain = .{
                .next = null,
                .sType = wgpu.WGPUSType_ShaderModuleWGSLDescriptor,
            },
            .code = shaderSource,
        };

        const shaderModule: wgpu.WGPUShaderModule = wgpu.wgpuDeviceCreateShaderModule(device, &.{
            .hintCount = 0,
            .hints = null,
            .nextInChain = &shaderCodeDesc.chain,
        });
        defer wgpu.wgpuShaderModuleRelease(shaderModule);

        // create render pipeline
        return wgpu.wgpuDeviceCreateRenderPipeline(device, &wgpu.WGPURenderPipelineDescriptor{
            .nextInChain = null,
            .vertex = .{
                .bufferCount = 0,
                .buffers = null,
                .module = shaderModule,
                .entryPoint = "vs_main",
                .constantCount = 0,
                .constants = null,
            },
            .primitive = .{
                .topology = wgpu.WGPUPrimitiveTopology_TriangleList,
                .stripIndexFormat = wgpu.WGPUIndexFormat_Undefined,
                .frontFace = wgpu.WGPUFrontFace_CCW,
                .cullMode = wgpu.WGPUCullMode_None,
            },
            .fragment = &wgpu.WGPUFragmentState{
                .module = shaderModule,
                .entryPoint = "fs_main",
                .constantCount = 0,
                .constants = null,
                .targetCount = 1,
                .targets = &wgpu.WGPUColorTargetState{
                    .format = surfaceFormat,
                    .blend = &wgpu.WGPUBlendState{
                        .color = .{
                            .srcFactor = wgpu.WGPUBlendFactor_SrcAlpha,
                            .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                            .operation = wgpu.WGPUBlendOperation_Add,
                        },
                        .alpha = .{
                            .srcFactor = wgpu.WGPUBlendFactor_Zero,
                            .dstFactor = wgpu.WGPUBlendFactor_One,
                            .operation = wgpu.WGPUBlendOperation_Add,
                        },
                    },
                    .writeMask = wgpu.WGPUColorWriteMask_All,
                },
            },
            .depthStencil = null,
            .multisample = .{
                .count = 1,
                .mask = ~@as(u32, 0),
                .alphaToCoverageEnabled = 0,
            },
            .layout = null,
        });
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpuRenderPipelineRelease(self.pipeline);
        wgpu.wgpuSurfaceUnconfigure(self.surface);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuDeviceRelease(self.device);
        glfw3.glfwDestroyWindow(self.window);
        glfw3.glfwTerminate();
    }

    pub fn isRunning(self: *Self) bool {
        return glfw3.glfwWindowShouldClose(self.window) == glfw3.GL_FALSE;
    }
};

fn requestAdapterSync(instance: wgpu.WGPUInstance, options: *const wgpu.WGPURequestAdapterOptions) !?wgpu.WGPUAdapter {
    const UserData = struct {
        adapter: ?wgpu.WGPUAdapter = null,
        requestEnded: bool = false,
    };

    var userData: UserData = .{};

    const onAdapterRequestEnded = struct {
        fn func(status: wgpu.WGPURequestAdapterStatus, adapter: wgpu.WGPUAdapter, message: [*c]const u8, pUserData: ?*anyopaque) callconv(.C) void {
            const _userData: *UserData = @ptrCast(@alignCast(pUserData));
            if (status == wgpu.WGPURequestAdapterStatus_Success) {
                _userData.adapter = adapter;
            } else {
                std.debug.print("Could not get WebGPU adapter: {s}\n", .{message});
            }
            _userData.requestEnded = true;
        }
    }.func;

    wgpu.wgpuInstanceRequestAdapter(
        instance,
        options,
        onAdapterRequestEnded,
        @as(?*anyopaque, @ptrCast(&userData)),
    );

    while (!userData.requestEnded) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    return userData.adapter;
}

fn requestDeviceSync(adapter: wgpu.WGPUAdapter, descriptor: *const wgpu.WGPUDeviceDescriptor) ?wgpu.WGPUDevice {
    const UserData = struct {
        device: ?wgpu.WGPUDevice = null,
        requestEnded: bool = false,
    };

    var userData: UserData = .{};

    const onDeviceRequestEnded = struct {
        fn func(status: wgpu.WGPURequestDeviceStatus, device: wgpu.WGPUDevice, message: [*c]const u8, pUserData: ?*anyopaque) callconv(.C) void {
            const _userData: *UserData = @ptrCast(@alignCast(pUserData));
            if (status == wgpu.WGPURequestDeviceStatus_Success) {
                _userData.device = device;
            } else {
                std.debug.print("Could not get WebGPU device: {s}\n", .{message});
            }
            _userData.requestEnded = true;
        }
    }.func;

    wgpu.wgpuAdapterRequestDevice(
        adapter,
        descriptor,
        onDeviceRequestEnded,
        @as(?*anyopaque, @ptrCast(&userData)),
    );

    assert(userData.requestEnded);

    return userData.device;
}

// wayland only
fn glfwGetWGPUSurface(instance: wgpu.WGPUInstance, window: *glfw3.GLFWwindow) !wgpu.WGPUSurface {
    const wayland_display: *glfw3.wl_display = glfw3.glfwGetWaylandDisplay() orelse {
        return Error.FailedToGetWaylandDisplay;
    };
    const wayland_surface: *glfw3.wl_surface = glfw3.glfwGetWaylandWindow(window) orelse {
        return Error.FailedToGetWaylandWindow;
    };

    const fromWaylandSurface = wgpu.WGPUSurfaceDescriptorFromWaylandSurface{
        .chain = .{
            .next = null,
            .sType = wgpu.WGPUSType_SurfaceDescriptorFromWaylandSurface,
        },
        .display = wayland_display,
        .surface = wayland_surface,
    };

    const surfaceDescriptor = wgpu.WGPUSurfaceDescriptor{
        .nextInChain = &fromWaylandSurface.chain,
        .label = null,
    };

    return wgpu.wgpuInstanceCreateSurface(instance, &surfaceDescriptor);
}
