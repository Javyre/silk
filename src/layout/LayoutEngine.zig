const std = @import("std");
const geo = @import("../geo.zig");
const anim = @import("anim.zig");
const RenderEngine = @import("../render/RenderEngine.zig");
const Allocator = std.mem.Allocator;

const Self = @This();

const CornerRadius = geo.Rect.Radius;

const NONE_INDEX: u32 = std.math.maxInt(u32);
const MAX_INDEX: u32 = std.math.maxInt(u32) - 1;
const MAX_CHILDREN: u32 = 2048;

const DisplayMode = enum {
    flex,
};

// TODO: implement RTL support. For now we assume LTR for flex-direction.
const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,

    fn is_vertical(self: FlexDirection) bool {
        return switch (self) {
            .row, .row_reverse => true,
            .column, .column_reverse => false,
        };
    }
};

const Element = struct {
    kind: Kind,

    first_child: u32 = NONE_INDEX, // Only used for kind = .view
    next_sibling: u32 = NONE_INDEX,

    dirt: DirtFlags,

    display: DisplayMode = .flex,

    // TODO: flex engine? to make these attributes stored less sparsely.
    flex_direction: FlexDirection = .row,
    flex_grow: anim.Value = anim.Value{ .immediate = 1.0 },
    flex_shrink: anim.Value = anim.Value{ .immediate = 1.0 },
    flex_basis: anim.Value = anim.Value.zero,

    margin_top: anim.Value = anim.Value.zero,
    margin_bottom: anim.Value = anim.Value.zero,
    margin_left: anim.Value = anim.Value.zero,
    margin_right: anim.Value = anim.Value.zero,

    // the outer-box contains the padding and (eventually) border but not the
    // margin.
    //
    // the layout engine will work off of this box as a starting constraint.
    // changes in the outer-box are registered in the dirt flags.
    outer_box_x: f32 = 0,
    outer_box_y: f32 = 0,
    outer_box_width: f32 = 0,
    outer_box_height: f32 = 0,

    padding_top: anim.Value = anim.Value.zero,
    padding_bottom: anim.Value = anim.Value.zero,
    padding_left: anim.Value = anim.Value.zero,
    padding_right: anim.Value = anim.Value.zero,

    corner_radius_top_left_x: anim.Value = anim.Value.zero,
    corner_radius_top_left_y: anim.Value = anim.Value.zero,
    corner_radius_top_right_x: anim.Value = anim.Value.zero,
    corner_radius_top_right_y: anim.Value = anim.Value.zero,
    corner_radius_bottom_left_x: anim.Value = anim.Value.zero,
    corner_radius_bottom_left_y: anim.Value = anim.Value.zero,
    corner_radius_bottom_right_x: anim.Value = anim.Value.zero,
    corner_radius_bottom_right_y: anim.Value = anim.Value.zero,

    background_color: anim.Color = anim.Color.transparent,

    const DirtFlags = packed struct(u8) {
        outer_box: bool = false,
        _padding: u7 = undefined,
    };

    const Kind = enum {
        view,
        text,
    };
};

const Elements = std.MultiArrayList(Element);
const Attr = enum {
    //
    // Direct attributes
    //

    display,

    flex_direction,
    flex_grow,
    flex_shrink,
    flex_basis,

    margin_top,
    margin_bottom,
    margin_left,
    margin_right,

    padding_top,
    padding_bottom,
    padding_left,
    padding_right,

    corner_radius_top_left_x,
    corner_radius_top_left_y,
    corner_radius_top_right_x,
    corner_radius_top_right_y,
    corner_radius_bottom_left_x,
    corner_radius_bottom_left_y,
    corner_radius_bottom_right_x,
    corner_radius_bottom_right_y,

    background_color,

    //
    // Virtual attributes
    //

    margin,
    padding,
    corner_radius,
};

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
    slice.items(.outer_box_width)[0] = dims.dims[0];
    slice.items(.outer_box_height)[0] = dims.dims[1];
    slice.items(.dirt)[0].outer_box = true;
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

