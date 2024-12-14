const std = @import("std");

const App = @import("app.zig").App;

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();

    while (app.isRunning()) {
        app.run();
    }
}
