const std = @import("std");
const core = @import("core");
const gpu = core.gpu;

const LayoutEngine = @import("layout/LayoutEngine.zig");
const RenderEngine = @import("render/RenderEngine.zig");
const SpringEngine = @import("layout/SpringEngine.zig");

const geo = @import("render/geo.zig");

pub const App = @This();

gpa: std.heap.GeneralPurposeAllocator(.{}),

layout_engine: LayoutEngine,
render_engine: RenderEngine,
spring_engine: SpringEngine,
spring_x: SpringEngine.SpringIdx,
spring_y: SpringEngine.SpringIdx,

title_timer: core.Timer,

pub fn init(app: *App) !void {
    try core.init(.{});

    app.gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = app.gpa.allocator();
    const render_engine = RenderEngine.init(alloc);
    const layout_engine = try LayoutEngine.init(alloc);

    var spring_engine = try SpringEngine.init(alloc);
    const spring_cfg = .{
        .initial_value = 0.0,
        .mass = 1.0,
        .stiffness = 500.0,
        .damping = 10.0,
    };
    const spring_x = try spring_engine.newSpring(alloc, spring_cfg);
    const spring_y = try spring_engine.newSpring(alloc, spring_cfg);

    app.* = .{
        .gpa = app.gpa,
        .layout_engine = layout_engine,
        .render_engine = render_engine,
        .spring_engine = spring_engine,
        .spring_x = spring_x,
        .spring_y = spring_y,

        .title_timer = try core.Timer.start(),
    };
}

pub fn deinit(app: *App) void {
    const alloc = app.gpa.allocator();

    defer core.deinit();
    defer {
        if (app.gpa.deinit() == .leak)
            std.log.warn("Leaked memory\n", .{});
    }
    defer app.render_engine.deinit();
    defer {
        app.layout_engine.deinit(alloc) catch unreachable;
    }
    defer app.spring_engine.deinit(alloc);
}

pub fn update(app: *App) !bool {
    app.spring_engine.updatePositions();

    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => return true,
            .mouse_motion => |ev| {
                // ev.pos;
                const target_x = @as(f32, @floatCast(ev.pos.x * 2));
                const target_y = @as(f32, @floatCast(ev.pos.y * 2));
                app.spring_engine.stretchSpring(app.spring_x, target_x);
                app.spring_engine.stretchSpring(app.spring_y, target_y);
            },
            else => {
                // push event to layout engine?
                // maybe separate interaction engine?
            },
        }
    }

    const back_buffer = core.swap_chain.getCurrentTexture().?;

    // TODO: app.layout_engine.writeFrame(objectWriter)
    // app.layout_engine.renderFrame(&app.render_engine);

    const spring_x_pos = app.spring_engine.getPosition(app.spring_x);
    const spring_y_pos = app.spring_engine.getPosition(app.spring_y);
    try app.render_engine.writeRect(.{
        .origin = .{ spring_x_pos, spring_y_pos },
        .size = .{ 100, 100 },
        .color = .{
            1, 1, 1, 0.7,
        },
        .radius = geo.Rect.uniformRadius(17.0),
    });
    try app.render_engine.writeRect(.{
        .origin = .{ 400, 400 },
        .size = .{ 300, 600 },
        .color = .{
            0, 0.2, 0.5, 0.7,
        },
        .radius = geo.Rect.uniformRadius(17.0),
    });

    app.render_engine.flushScene(back_buffer);

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