pub fn getAttr(
    self: *Self,
    el: u32,
    comptime attr: Attr,
) anim.ValueRef(switch (attr) {
    .margin => 4,
    .padding => 4,
    .corner_radius => 8,
    else => 1,
}) {
    switch (attr) {
        // Virtual attributes
        .margin => return .{
            .values = .{
                &self.elements.items(.margin_top)[el],
                &self.elements.items(.margin_bottom)[el],
                &self.elements.items(.margin_left)[el],
                &self.elements.items(.margin_right)[el],
            },
            .engines = &self.animators,
            .alloc = self.alloc,
        },
        .padding => return .{
            .values = .{
                &self.elements.items(.padding_top)[el],
                &self.elements.items(.padding_bottom)[el],
                &self.elements.items(.padding_left)[el],
                &self.elements.items(.padding_right)[el],
            },
            .engines = &self.animators,
            .alloc = self.alloc,
        },
        .corner_radius => return .{
            .values = .{
                &self.elements.items(.corner_radius_top_left_x)[el],
                &self.elements.items(.corner_radius_top_left_y)[el],
                &self.elements.items(.corner_radius_top_right_x)[el],
                &self.elements.items(.corner_radius_top_right_y)[el],
                &self.elements.items(.corner_radius_bottom_left_x)[el],
                &self.elements.items(.corner_radius_bottom_left_y)[el],
                &self.elements.items(.corner_radius_bottom_right_x)[el],
                &self.elements.items(.corner_radius_bottom_right_y)[el],
            },
            .engines = &self.animators,
            .alloc = self.alloc,
        },

        // Transparent attributes
        else => return .{
            .values = .{
                &self.elements.items(@field(
                    Elements.Field,
                    @tagName(attr),
                ))[el],
            },
            .engines = &self.animators,
            .alloc = self.alloc,
        },
    }
}

fn gatherChildrenIndices(
    self: *Self,
    parent: u32,
    store: []u32,
) ![]u32 {
    const slice = self.elements.slice();
    var children: []u32 = store[0..0];
    var child = slice.items(.first_child)[parent];
    while (child != NONE_INDEX) {
        // Not enough room in store.
        if (children.len >= store.len)
            return error.OutOfMemory;

        children = store[0 .. children.len + 1];
        children[children.len - 1] = child;

        child = slice.items(.next_sibling)[child];
    }
    return children;
}

