const std = @import("std");
const assert = std.debug.assert;

const glfw = @import("zglfw");
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
window: *glfw.Window,
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
    defer mesh.deinit();

    // init glfw
    glfw.init() catch return Error.FailedToInitializeGLFW;
    errdefer glfw.terminate();

    // open window
    glfw.windowHint(glfw.Resizable, @intFromBool(false));
    glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
    app.window = glfw.createWindow(@intCast(app.width), @intCast(app.height), "VOXEL", null, null) catch return Error.FailedToOpenWindow;
    errdefer glfw.destroyWindow(app.window);

    // close callback
    _ = glfw.setWindowCloseCallback(app.window, onClose);

    // setup graphics
    app.graphics = try Graphics.init(mesh, app.window);

    // setup resizing
    glfw.setWindowUserPointer(app.window, app);
    _ = glfw.setFramebufferSizeCallback(app.window, onWindowResize);

    var width: c_int = undefined;
    var height: c_int = undefined;
    glfw.getFramebufferSize(app.window, &width, &height);
    onWindowResize(app.window, width, height);

    // setup renderer
    app.renderer = try Renderer.init(allocator, mesh, app.graphics, app.width, app.height);

    // input
    _ = glfw.setKeyCallback(app.window, onKeyInput);
    _ = glfw.setCursorPosCallback(app.window, onMouseInput);
    glfw.setInputMode(app.window, glfw.Cursor, glfw.CursorDisabled);
    var xpos: f64 = undefined;
    var ypos: f64 = undefined;
    glfw.getCursorPos(app.window, &xpos, &ypos);
    app.input.mouse_position = .{ xpos, ypos };

    return app;
}

pub fn deinit(self: *App) void {
    if (self.renderer) |renderer| renderer.deinit();
    self.graphics.deinit();
    self.chunk_manager.deinit();
    glfw.destroyWindow(self.window);
    glfw.terminate();
}

pub fn run(self: *App) !void {
    glfw.pollEvents();

    const time: f32 = @floatCast(glfw.getTime());

    try self.update();

    try self.renderer.?.render(self.graphics, time, self.camera);

    _ = self.graphics.surface.present();

    _ = self.graphics.device.poll(true, null);
}

fn update(self: *App) !void {
    const movement = self.input.toVec3();
    if (@reduce(.Add, movement * movement) > 0) {
        self.camera.moveRelative(movement * @as(@TypeOf(movement), @splat(MOVEMENT_SPEED)));

        if (try self.chunk_manager.update(self.camera.position)) |mesh| {
            defer mesh.deinit();

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
    return !glfw.windowShouldClose(self.window);
}

fn onClose(window: *glfw.Window) callconv(.c) void {
    _ = window;
}

fn onWindowResize(window: *glfw.Window, width: c_int, height: c_int) callconv(.c) void {
    const app_ptr = glfw.getWindowUserPointer(window);
    if (app_ptr == null) return;
    const app: *App = @as(*App, @ptrCast(@alignCast(app_ptr.?)));

    app.width = @intCast(width);
    app.height = @intCast(height);

    std.debug.print("resized {}, {}\n", .{ width, height });

    app.graphics.surface.configure(&.{
        .device = app.graphics.device,
        .format = app.graphics.surface_format,
        .width = @intCast(width),
        .height = @intCast(height),
    });

    app.camera.aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

    if (app.renderer) |*renderer| renderer.updateScale(app.graphics, @intCast(width), @intCast(height)) catch {};
}

fn onKeyInput(window: *glfw.Window, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    _ = mods;

    if (key == glfw.KeyEscape and action == glfw.Press) {
        std.debug.print("closing...\n", .{});
        glfw.setWindowShouldClose(window, true);
        return;
    }

    const app_ptr = glfw.getWindowUserPointer(window);
    if (app_ptr == null) return;

    const app: *App = @ptrCast(@alignCast(app_ptr));

    app.input.updateKey(key, action);
}

fn onMouseInput(window: *glfw.Window, position_x: f64, position_y: f64) callconv(.c) void {
    const app_ptr = glfw.getWindowUserPointer(window);
    if (app_ptr == null) return;
    const app: *App = @as(*App, @ptrCast(@alignCast(app_ptr.?)));
    app.input.updateMouse(position_x, position_y);
}
