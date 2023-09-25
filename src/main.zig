const std = @import("std");
const core = @import("mach-core");
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
    const size = .{ .width = 1920 / 2, .height = 1080 / 2 };
    try core.init(.{ .size = size });

    app.gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = app.gpa.allocator();
    const render_engine = RenderEngine.init(alloc);
    var layout_engine = try LayoutEngine.init(alloc);
    const le = &layout_engine;

    le.setRootSize(.{
        .dims = .{
            @as(f32, @floatFromInt(size.width)) * 2,
            @as(f32, @floatFromInt(size.height)) * 2,
        },
    });

    try le.getAttr(0, .padding).setValue(50);

    const view_1 = try le.appendChild(0, .{
        .kind = .view,
        .display = .flex,

        .margin_bottom = anim.Value{ .immediate = 50.0 },

        .background_color = anim.Color{
            .r = .{ .immediate = 0.7 },
            .g = .{ .immediate = 1.0 },
            .b = .{ .immediate = 0.01 },
            .a = .{ .immediate = 0.75 },
        },

        .corner_radius_top_left_x = anim.Value{ .immediate = 50.0 },
        .corner_radius_top_left_y = anim.Value{ .immediate = 50.0 },
    });

    try le.getAttr(view_1, .corner_radius_bottom_left_x).setSpring(.{});
    try le.getAttr(view_1, .corner_radius_bottom_left_y).setSpring(.{});
    try le.getAttr(view_1, .corner_radius).setValue(17);

    const view_2 = try le.appendChild(0, .{
        .kind = .view,
        .display = .flex,
        .flex_direction = .column,

        .background_color = anim.Color{
            .r = .{ .immediate = 0.4 },
            .g = .{ .immediate = 0.4 },
            .b = .{ .immediate = 0.4 },
            .a = .{ .immediate = 1 },
        },
    });
    try le.getAttr(view_2, .corner_radius).setValue(17);

    const view_2_a = try le.appendChild(view_2, .{
        .kind = .view,
        .display = .flex,
        .flex_basis = anim.Value{ .immediate = 400.0 },
        .flex_shrink = anim.Value{ .immediate = 0.0 },
        // .flex_grow = anim.Value{ .immediate = 0.0 },

        .background_color = anim.Color{
            .r = .{ .immediate = 0.9 },
            .g = .{ .immediate = 0.9 },
            .b = .{ .immediate = 0.9 },
            .a = .{ .immediate = 1 },
        },
    });
    try le.getAttr(view_2_a, .margin).setValue(5);
    try le.getAttr(view_2_a, .corner_radius).setValue(17 - 5);

    const view_2_b = try le.appendChild(view_2, .{
        .kind = .view,
        .display = .flex,
        .flex_basis = anim.Value{ .immediate = 400.0 },
        .flex_shrink = anim.Value{ .immediate = 1.0 },
        .flex_grow = anim.Value{ .immediate = 0.0 },

        .margin_left = anim.Value{ .immediate = 50.0 },

        .background_color = anim.Color{
            .r = .{ .immediate = 0.01 },
            .g = .{ .immediate = 1.0 },
            .b = .{ .immediate = 0.7 },
            .a = .{ .immediate = 0.75 },
        },
    });
    try le.getAttr(view_2_b, .corner_radius).setValue(17);

    // const tight_spring = .{
    //     .mass = 1.0,
    //     .stiffness = 800.0,
    //     .damping = 20.0,
    // };
    // const corner_radius_spring = .{
    //     .target_value = 50.0,
    //     .mass = 2.0,
    //     .stiffness = 200.0,
    //     .damping = 10.0,
    // };

    // try le.getAttr(view_1, .outer_box_width).setSpring(tight_spring);
    // try le.getAttr(view_1, .outer_box_height).setSpring(tight_spring);

    // try le.getAttr(view_1, .outer_box_width).setSpring(.{
    //     .target_value = 200,
    // });
    // try le.getAttr(view_1, .outer_box_height).setSpring(.{
    //     .target_value = 200,
    // });

    // try le.getAttr(view_1, .corner_radius_top_left_x)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_top_left_y)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_top_right_x)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_top_right_y)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_top_left_x)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_top_left_y)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_bottom_left_x)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_bottom_left_y)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_bottom_right_x)
    //     .setSpring(corner_radius_spring);
    // try le.getAttr(view_1, .corner_radius_bottom_right_y)
    //     .setSpring(corner_radius_spring);

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
            .framebuffer_resize => |size| {
                app.layout_engine.setRootSize(.{
                    .dims = .{
                        @as(f32, @floatFromInt(size.width)),
                        @as(f32, @floatFromInt(size.height)),
                    },
                });
            },
            .mouse_press => |ev| {
                _ = ev;

                // try app.layout_engine.getAttr(app.view_1, .outer_box_x)
                //     .setSpring(.{ .initial_velocity = -1 * 1000.0 });
                // try app.layout_engine.getAttr(app.view_1, .outer_box_y)
                //     .setSpring(.{ .initial_velocity = -1 * 1000.0 });
                // try app.layout_engine.getAttr(app.view_1, .outer_box_width)
                //     .setSpring(.{ .initial_velocity = 2 * 1000.0 });
                // try app.layout_engine.getAttr(app.view_1, .outer_box_height)
                //     .setSpring(.{ .initial_velocity = 2 * 1000.0 });
            },
            .mouse_motion => |ev| {
                const target_x = @as(f32, @floatCast(ev.pos.x * 2));
                _ = target_x;
                const target_y = @as(f32, @floatCast(ev.pos.y * 2));
                _ = target_y;

                // try app.layout_engine.getAttr(app.view_1, .outer_box_x)
                //     .setSpring(.{
                //     .target_value = target_x,
                // });
                // try app.layout_engine.getAttr(app.view_1, .outer_box_y)
                //     .setSpring(.{
                //     .target_value = target_y,
                // });

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

    try app.layout_engine.flushLayout();
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
