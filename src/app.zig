const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");

const wgpu = @cImport({
    @cInclude("wgpu.h");
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
    device: wgpu.WGPUDevice,
    queue: wgpu.WGPUQueue,
    surface: wgpu.WGPUSurface,
    surfaceFormat: wgpu.WGPUTextureFormat,
    pipeline: wgpu.WGPURenderPipeline,
    indexCount: u32 = mesh.indices.len * @typeInfo(mesh.Index).array.len,
    indexBuffer: wgpu.WGPUBuffer,
    pointBuffer: wgpu.WGPUBuffer,

    pub fn init() !Self {
        glfw.setErrorCallback(errorCallback);
        // Open window
        if (!glfw.init(.{})) {
            std.debug.print("Failed to initialize GLFW\n", .{});
        }
        errdefer glfw.terminate();

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

        std.debug.print("{}\n", .{window.getAttrib(.resizable)});

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
            .requiredLimits = &getRequiredLimits(adapter),
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
            .width = size.width,
            .height = size.height,
            .usage = wgpu.WGPUTextureUsage_RenderAttachment,
            .format = preferredFormat,
            .viewFormatCount = 0,
            .viewFormats = null,
            .device = device,
            .presentMode = wgpu.WGPUPresentMode_Fifo,
            .alphaMode = wgpu.WGPUCompositeAlphaMode_Auto,
        });

        const pipeline = initializePipeline(device, preferredFormat);
        const bufTuple = initBuffer(device, queue);
        const pointBuffer = bufTuple.@"0";
        const indexBuffer = bufTuple.@"1";

        return Self{
            .window = window,
            .device = device,
            .queue = queue,
            .surface = surface,
            .surfaceFormat = preferredFormat,
            .pipeline = pipeline,
            .indexBuffer = indexBuffer,
            .pointBuffer = pointBuffer,
        };
    }

    pub fn run(self: *Self) void {
        glfw.pollEvents();
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
                .clearValue = wgpu.WGPUColor{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
            }},
            .depthStencilAttachment = null,
            .timestampWrites = null,
        });

        wgpu.wgpuRenderPassEncoderSetPipeline(renderPass, self.pipeline);

        wgpu.wgpuRenderPassEncoderSetVertexBuffer(renderPass, 0, self.pointBuffer, 0, wgpu.wgpuBufferGetSize(self.pointBuffer));
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(renderPass, self.indexBuffer, wgpu.WGPUIndexFormat_Uint16, 0, wgpu.wgpuBufferGetSize(self.indexBuffer));

        wgpu.wgpuRenderPassEncoderDrawIndexed(renderPass, self.indexCount, 1, 0, 0, 0);

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
                .bufferCount = 1,
                .buffers = &[_]wgpu.WGPUVertexBufferLayout{
                    .{
                        .attributeCount = 2,
                        .attributes = &[_]wgpu.WGPUVertexAttribute{ .{
                            .shaderLocation = 0,
                            .format = wgpu.WGPUVertexFormat_Float32x2,
                            .offset = 0,
                        }, .{
                            .shaderLocation = 1,
                            .format = wgpu.WGPUVertexFormat_Float32x3,
                            .offset = 2 * @sizeOf(f32),
                        } },
                        .arrayStride = 5 * @sizeOf(f32),
                        .stepMode = wgpu.WGPUVertexStepMode_Vertex,
                    },
                },
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

    fn initBuffer(device: wgpu.WGPUDevice, queue: wgpu.WGPUQueue) struct { wgpu.WGPUBuffer, wgpu.WGPUBuffer } {
        const pointBuffer: wgpu.WGPUBuffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = "point buffer",
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
            .size = mesh.points.len * @sizeOf(mesh.Point),
            .mappedAtCreation = 0, //false
        });
        wgpu.wgpuQueueWriteBuffer(queue, pointBuffer, 0, &mesh.points, mesh.points.len * @sizeOf(mesh.Point));

        const indexBuffer: wgpu.WGPUBuffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = "index buffer",
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
            .size = mesh.indices.len * @sizeOf(mesh.Index),
            .mappedAtCreation = 0, //false
        });
        wgpu.wgpuQueueWriteBuffer(queue, indexBuffer, 0, &mesh.indices, mesh.indices.len * @sizeOf(mesh.Index));

        //std.debug.print("{}, {}\n", .{ mesh.indices.len * @sizeOf(mesh.Index), (mesh.indices.len * @sizeOf(mesh.Index) + 3) & ~@as(usize, 3) });

        return .{ pointBuffer, indexBuffer };
    }

    fn getRequiredLimits(adapter: wgpu.WGPUAdapter) wgpu.WGPURequiredLimits {
        var supportedLimits: wgpu.WGPUSupportedLimits = .{
            .nextInChain = null,
        };
        _ = wgpu.wgpuAdapterGetLimits(adapter, &supportedLimits);

        var requiredLimits: wgpu.WGPURequiredLimits = .{};
        setDefault(&requiredLimits.limits);

        requiredLimits.limits.maxVertexAttributes = 2;
        requiredLimits.limits.maxVertexBuffers = 1;
        requiredLimits.limits.maxBufferSize = @typeInfo(mesh.Index).array.len * mesh.indices.len * @sizeOf(mesh.Point);
        requiredLimits.limits.maxVertexBufferArrayStride = @sizeOf(mesh.Point);
        requiredLimits.limits.maxInterStageShaderComponents = 3;

        requiredLimits.limits.minUniformBufferOffsetAlignment = supportedLimits.limits.minUniformBufferOffsetAlignment;
        requiredLimits.limits.minStorageBufferOffsetAlignment = supportedLimits.limits.minStorageBufferOffsetAlignment;

        return requiredLimits;
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpuBufferRelease(self.indexBuffer);
        wgpu.wgpuBufferRelease(self.pointBuffer);
        wgpu.wgpuRenderPipelineRelease(self.pipeline);
        wgpu.wgpuSurfaceUnconfigure(self.surface);
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuSurfaceRelease(self.surface);
        wgpu.wgpuDeviceRelease(self.device);
        glfw.Window.destroy(self.window);
        glfw.terminate();
    }

    pub fn isRunning(self: *Self) bool {
        return !glfw.Window.shouldClose(self.window);
    }
};

