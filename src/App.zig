const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const Renderer = @import("Renderer.zig");
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Chunk = @import("Chunk.zig");
const Input = @import("Input.zig");

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

camera: Camera = .{},
input: Input = .{},

mesh: Mesh,

pub fn init(allocator: std.mem.Allocator) !*App {
    var app = try allocator.create(App);
    errdefer allocator.destroy(app);

    var chunk = Chunk.init();
    const chunk_mesh = try chunk.generateMesh(.{ 0, 0, 0 }, allocator);

    app.* = .{
        .allocator = allocator,
        .window = undefined,
        .graphics = undefined,
        .renderer = null,
        .width = 640,
        .height = 480,
        .mesh = chunk_mesh,
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

    // close callback
    app.window.setCloseCallback(onClose);

    // setup graphics
    app.graphics = try Graphics.init(app.mesh, app.window);

    // setup resizing
    app.window.setUserPointer(app);
    app.window.setFramebufferSizeCallback(onWindowResize);

    const size = app.window.getFramebufferSize();
    onWindowResize(app.window, size.width, size.height);

    // setup renderer
    app.renderer = try Renderer.init(app.mesh, app.graphics, app.width, app.height);

    // input
    app.window.setKeyCallback(onKeyInput);
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

    self.update();

    try self.renderer.?.renderFrame(self.graphics, &self.mesh, time, self.camera);

    self.graphics.surface.present();

    _ = self.graphics.device.poll(true, null);
}

fn update(self: *App) void {
    if (@reduce(.Add, self.input.toVec3() * self.input.toVec3()) > 0) {
        const movement_speed: Vec3 = @splat(0.1);

        self.camera.moveRelative(self.input.toVec3() * movement_speed);
    }
}

pub fn isRunning(self: *App) bool {
    return !glfw.Window.shouldClose(self.window);
}

fn onClose(window: glfw.Window) void {
    const app = window.getUserPointer(App) orelse return;

    app.deinit();
}

fn onWindowResize(window: glfw.Window, width: u32, height: u32) void {
    const app = window.getUserPointer(App) orelse return;

    app.width = width;
    app.height = height;

    std.debug.print("resized {}, {}\n", .{ width, height });

    app.graphics.surface.configure(&.{
        .device = app.graphics.device,
        .format = app.graphics.surface_format,
        .width = width,
        .height = height,
    });

    app.camera.aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    if (app.renderer) |*renderer| renderer.updateScale(app.graphics.queue, width, height);
}

fn onKeyInput(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = scancode;
    _ = mods;

    const app = window.getUserPointer(App) orelse return;

    if (key == .escape and action == .press) {
        std.debug.print("closing...\n", .{});
        window.setShouldClose(true);
        return;
    }

    app.input.update(key, action);
}
