const std = @import("std");

const App = @import("App.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    while (app.isRunning()) {
        app.run();
    }
}
