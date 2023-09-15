const std = @import("std");
const core = @import("core");
const gpu = core.gpu;

const LayoutEngine = @import("layout/LayoutEngine.zig");
const RenderEngine = @import("render/RenderEngine.zig");

const geo = @import("geo.zig");
const anim = @import("layout/anim.zig");

pub const App = @This();

gpa: std.heap.GeneralPurposeAllocator(.{}),

layout_engine: LayoutEngine,
render_engine: RenderEngine,
view_1: u32,

title_timer: core.Timer,

pub fn init(app: *App) !void {
    try core.init(.{});

    app.gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = app.gpa.allocator();
    const render_engine = RenderEngine.init(alloc);
    var layout_engine = try LayoutEngine.init(alloc);

    const view_1 = try layout_engine.appendChild(0, .{
        .kind = .view,
        .dirt = .{},

        .outer_box_x = anim.Value{ .immediate = 100.0 },
        .outer_box_y = anim.Value{ .immediate = 100.0 },
        .outer_box_width = anim.Value.zero,
        .outer_box_height = anim.Value.zero,
    });

    try layout_engine.getAttr(view_1, .outer_box_width).setSpring(.{
        .target_value = 300.0,
        .mass = 1.0,
        .stiffness = 800.0,
        .damping = 20.0,
    });
    try layout_engine.getAttr(view_1, .outer_box_height).setSpring(.{
        .target_value = 200.0,
        .mass = 1.0,
        .stiffness = 800.0,
        .damping = 20.0,
    });

    const corner_radius_spring = .{
        .target_value = 50.0,
        .mass = 2.0,
        .stiffness = 200.0,
        .damping = 10.0,
    };
    try layout_engine.getAttr(view_1, .corner_radius_top_left_x)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_top_left_y)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_top_right_x)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_top_right_y)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_top_left_x)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_top_left_y)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_bottom_left_x)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_bottom_left_y)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_bottom_right_x)
        .setSpring(corner_radius_spring);
    try layout_engine.getAttr(view_1, .corner_radius_bottom_right_y)
        .setSpring(corner_radius_spring);

    app.* = .{
        .gpa = app.gpa,
        .layout_engine = layout_engine,
        .render_engine = render_engine,
        .view_1 = view_1,

        .title_timer = try core.Timer.start(),
    };
}

pub fn deinit(app: *App) void {
    const alloc = app.gpa.allocator();
    _ = alloc;

    defer core.deinit();
    defer {
        if (app.gpa.deinit() == .leak)
            std.log.warn("Leaked memory\n", .{});
    }
    defer app.render_engine.deinit();
    defer {
        app.layout_engine.deinit() catch unreachable;
    }
}

pub fn update(app: *App) !bool {
    const alloc = app.gpa.allocator();
    _ = alloc;

    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => return true,
            .mouse_press => |ev| {
                _ = ev;

                const spring = .{
                    .initial_velocity = 2 * 1000.0,
                    .mass = 1.0,
                    .stiffness = 800.0,
                    .damping = 20.0,
                };
                var spring_inv = .{
                    .initial_velocity = -1000.0,
                    .mass = 1.0,
                    .stiffness = 800.0,
                    .damping = 20.0,
                };

                try app.layout_engine.getAttr(app.view_1, .outer_box_x)
                    .setSpring(spring_inv);
                try app.layout_engine.getAttr(app.view_1, .outer_box_y)
                    .setSpring(spring_inv);
                try app.layout_engine.getAttr(app.view_1, .outer_box_width)
                    .setSpring(spring);
                try app.layout_engine.getAttr(app.view_1, .outer_box_height)
                    .setSpring(spring);
            },
            .mouse_motion => |ev| {
                // ev.pos;
                const target_x = @as(f32, @floatCast(ev.pos.x * 2));
                const target_y = @as(f32, @floatCast(ev.pos.y * 2));

                try app.layout_engine.getAttr(app.view_1, .outer_box_x)
                    .setSpring(.{
                    .target_value = target_x,
                    .mass = 1.0,
                    .stiffness = 800.0,
                    .damping = 20.0,
                });
                try app.layout_engine.getAttr(app.view_1, .outer_box_y)
                    .setSpring(.{
                    .target_value = target_y,
                    .mass = 1.0,
                    .stiffness = 800.0,
                    .damping = 20.0,
                });
                // try app.layout_engine.getAttr(app.view_1, .corner_radius_bottom_right_x)
                //     .setSpring(.{
                //     .target_value = 100.0 * (@sin(target_x / 200.0) + 1),
                //     .mass = 1.0,
                //     .stiffness = 100.0,
                //     .damping = 10.0,
                // });
                // try app.layout_engine.getAttr(app.view_1, .corner_radius_bottom_right_y)
                //     .setSpring(.{
                //     .target_value = 100.0 * (@sin(target_x / 200.0) + 1),
                //     .mass = 1.0,
                //     .stiffness = 100.0,
                //     .damping = 10.0,
                // });
            },
            else => {
                // push event to layout engine?
                // maybe separate interaction engine?
            },
        }
    }

    const back_buffer = core.swap_chain.getCurrentTexture().?;

    try app.layout_engine.renderFrame(&app.render_engine);
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
