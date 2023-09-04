const std = @import("std");
const geo = @import("../render/geo.zig");
const RenderEngine = @import("../render/RenderEngine.zig").RenderEngine;
const Allocator = std.mem.Allocator;

const Self = @This();

const Box = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

const CornerRadius = geo.Rect.Radius;

const Element = struct {
    kind: Kind,

    dirt: DirtFlags,

    outer_box_target: Box,
    outer_box_value: Box,

    corner_radius_target: CornerRadius = .{},
    corner_radius_value: CornerRadius = .{},

    const DirtFlags = packed struct(u8) {
        outer_box: bool = false,
        corner_radius: bool = false,
        _padding: u6 = undefined,
    };

    const Kind = enum {
        view,
        text,
    };
};

elements: std.MultiArrayList(Element) = .{},

pub fn init(alloc: Allocator) !Self {
    var self = Self{};

    try self.elements.ensureTotalCapacity(alloc, 255);

    try self.elements.append(alloc, .{
        .kind = .view,
        .dirt = .{},

        .outer_box_value = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .outer_box_target = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    });

    return self;
}

pub fn deinit(self: *Self, alloc: Allocator) !void {
    defer self.elements.deinit(alloc);
}

pub fn setRootSize(self: *Self) void {
    _ = self;
    // self.elements.
}

pub fn drawFrame(
    self: *Self,
    alloc: Allocator,
    delta_time: f32,
    renderer: *RenderEngine,
) !void {
    _ = renderer;
    _ = delta_time;
    _ = alloc;
    _ = self;
}