pub fn flushLayout(
    self: *Self,
) !void {
    // We assume a freeze of the tree during layouting.
    const slice = self.elements.slice();

    // Top-down traversal of the tree. (no other guaranteed ordering)
    for (slice.items(.dirt), 0..) |*dirt, _i| {
        const i: u32 = @intCast(_i);

        if (dirt.outer_box) {
            const layout = slice.items(.display)[i];

            switch (layout) {
                .flex => {
                    const outer_box = .{
                        .x = slice.items(.outer_box_x)[i],
                        .y = slice.items(.outer_box_y)[i],
                        .width = slice.items(.outer_box_width)[i],
                        .height = slice.items(.outer_box_height)[i],
                    };
                    const padding = .{
                        .top = slice.items(.padding_top)[i]
                            .getValue(&self.animators),
                        .bottom = slice.items(.padding_bottom)[i]
                            .getValue(&self.animators),
                        .left = slice.items(.padding_left)[i]
                            .getValue(&self.animators),
                        .right = slice.items(.padding_right)[i]
                            .getValue(&self.animators),
                    };
                    const inner_box = .{
                        .x = outer_box.x + padding.left,
                        .y = outer_box.y + padding.top,
                        .width = outer_box.width -
                            (padding.left + padding.right),
                        .height = outer_box.height -
                            (padding.top + padding.bottom),
                    };

                    const flex_dir = slice.items(.flex_direction)[i];

                    //
                    // request the right new sizes to children.
                    //

                    var children_store = [_]u32{NONE_INDEX} ** MAX_CHILDREN;
                    var size_dist_store = [_]f32{0} ** MAX_CHILDREN;

                    var size_left: f32 = if (flex_dir.is_vertical())
                        inner_box.height
                    else
                        inner_box.width;

                    // First pass: resolve find remaining space after
                    // flex-basis.

                    // cache children indices
                    const children =
                        try self.gatherChildrenIndices(i, &children_store);
                    const size_dist = size_dist_store[0..children.len];

                    for (children, 0..) |child, j| {
                        const cm = .{
                            .top = slice.items(.margin_top)[child]
                                .getValue(&self.animators),
                            .bottom = slice.items(.margin_bottom)[child]
                                .getValue(&self.animators),
                            .left = slice.items(.margin_left)[child]
                                .getValue(&self.animators),
                            .right = slice.items(.margin_right)[child]
                                .getValue(&self.animators),
                        };

                        const totalm = if (flex_dir.is_vertical())
                            cm.top + cm.bottom
                        else
                            cm.left + cm.right;

                        const flex_basis = slice.items(.flex_basis)[child]
                            .getValue(&self.animators);
                        const total_basis = flex_basis + totalm;

                        size_left -= total_basis;
                        size_dist[j] = total_basis;
                    }

                    var total_grow: f32 = 0;
                    var total_shrink: f32 = 0;
                    for (children) |child| {
                        total_grow += slice.items(.flex_grow)[child]
                            .getValue(&self.animators);
                    }
                    for (children) |child| {
                        total_shrink += slice.items(.flex_shrink)[child]
                            .getValue(&self.animators);
                    }

                    // Second pass: apply flex-grow and flex-shrink.
                    // NOTE: the way this is implemented probably will lead to floating point
                    // imprecision. We should use the total remaining space for the last element
                    // somehow.
                    if (size_left > 0) {
                        // Apply flex-grow.
                        if (total_grow != 0) {
                            const grow_unit = size_left / total_grow;
                            for (children, 0..) |child, j| {
                                const fg = slice.items(.flex_grow)[child]
                                    .getValue(&self.animators);
                                const delta = grow_unit * fg;
                                size_dist[j] += delta;
                            }
                        }
                    } else {
                        // Apply flex-shrink.
                        if (total_shrink != 0) {
                            const shrink_unit = size_left / total_shrink;
                            for (children, 0..) |child, j| {
                                const fs = slice.items(.flex_shrink)[child]
                                    .getValue(&self.animators);
                                const delta = shrink_unit * fs;
                                size_dist[j] += delta;
                            }
                        }
                    }

                    // Apply distribution to layout of the children.
                    var offset: f32 = 0;
                    for (children, size_dist) |child, size| {
                        var child_box = inner_box;
                        if (flex_dir.is_vertical()) {
                            child_box.y += offset;
                            child_box.height = size;
                        } else {
                            child_box.x += offset;
                            child_box.width = size;
                        }
                        offset += size;

                        const cm = .{
                            .top = slice.items(.margin_top)[child]
                                .getValue(&self.animators),
                            .bottom = slice.items(.margin_bottom)[child]
                                .getValue(&self.animators),
                            .left = slice.items(.margin_left)[child]
                                .getValue(&self.animators),
                            .right = slice.items(.margin_right)[child]
                                .getValue(&self.animators),
                        };

                        slice.items(.outer_box_x)[child] = child_box.x + cm.left;
                        slice.items(.outer_box_y)[child] = child_box.y + cm.top;
                        slice.items(.outer_box_width)[child] = child_box.width -
                            (cm.left + cm.right);
                        slice.items(.outer_box_height)[child] = child_box.height -
                            (cm.top + cm.bottom);
                        slice.items(.dirt)[child].outer_box = true;
                    }
                },
            }

            // dirt resolved
            dirt.outer_box = false;
        }
    }
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
        slice.items(.background_color),
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
        background_color,
    | {
        switch (kind) {
            .view => {
                if (outer_box_width == 0 or outer_box_height == 0)
                    continue;
                if (background_color.a.getValue(&self.animators) == 0)
                    continue;

                try render.writeRect(geo.Rect{
                    .origin = .{
                        outer_box_x,
                        outer_box_y,
                    },
                    .size = .{
                        outer_box_width,
                        outer_box_height,
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

                    .color = geo.Vec4{
                        background_color.r.getValue(&self.animators),
                        background_color.g.getValue(&self.animators),
                        background_color.b.getValue(&self.animators),
                        background_color.a.getValue(&self.animators),
                    },
                });
            },
            .text => {
                // TODO
            },
        }
    }
}
