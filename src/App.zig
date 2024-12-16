const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const Renderer = @import("Renderer.zig");
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");

const Error = error{
    FailedToInitializeGLFW,
    FailedToOpenWindow,
};

const App = @This();

allocator: std.mem.Allocator,
window: glfw.Window,
graphics: Graphics,
renderer: ?Renderer,

width: u32,
height: u32,
camera: Camera,

mesh: Mesh = .{
    .points = ([_]Mesh.Point{
        // front
        .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } }, // 0
        .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } }, // 1
        .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } }, // 2
        .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0 } }, // 3

        // back
        .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // 4
        .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // 5
        .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // 6
        .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // 7
    })[0..],
    .indices = ([_]Mesh.Index{
        // front
        .{ 0, 1, 2 }, .{ 0, 2, 3 },
        // back
        .{ 5, 4, 7 }, .{ 5, 7, 6 },
        // top
        .{ 3, 2, 6 }, .{ 3, 6, 7 },
        // bottom
        .{ 4, 5, 1 }, .{ 4, 1, 0 },
        // right
        .{ 1, 5, 6 }, .{ 1, 6, 2 },
        // left
        .{ 4, 0, 3 }, .{ 4, 3, 7 },
    })[0..],
    .uniform = .{},
},

pub fn init(allocator: std.mem.Allocator) !*App {
    var app = try allocator.create(App);
    errdefer allocator.destroy(app);

    app.* = .{
        .allocator = allocator,
        .window = undefined,
        .graphics = undefined,
        .renderer = null,
        .width = 640,
        .height = 480,
        .camera = Camera{},
    };

    // init glfw
    _ = glfw.init(.{}) or return Error.FailedToInitializeGLFW;
    errdefer glfw.terminate();

    // open window
    app.window = glfw.Window.create(app.width, app.height, "VOXEL", null, null, .{
        .resizable = false,
        .client_api = .no_api,
    }) orelse return Error.FailedToOpenWindow;
    errdefer app.window.destroy();

    // setup graphics
    app.graphics = try Graphics.init(app.mesh, app.window);

    // setup resizing
    app.window.setUserPointer(app);
    app.window.setFramebufferSizeCallback(onWindowResize);

    const size = app.window.getFramebufferSize();
    onWindowResize(app.window, size.width, size.height);

    // setup renderer
    app.renderer = Renderer.init(app.mesh, app.graphics, app.width, app.height);

    return app;
}

pub fn deinit(self: *App) void {
    self.renderer.?.deinit();
    self.graphics.deinit();
    self.window.destroy();
    glfw.terminate();
    self.allocator.destroy(self);
}

pub fn run(self: *App) void {
    glfw.pollEvents();

    const time: f32 = @floatCast(glfw.getTime());

    try self.renderer.?.renderFrame(self.graphics, &self.mesh, time, self.camera);

    self.graphics.surface.present();

    _ = self.graphics.device.poll(true, null);
}

pub fn isRunning(self: *App) bool {
    return !glfw.Window.shouldClose(self.window);
}

fn onWindowResize(window: glfw.Window, width: u32, height: u32) void {
    const app: *App = window.getUserPointer(App) orelse return;

    app.width = width;
    app.height = height;

    std.debug.print("resized {}, {}\n", .{ width, height });

    app.graphics.surface.configure(&.{
        .device = app.graphics.device,
        .format = app.graphics.surface_format,
        .width = width,
        .height = height,
    });

    if (app.renderer) |*renderer| renderer.updateScale(app.graphics.queue, width, height);
}
