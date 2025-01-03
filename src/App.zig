const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("mach-glfw");
const gpu = @import("wgpu");

const Graphics = @import("Graphics.zig");
const Renderer = @import("Renderer.zig");
const Camera = @import("Camera.zig");
const Mesh = @import("Mesh.zig");
const math = @import("math.zig");
const Vec3f = math.Vec3(f32);
const Vec3i = math.Vec3(i32);
const Chunk = @import("Chunk.zig");
const Input = @import("Input.zig");
const ChunkManager = @import("ChunkManager.zig");

const Error = error{
    FailedToInitializeGLFW,
    FailedToOpenWindow,
};

const App = @This();

const MOVEMENT_SPEED: f32 = 0.2;
const MOUSE_SENSITIVITY: f32 = 0.07;

allocator: std.mem.Allocator,
window: glfw.Window,
graphics: Graphics,
renderer: ?Renderer,

width: u32,
height: u32,

camera: Camera = .{},
input: Input = .{},

chunk_manager: ChunkManager,

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
        .chunk_manager = ChunkManager.init(allocator),
    };

    app.camera.lookAt(.{ 0, 0, 0 });

    const mesh = try app.chunk_manager.update(app.camera.position) orelse try app.chunk_manager.getMergedMesh();
    //defer mesh.deinit();

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
    app.graphics = try Graphics.init(mesh, app.window);

    // setup resizing
    app.window.setUserPointer(app);
    app.window.setFramebufferSizeCallback(onWindowResize);

    const size = app.window.getFramebufferSize();
    onWindowResize(app.window, size.width, size.height);

    // setup renderer
    app.renderer = try Renderer.init(allocator, mesh, app.graphics, app.width, app.height);

    // input
    app.window.setKeyCallback(onKeyInput);
    app.window.setCursorPosCallback(onMouseInput);
    app.window.setInputMode(.cursor, .disabled);
    const cursor_position = app.window.getCursorPos();
    app.input.mouse_position = .{ cursor_position.xpos, cursor_position.ypos };

    return app;
}

pub fn deinit(self: *App) void {
    self.renderer.?.deinit();
    self.graphics.deinit();
    self.window.destroy();
    glfw.terminate();
    self.allocator.destroy(self);
}

pub fn run(self: *App) !void {
    glfw.pollEvents();

    const time: f32 = @floatCast(glfw.getTime());

    try self.update();

    try self.renderer.?.render(self.graphics, time, self.camera);

    self.graphics.surface.present();

    _ = self.graphics.device.poll(true, null);
}

fn update(self: *App) !void {
    const movement = self.input.toVec3();
    if (@reduce(.Add, movement * movement) > 0) {
        self.camera.moveRelative(movement * @as(@TypeOf(movement), @splat(MOVEMENT_SPEED)));

        if (try self.chunk_manager.update(self.camera.position)) |mesh| {
            //defer mesh.deinit();

            if (self.renderer) |*renderer| {
                try renderer.shader.set(self.allocator, mesh.points);
                try renderer.shader.set(self.allocator, mesh.indirects);
                try renderer.shader.set(self.allocator, mesh.chunks);
            }
        }
    }

    const rotation = self.input.mouse_delta;
    if (@reduce(.Add, rotation * rotation) > 0) {
        self.camera.rotate(rotation * @as(@TypeOf(rotation), @splat(MOUSE_SENSITIVITY)));
        self.input.mouse_delta = @splat(0);
    }
}
pub fn isRunning(self: *App) bool {
    return !glfw.Window.shouldClose(self.window);
}

fn onClose(window: glfw.Window) void {
    _ = window;
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

    if (app.renderer) |*renderer| renderer.updateScale(app.graphics, width, height) catch {};
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

    app.input.updateKey(key, action);
}

fn onMouseInput(window: glfw.Window, position_x: f64, position_y: f64) void {
    const app = window.getUserPointer(App) orelse return;
    app.input.updateMouse(position_x, position_y);
}
