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

velocity: Velocity = .{},

mesh: Mesh = .{
    .points = &[_]Mesh.Point{
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
    },
    .indices = &[_]Mesh.Index{
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
    },
    .instances = &[_]Mesh.Instance{
        Mesh.makeInstance(.{ 0, 0, 0 }),
        Mesh.makeInstance(.{ 0, 2, 0 }),
        Mesh.makeInstance(.{ 0, -2, 0 }),
        Mesh.makeInstance(.{ 2, 0, 0 }),
        Mesh.makeInstance(.{ -2, 0, 0 }),
    },
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
    if (@reduce(.Add, self.velocity.toVec3() * self.velocity.toVec3()) > 0) {
        const movement_speed: Vec3 = @splat(0.1);

        self.camera.moveRelative(self.velocity.toVec3() * movement_speed);
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

const Velocity = struct {
    horizontal: enum { none, left, right } = .none,
    vertical: enum { none, forward, backward } = .none,

    pressed_w: bool = false,
    pressed_a: bool = false,
    pressed_s: bool = false,
    pressed_d: bool = false,

    pub fn update(self: *@This(), key: glfw.Key, action: glfw.Action) void {
        const is_press = action == .press;
        const is_release = action == .release;
        switch (key) {
            .a => if (is_press or is_release) {
                self.pressed_a = is_press;
                if (is_press) {
                    self.horizontal = .left;
                } else if (self.pressed_d) {
                    self.horizontal = .right;
                } else {
                    self.horizontal = .none;
                }
            },
            .d => if (is_press or is_release) {
                self.pressed_d = is_press;
                if (is_press) {
                    self.horizontal = .right;
                } else if (self.pressed_a) {
                    self.horizontal = .left;
                } else {
                    self.horizontal = .none;
                }
            },
            .w => if (is_press or is_release) {
                self.pressed_w = is_press;
                if (is_press) {
                    self.vertical = .forward;
                } else if (self.pressed_s) {
                    self.vertical = .backward;
                } else {
                    self.vertical = .none;
                }
            },
            .s => if (is_press or is_release) {
                self.pressed_s = is_press;
                if (is_press) {
                    self.vertical = .backward;
                } else if (self.pressed_w) {
                    self.vertical = .forward;
                } else {
                    self.vertical = .none;
                }
            },
            else => {},
        }
    }

    pub fn toVec3(self: @This()) Vec3 {
        return .{
            switch (self.horizontal) {
                .none => 0,
                .left => -1,
                .right => 1,
            },
            switch (self.vertical) {
                .none => 0,
                .forward => 1,
                .backward => -1,
            },
            0,
        };
    }
};

fn onKeyInput(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = scancode;
    _ = mods;

    const app = window.getUserPointer(App) orelse return;

    if (key == .escape and action == .press) {
        std.debug.print("closing...\n", .{});
        window.setShouldClose(true);
        return;
    }

    app.velocity.update(key, action);
}
