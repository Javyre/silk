const std = @import("std");
const geo = @import("../geo.zig");
const anim = @import("anim.zig");
const RenderEngine = @import("../render/RenderEngine.zig");
const Allocator = std.mem.Allocator;

const Self = @This();

const CornerRadius = geo.Rect.Radius;

const NONE_INDEX: u32 = std.math.maxInt(u32);
const MAX_INDEX: u32 = std.math.maxInt(u32) - 1;

const Element = struct {
    kind: Kind,

    first_child: u32 = NONE_INDEX, // Only used for kind = .view
    next_sibling: u32 = NONE_INDEX,

    dirt: DirtFlags,

    outer_box_x: anim.Value = anim.Value.zero,
    outer_box_y: anim.Value = anim.Value.zero,
    outer_box_width: anim.Value = anim.Value.zero,
    outer_box_height: anim.Value = anim.Value.zero,

    corner_radius_top_left_x: anim.Value = anim.Value.zero,
    corner_radius_top_left_y: anim.Value = anim.Value.zero,
    corner_radius_top_right_x: anim.Value = anim.Value.zero,
    corner_radius_top_right_y: anim.Value = anim.Value.zero,
    corner_radius_bottom_left_x: anim.Value = anim.Value.zero,
    corner_radius_bottom_left_y: anim.Value = anim.Value.zero,
    corner_radius_bottom_right_x: anim.Value = anim.Value.zero,
    corner_radius_bottom_right_y: anim.Value = anim.Value.zero,

    // outer_box: anim.Box,

    // corner_radius: CornerRadius = .{},

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

const Elements = std.MultiArrayList(Element);
const Attr = Elements.Field;

alloc: Allocator,
animators: anim.Engines,
elements: Elements = .{},

pub fn init(alloc: Allocator) !Self {
    var self = Self{
        .alloc = alloc,
        .animators = try anim.Engines.init(alloc),
    };

    try self.elements.ensureTotalCapacity(alloc, 255);

    // Init root element.
    //
    // Always at position 0 since we keep top-down ordering on the table of
    // nodes.
    try self.elements.append(alloc, .{
        .kind = .view,
        .dirt = .{},
    });

    return self;
}

pub fn deinit(self: *Self) !void {
    defer self.animators.deinit(self.alloc);
    defer self.elements.deinit(self.alloc);
}

pub fn setRootSize(self: *Self, dims: geo.ScreenDims) void {
    const slice = self.elements.slice();
    slice.items(.outer_box_width)[0] = .{ .immediate = dims.width };
    slice.items(.outer_box_height)[0] = .{ .immediate = dims.height };
}

fn appendElement(self: *Self, el: Element) !u32 {
    const new_idx: u32 = @intCast(self.elements.len);
    if (new_idx >= MAX_INDEX) {
        return error.OutOfMemory;
    }
    try self.elements.append(self.alloc, el);
    return new_idx;
}

pub fn appendChild(self: *Self, parent: u32, el: Element) !u32 {
    const new_idx = try self.appendElement(el);
    self.setLastChild(parent, new_idx);
    return new_idx;
}

pub fn appendSibling(self: *Self, sibling: u32, el: Element) !u32 {
    const new_idx = try self.appendElement(el);
    self.setNextSibling(sibling, new_idx);
    return new_idx;
}

fn setLastChild(self: *Self, parent: u32, child: u32) void {
    if (std.debug.runtime_safety)
        std.debug.assert(parent < child);

    // NOTE: we don't check that the child is already a child.

    const slice = self.elements.slice();

    const first_child = slice.items(.first_child)[parent];

    if (first_child == NONE_INDEX) {
        slice.items(.first_child)[parent] = child;
    } else {
        var last_child = first_child;
        while (slice.items(.next_sibling)[last_child] != NONE_INDEX) {
            last_child = slice.items(.next_sibling)[last_child];
        }
        slice.items(.next_sibling)[last_child] = child;
    }
}

fn setNextSibling(self: *Self, sibling: u32, next_sibling: u32) void {
    // NOTE: we don't check that the new sibling is below the parent.
    //       Neither do we check if the sibling is already a sibling.

    const slice = self.elements.slice();
    const next_next_sibling = slice.items(.next_sibling)[sibling];
    slice.items(.next_sibling)[sibling] = next_sibling;
    slice.items(.next_sibling)[next_sibling] = next_next_sibling;
}

pub fn getAttr(self: *Self, el: u32, comptime attr: Attr) anim.ValueRef {
    return .{
        .value = &self.elements.items(attr)[el],
        .engines = &self.animators,
        .alloc = self.alloc,
    };
}

pub fn renderFrame(
    self: *Self,
    render: *RenderEngine,
) !void {
    self.animators.update();

    // We take advantage of the parent > child ordering of the elements to
    // render the tree in a single pass with the proper z-ordering (ignoring
    // siblings).

    const slice = self.elements.slice();
    for (
        slice.items(.kind),
        slice.items(.outer_box_x),
        slice.items(.outer_box_y),
        slice.items(.outer_box_width),
        slice.items(.outer_box_height),
        slice.items(.corner_radius_top_left_x),
        slice.items(.corner_radius_top_left_y),
        slice.items(.corner_radius_top_right_x),
        slice.items(.corner_radius_top_right_y),
        slice.items(.corner_radius_bottom_left_x),
        slice.items(.corner_radius_bottom_left_y),
        slice.items(.corner_radius_bottom_right_x),
        slice.items(.corner_radius_bottom_right_y),
    ) |
        kind,
        outer_box_x,
        outer_box_y,
        outer_box_width,
        outer_box_height,
        corner_radius_top_left_x,
        corner_radius_top_left_y,
        corner_radius_top_right_x,
        corner_radius_top_right_y,
        corner_radius_bottom_left_x,
        corner_radius_bottom_left_y,
        corner_radius_bottom_right_x,
        corner_radius_bottom_right_y,
    | {
        switch (kind) {
            .view => {
                try render.writeRect(geo.Rect{
                    .origin = .{
                        outer_box_x.getValue(&self.animators),
                        outer_box_y.getValue(&self.animators),
                    },
                    .size = .{
                        outer_box_width.getValue(&self.animators),
                        outer_box_height.getValue(&self.animators),
                    },
                    .radius = .{
                        .top_left = .{
                            corner_radius_top_left_x.getValue(&self.animators),
                            corner_radius_top_left_y.getValue(&self.animators),
                        },
                        .top_right = .{
                            corner_radius_top_right_x.getValue(&self.animators),
                            corner_radius_top_right_y.getValue(&self.animators),
                        },
                        .bottom_left = .{
                            corner_radius_bottom_left_x.getValue(&self.animators),
                            corner_radius_bottom_left_y.getValue(&self.animators),
                        },
                        .bottom_right = .{
                            corner_radius_bottom_right_x.getValue(&self.animators),
                            corner_radius_bottom_right_y.getValue(&self.animators),
                        },
                    },

                    // SPONGE: unhardcode this
                    .color = geo.Vec4{ 0.7, 1, 0.01, 0.75 },
                });
            },
            .text => {
                // TODO
            },
        }
    }
}
