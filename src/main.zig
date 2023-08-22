const std = @import("std");
const core = @import("core");
const gpu = core.gpu;

const RectPass = @import("render/RectPass.zig");
const geo = @import("render/geo.zig");

pub const App = @This();

rect_pass: RectPass,
title_timer: core.Timer,

pub fn init(app: *App) !void {
    try core.init(.{});

    const rect_pass = RectPass.init();

    app.* = .{
        .rect_pass = rect_pass,
        .title_timer = try core.Timer.start(),
    };
}

pub fn deinit(app: *App) void {
    defer core.deinit();
    _ = app;
}

pub fn update(app: *App) !bool {
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => return true,
            else => {},
        }
    }

    const back_buffer = core.swap_chain.getCurrentTexture().?;

    app.rect_pass.render(back_buffer, &[_]geo.Rect{
        .{
            .origin = .{ 0, 0 },
            .size = .{ 100, 100 },
            .color = .{
                246.0 / 255.0,
                71.0 / 255.0,
                64.0 / 255.0,
                1.0,
            },
        },
        .{
            .origin = .{ 400, 400 },
            .size = .{ 300, 600 },
            .color = .{
                246.0 / 255.0,
                71.0 / 255.0,
                64.0 / 255.0,
                1.0,
            },
            .radius = geo.Rect.uniform_radius(17.0),
        },
    });

    core.swap_chain.present();
    back_buffer.release();

    // update the window title every second
    if (app.title_timer.read() >= 1.0) {
        app.title_timer.reset();
        try core.printTitle("Silk [ {d}fps ] [ Input {d}hz ]", .{
            core.frameRate(),
            core.inputRate(),
        });
    }

    return false;
}
