const std = @import("std");
const core = @import("mach").core;
const gpu = core.gpu;

const FontManager = @import("FontManager.zig");
const LayoutEngine = @import("layout/LayoutEngine.zig");
const RenderEngine = @import("render/RenderEngine.zig");

const geo = @import("geo.zig");
const anim = @import("layout/anim.zig");

test {
    _ = LayoutEngine;
}

pub const App = @This();

gpa: std.heap.GeneralPurposeAllocator(.{}),

font_manager: FontManager,
layout_engine: LayoutEngine,
render_engine: RenderEngine,
view_1: u32,

title_timer: core.Timer,

pub fn init(app: *App) !void {
    const size = .{ .width = 1920 / 2, .height = 1080 / 2 };
    try core.init(.{ .size = size });

    app.gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = app.gpa.allocator();
    app.font_manager = try FontManager.init(alloc);
    const render_engine = try RenderEngine.init(alloc, &app.font_manager);
    var layout_engine = try LayoutEngine.init(alloc);
    const le = &layout_engine;

    le.setRootSize(.{
        .dims = .{
            // FIXME: investigate how to detect retina displays/screen scaling factor.
            @as(f32, @floatFromInt(size.width)) * 2,
            @as(f32, @floatFromInt(size.height)) * 2,
        },
    });

    try le.getAttr(0, .padding).set(anim.value(50));

    var view_1: u32 = undefined;
    try le.appendChildTree(0, .{
        .kind = .view,
        .display = .flex,
        .ref = &view_1,
        // TODO: animated layout param causes rerender/relayout until done.
        .margin_bottom = anim.value(50.0).spring(.{}).from(0),
        .background_color = anim.color(.{
            .r = anim.value(0.7),
            .g = anim.value(1.0),
            .b = anim.value(0.01),
            .a = anim.value(0.75),
        }),
        .corner_radius_top_left = anim.value(50.0),
    });
    try le.getAttr(view_1, .corner_radius_bottom_left).set(anim.spring(.{}));
    try le.getAttr(view_1, .corner_radius).set(anim.value(17.0));

    var view_2: u32 = undefined;
    var view_2_a: u32 = undefined;
    var view_2_b: u32 = undefined;
    try le.appendChildTree(0, .{
        .kind = .view,
        .display = .flex,
        .flex_direction = .column,
        .ref = &view_2,
        .corner_radius = anim.value(17),
        .background_color = anim.color(.{
            .r = anim.value(0.4),
            .g = anim.value(0.4),
            .b = anim.value(0.4),
            .a = anim.value(1),
        }),
        .children = .{
            .{
                .kind = .view,
                .display = .flex,
                .ref = &view_2_a,
                .flex_basis = anim.value(400.0),
                .flex_shrink = anim.value(0.0),
                // .flex_grow = anim.value(0),
                .margin = anim.value(5),
                .corner_radius = anim.value(17 - 5),
                .background_color = anim.color(.{
                    .r = anim.value(0.9),
                    .g = anim.value(0.9),
                    .b = anim.value(0.9),
                    .a = anim.value(1),
                }),
            },
            .{
                .kind = .view,
                .display = .flex,
                .ref = &view_2_b,
                .flex_basis = anim.value(400.0),
                .flex_shrink = anim.value(1.0),
                .flex_grow = anim.value(0.0),
                .margin_left = anim.value(50.0),
                .corner_radius = anim.value(17 - 5),
                .background_color = anim.color(.{
                    .r = anim.value(0.01),
                    .g = anim.value(1.0),
                    .b = anim.value(0.7),
                    .a = anim.value(0.75),
                }),
            },
        },
    });

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
        .font_manager = app.font_manager,
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
    defer app.font_manager.deinit();
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
    const font = try app.font_manager.getOrLoadFont("Georgia");
    try app.render_engine.writeText(
        .{ 50, 50 },
        "gHello, world!\ntesting testing blablabla...",
        font,
        62 * 16,
    );
    try app.render_engine.flushScene(back_buffer);

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
