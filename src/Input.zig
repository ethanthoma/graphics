const glfw = @import("mach-glfw");

const math = @import("math.zig");
const Vec3 = math.Vec3;

const Input = @This();

horizontal: enum { none, left, right } = .none,
vertical: enum { none, up, down } = .none,
forward: enum { none, forward, backward } = .none,

pressed_w: bool = false,
pressed_a: bool = false,
pressed_s: bool = false,
pressed_d: bool = false,
pressed_space: bool = false,
pressed_shift: bool = false,

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
                self.forward = .forward;
            } else if (self.pressed_s) {
                self.forward = .backward;
            } else {
                self.forward = .none;
            }
        },
        .s => if (is_press or is_release) {
            self.pressed_s = is_press;
            if (is_press) {
                self.forward = .backward;
            } else if (self.pressed_w) {
                self.forward = .forward;
            } else {
                self.forward = .none;
            }
        },
        .space => if (is_press or is_release) {
            self.pressed_space = is_press;
            if (is_press) {
                self.vertical = .up;
            } else if (self.pressed_shift) {
                self.vertical = .down;
            } else {
                self.vertical = .none;
            }
        },
        .left_shift => if (is_press or is_release) {
            self.pressed_shift = is_press;
            if (is_press) {
                self.vertical = .down;
            } else if (self.pressed_space) {
                self.vertical = .up;
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
            .up => 1,
            .down => -1,
        },
        switch (self.forward) {
            .none => 0,
            .forward => 1,
            .backward => -1,
        },
    };
}