fn setDefault(limits: *wgpu.WGPULimits) void {
    limits.maxTextureDimension1D = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxTextureDimension2D = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxTextureDimension3D = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxTextureArrayLayers = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxBindGroups = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxBindGroupsPlusVertexBuffers = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxBindingsPerBindGroup = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxDynamicUniformBuffersPerPipelineLayout = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxDynamicStorageBuffersPerPipelineLayout = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxSampledTexturesPerShaderStage = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxSamplersPerShaderStage = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxStorageBuffersPerShaderStage = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxStorageTexturesPerShaderStage = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxUniformBuffersPerShaderStage = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxUniformBufferBindingSize = wgpu.WGPU_LIMIT_U64_UNDEFINED;
    limits.maxStorageBufferBindingSize = wgpu.WGPU_LIMIT_U64_UNDEFINED;
    limits.minUniformBufferOffsetAlignment = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.minStorageBufferOffsetAlignment = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxVertexBuffers = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxBufferSize = wgpu.WGPU_LIMIT_U64_UNDEFINED;
    limits.maxVertexAttributes = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxVertexBufferArrayStride = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxInterStageShaderComponents = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxInterStageShaderVariables = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxColorAttachments = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxColorAttachmentBytesPerSample = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeWorkgroupStorageSize = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeInvocationsPerWorkgroup = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeWorkgroupSizeX = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeWorkgroupSizeY = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeWorkgroupSizeZ = wgpu.WGPU_LIMIT_U32_UNDEFINED;
    limits.maxComputeWorkgroupsPerDimension = wgpu.WGPU_LIMIT_U32_UNDEFINED;
}

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
fn glfwGetWGPUSurface(instance: wgpu.WGPUInstance, window: glfw.Window) !wgpu.WGPUSurface {
    const Native = glfw.Native(.{ .wayland = true });

    return wgpu.wgpuInstanceCreateSurface(instance, &wgpu.WGPUSurfaceDescriptor{
        .nextInChain = &(wgpu.WGPUSurfaceDescriptorFromWaylandSurface{
            .chain = .{
                .next = null,
                .sType = wgpu.WGPUSType_SurfaceDescriptorFromWaylandSurface,
            },
            .display = Native.getWaylandDisplay(),
            .surface = Native.getWaylandWindow(window),
        }).chain,
        .label = null,
    });
}
