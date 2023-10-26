//! == Layout Engine ==
//!
//! Heavily DOM-inspired layout engine.
//!
//! We store elements as a SOA in topological order (parent > child).
//! The tree is kept track of with:
//! - first_child: the first child of a node
//! - next_sibling: the next sibling of a node
//!
//! e.g.: the tree
//! a
//! ├─ b
//! │  ├─ c
//! │  └─ d
//! └─ e
//!
//! is represented as:
//!
//! a
//! └─> b ──> e
//!     └─> c ──> d
//!
//! `└─>`: First Child
//! `──>`: Next Sibling
//!
//! and stored as:
//!
//! [ a, b, e, c, d ]
//!
//! The `first_child` and `next_sibling` are strong references.
//! The `backlink` is a weak reference to the single strong reference that
//! exists to the current element.
//!
//! NOTE: We optimize for breadth-first ordering but assume only topological
//!       ordering.
//!
//! NOTE: Notice that there is at most two references to each element.
//!       This helps reduce the writes during tree mutations at the cost of
//!       some extra reads to find certain relatives (parent, nth sibling,
//!       etc.)
//!

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

const Err = error{
    OutOfMemory,
};

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
    kind: Kind = .view,

    /// The label can be used for debugging purposes.
    /// (memory not owned by the layout engine)
    label: ?[]const u8 = undefined,

    first_child: u32 = NONE_INDEX, // Only used for kind = .view
    next_sibling: u32 = NONE_INDEX,
    /// weak reference to owning element of this element (either by first_child
    /// or next_sibling).
    backlink: u32 = NONE_INDEX,

    flags: Flags = .{},
    sort_index_: u32 = NONE_INDEX, // temp field for sorting

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

    const Flags = packed struct(u8) {
        dirt: packed struct(u1) {
            outer_box: bool = false,
        } = .{},
        _padding: u7 = undefined,
    };

    const Kind = enum {
        view,
        text,
    };
};

const Elements = std.MultiArrayList(Element);

const element_attrs = .{
    .Direct = enum {
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
    },

    .virtual = .{
        .margin = .{ "top", "bottom", "left", "right" },
        .padding = .{ "top", "bottom", "left", "right" },

        .corner_radius = .{
            "top_left_x",     "top_left_y",
            "top_right_x",    "top_right_y",
            "bottom_left_x",  "bottom_left_y",
            "bottom_right_x", "bottom_right_y",
        },
        .corner_radius_top_left = .{ "x", "y" },
        .corner_radius_top_right = .{ "x", "y" },
        .corner_radius_bottom_left = .{ "x", "y" },
        .corner_radius_bottom_right = .{ "x", "y" },
    },
};

const Attr = x: {
    const d_fnames = std.meta.fieldNames(element_attrs.Direct);
    const v_fnames = std.meta.fieldNames(@TypeOf(element_attrs.virtual));
    const names = d_fnames ++ v_fnames;

    var fields: [names.len]std.builtin.Type.EnumField = undefined;
    for (names, &fields, 0..) |name, *field, i| {
        field.* = .{ .name = name, .value = i };
    }

    break :x @Type(std.builtin.Type{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, names.len),
            .decls = &.{},
            .fields = &fields,
            .is_exhaustive = true,
        },
    });
};

fn isDirectAttr(attr: Attr) bool {
    const name = @tagName(attr);
    return std.meta.fieldIndex(element_attrs.Direct, name) != null;
}

fn isVirtualAttr(attr: Attr) bool {
    const name = @tagName(attr);
    return std.meta.fieldIndex(@TypeOf(element_attrs.virtual), name) != null;
}

alloc: Allocator,
animators: anim.Engines,
elements: Elements = .{},
// TODO: turn this into a fixed-size array and if it gets full, we simply
//       defragment our element storage.
free_elements: std.ArrayList(u32),

pub fn init(alloc: Allocator) !Self {
    var self = Self{
        .alloc = alloc,
        .animators = try anim.Engines.init(alloc),
        .free_elements = std.ArrayList(u32).init(alloc),
    };

    try self.free_elements.ensureTotalCapacity(255);

    try self.elements.ensureTotalCapacity(alloc, 255);

    // Init root element.
    //
    // Always at position 0 since we keep top-down ordering on the table of
    // nodes.
    try self.elements.append(alloc, .{
        .kind = .view,
        .label = "root",
    });

    return self;
}

pub fn deinit(self: *Self) !void {
    defer self.animators.deinit(self.alloc);
    defer self.free_elements.deinit();
    defer self.elements.deinit(self.alloc);
}

pub fn setRootSize(self: *Self, dims: geo.ScreenDims) void {
    const slice = self.elements.slice();
    slice.items(.outer_box_width)[0] = dims.dims[0];
    slice.items(.outer_box_height)[0] = dims.dims[1];
    slice.items(.flags)[0].dirt.outer_box = true;
}

/// Allocated a new element with an index greater than `greater_idx_than`.
/// If `greater_idx_than` is null, the index is greater than all indices.
fn appendElement(self: *Self, el: Element, greater_idx_than: ?u32) Err!u32 {
    // Medium-effort looking through the free_elements.
    if (self.free_elements.items.len > 0) {
        const last = self.free_elements.items.len - 1;
        const max = @min(1024, self.free_elements.items.len);
        const gthan_idx = greater_idx_than orelse 0;

        // start search from end to recycle most recent elements first.
        // (more likely to be cache-hot)
        for (0..max) |i| {
            const free_idx = self.free_elements.items[last - i];
            if (free_idx > gthan_idx) {
                _ = self.free_elements.swapRemove(last - i);
                return free_idx;
            }
        }
    }

    // Give up recycling and just allocate a new index.
    const new_idx: u32 = @intCast(self.elements.len);
    if (new_idx >= MAX_INDEX) {
        return error.OutOfMemory;
    }
    try self.elements.append(self.alloc, el);
    return new_idx;
}

test "appendElement recycles" {
    var le = try Self.init(std.testing.allocator);
    defer (le.deinit() catch unreachable);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var a_ref: u32 = undefined;
    var a_a_ref: u32 = undefined;
    var a_b_ref: u32 = undefined;
    var a_c_ref: u32 = undefined;
    try le.appendChildTree(0, .{
        .label = "a",
        .kind = .view,
        .ref = &a_ref,
        .children = .{
            .{ .label = "a.a", .kind = .view, .ref = &a_a_ref },
            .{ .label = "a.b", .kind = .view, .ref = &a_b_ref },
            .{ .label = "a.c", .kind = .view, .ref = &a_c_ref },
        },
    });

    try le.removeElement(a_a_ref);
    try le.removeElement(a_b_ref);
    try le.removeElement(a_c_ref);
    try le.removeElement(a_ref);
    try std.testing.expectEqualSlices(u32, &.{
        a_a_ref,
        a_b_ref,
        a_c_ref,
        a_ref,
    }, le.free_elements.items);

    var b_ref: u32 = undefined;
    try le.appendChildTree(0, .{ .label = "b", .kind = .view, .ref = &b_ref });

    // Search for free element starts from end.
    // constraint is: new_idx > 0
    try std.testing.expectEqual(a_ref, b_ref);
    try std.testing.expectEqualSlices(u32, &.{
        a_a_ref,
        a_b_ref,
        a_c_ref,
    }, le.free_elements.items);

    var c_ref: u32 = undefined;
    try le.appendChildTree(0, .{ .label = "c", .kind = .view, .ref = &c_ref });

    // Search for free element starts from end.
    // constraint is: new_idx > a_a_ref
    try std.testing.expectEqual(a_c_ref, c_ref);
    try le.expectElementIndices(&.{
        a_a_ref,
        a_b_ref,
    }, le.free_elements.items);
}

/// Appends an element to the given parent.
///
/// The element is inserted as the last child of the parent.
pub fn appendChild(self: *Self, parent: u32, el: Element) Err!u32 {
    const new_idx = try self.appendElement(el, parent);
    self.setLastChild(parent, new_idx);
    return new_idx;
}

/// Appends an element as the next sibling of the given sibling.
pub fn appendSibling(self: *Self, sibling: u32, el: Element) Err!u32 {
    const new_idx = try self.appendElement(el, sibling);
    self.setNextSibling(sibling, new_idx);
    return new_idx;
}

/// Removes the given element from the tree.
pub fn removeElement(self: *Self, idx: u32) Err!void {
    const slice = self.elements.slice();
    const backlink = slice.items(.backlink)[idx];

    // only root is not owned by another element.
    std.debug.assert(backlink != NONE_INDEX);

    // Parents own their first_sibling and incidently their entire subtree.
    const first_child = slice.items(.first_child)[idx];
    var child = first_child;
    while (child != NONE_INDEX) {
        const next_child = slice.items(.next_sibling)[child];
        try self.removeElement(child);
        child = next_child;
    }

    const next_sibling = slice.items(.next_sibling)[idx];
    const parent_first_child = &slice.items(.first_child)[backlink];
    const prev_next_sibling = &slice.items(.next_sibling)[backlink];

    if (parent_first_child.* == idx) {
        parent_first_child.* = next_sibling;
    } else if (prev_next_sibling.* == idx) {
        prev_next_sibling.* = next_sibling;
    } else {
        const backlink_label = slice.items(.label)[backlink];
        const label = slice.items(.label)[idx];

        std.debug.panic("backlinked element {} ({?s}) does not actually own this element {} ({?s})", .{
            backlink, backlink_label,
            idx,      label,
        });
    }

    if (next_sibling != NONE_INDEX) {
        slice.items(.backlink)[next_sibling] = backlink;
    }
    if (first_child != NONE_INDEX) {
        slice.items(.backlink)[first_child] = backlink;
    }

    try self.free_elements.append(idx);
}

test "removeElement preserves backlinks" {
    var le = try Self.init(std.testing.allocator);
    defer (le.deinit() catch unreachable);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var a_ref: u32 = undefined;
    var a_a_ref: u32 = undefined;
    var a_b_ref: u32 = undefined;
    var a_c_ref: u32 = undefined;
    try le.appendChildTree(0, .{
        .label = "a",
        .kind = .view,
        .ref = &a_ref,
        .children = .{
            .{ .label = "a.a", .kind = .view, .ref = &a_a_ref },
            .{ .label = "a.b", .kind = .view, .ref = &a_b_ref },
            .{ .label = "a.c", .kind = .view, .ref = &a_c_ref },
        },
    });

    const eq = expectElementIndex;
    try eq(&le, @as(u32, 0), le.elements.items(.backlink)[a_ref]);
    try eq(&le, a_ref, le.elements.items(.backlink)[a_a_ref]);
    try eq(&le, a_a_ref, le.elements.items(.backlink)[a_b_ref]);
    try eq(&le, a_b_ref, le.elements.items(.backlink)[a_c_ref]);

    try le.removeElement(a_b_ref);

    try eq(&le, @as(u32, 0), le.elements.items(.backlink)[a_ref]);
    try eq(&le, a_ref, le.elements.items(.backlink)[a_a_ref]);
    try eq(&le, a_a_ref, le.elements.items(.backlink)[a_c_ref]);
}

test "removeElement recurses and bookkeeps" {
    var le = try Self.init(std.testing.allocator);
    defer (le.deinit() catch unreachable);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var a_ref: u32 = undefined;
    var a_a_ref: u32 = undefined;
    var a_b_ref: u32 = undefined;
    var a_c_ref: u32 = undefined;
    try le.appendChildTree(0, .{
        .label = "a",
        .kind = .view,
        .ref = &a_ref,
        .children = .{
            .{ .label = "a.a", .kind = .view, .ref = &a_a_ref },
            .{ .label = "a.b", .kind = .view, .ref = &a_b_ref },
            .{ .label = "a.c", .kind = .view, .ref = &a_c_ref },
        },
    });
    try std.testing.expectEqualStrings(
        \\(root)
        \\└─ (a)
        \\   ├─ (a.a)
        \\   ├─ (a.b)
        \\   └─ (a.c)
    ,
        try le.dumpTree(arena.allocator(), .{}),
    );
    try std.testing.expectEqualSlices(u32, le.free_elements.items, &.{});

    try le.removeElement(a_c_ref);
    try std.testing.expectEqualStrings(
        \\(root)
        \\└─ (a)
        \\   ├─ (a.a)
        \\   └─ (a.b)
    ,
        try le.dumpTree(arena.allocator(), .{}),
    );
    try std.testing.expectEqualSlices(u32, le.free_elements.items, &.{
        a_c_ref,
    });

    try le.removeElement(a_ref);
    try std.testing.expectEqualStrings(
        \\(root)
    ,
        try le.dumpTree(arena.allocator(), .{}),
    );
    try std.testing.expectEqualSlices(u32, le.free_elements.items, &.{
        a_c_ref, a_a_ref, a_b_ref, a_ref,
    });
}

fn setLastChild(self: *Self, parent: u32, child: u32) void {
    if (std.debug.runtime_safety)
        std.debug.assert(parent < child);

    // NOTE: we don't check that the child is already a child.

    const slice = self.elements.slice();

    const first_child = slice.items(.first_child)[parent];

    if (first_child == NONE_INDEX) {
        slice.items(.first_child)[parent] = child;
        slice.items(.backlink)[child] = parent;
    } else {
        var last_child = first_child;
        while (slice.items(.next_sibling)[last_child] != NONE_INDEX) {
            last_child = slice.items(.next_sibling)[last_child];
        }
        slice.items(.next_sibling)[last_child] = child;
        slice.items(.backlink)[child] = last_child;
    }
}

fn setNextSibling(self: *Self, sibling: u32, next_sibling: u32) void {
    // NOTE: we don't check that the new sibling is below the parent.
    //       Neither do we check if the sibling is already a sibling.

    const slice = self.elements.slice();
    const next_next_sibling = slice.items(.next_sibling)[sibling];
    slice.items(.next_sibling)[sibling] = next_sibling;
    slice.items(.next_sibling)[next_sibling] = next_next_sibling;
    slice.items(.backlink)[next_sibling] = sibling;
    if (next_next_sibling != NONE_INDEX)
        slice.items(.backlink)[next_next_sibling] = next_sibling;
}

pub fn getAttr(
    self: *Self,
    el: u32,
    comptime attr: Attr,
) anim.ValueRef(x: {
    if (isDirectAttr(attr)) {
        break :x 1;
    } else if (isVirtualAttr(attr)) {
        break :x @field(element_attrs.virtual, @tagName(attr)).len;
    } else {
        unreachable;
    }
}) {
    if (comptime isDirectAttr(attr)) {
        return .{
            .values = .{
                &self.elements.items(@field(
                    Elements.Field,
                    @tagName(attr),
                ))[el],
            },
            .engines = &self.animators,
            .alloc = self.alloc,
        };
    } else if (comptime isVirtualAttr(attr)) {
        const suffixes = @field(element_attrs.virtual, @tagName(attr));

        var values: [suffixes.len]*anim.Value = undefined;
        inline for (suffixes, &values) |suffix, *value| {
            value.* = &self.elements.items(
                @field(Elements.Field, @tagName(attr) ++ "_" ++ suffix),
            )[el];
        }

        return .{
            .values = values,
            .engines = &self.animators,
            .alloc = self.alloc,
        };
    } else {
        unreachable;
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
    for (slice.items(.flags), 0..) |*flags, _i| {
        const i: u32 = @intCast(_i);

        if (flags.dirt.outer_box) {
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
                        slice.items(.flags)[child].dirt.outer_box = true;
                    }
                },
            }

            // dirt resolved
            flags.dirt.outer_box = false;
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

/// Sort the elements in a breadth-first order.
/// Invalidates references to elements.
///
/// This should be done every so often to keep the tree cache-friendly.
///
/// Our layout algorithms assume that the elements are sorted parent > child,
/// but optimize for the breadth-first case.
pub fn reindexElementsBreadthFirst(self: *Self) !void {
    const slice = self.elements.slice();

    var queue = std.ArrayList(u32).init(self.alloc);
    defer queue.deinit();
    var queue_head: u32 = 0;

    var index_map = try self.alloc.alloc(u32, self.elements.len);
    defer self.alloc.free(index_map);

    var i: u32 = 0;
    var visiting: u32 = 0;
    while (true) {
        const first_child = slice.items(.first_child)[visiting];
        const next_sibling = slice.items(.next_sibling)[visiting];

        slice.items(.sort_index_)[visiting] = i;
        index_map[visiting] = i;
        i += 1;

        if (first_child != NONE_INDEX) {
            try queue.append(first_child);
        }

        if (next_sibling != NONE_INDEX) {
            visiting = next_sibling;
        } else {
            if (queue_head >= queue.items.len)
                break;

            visiting = queue.items[queue_head];
            queue_head += 1;

            // try to save on memory:
            if (queue_head >= queue.items.len / 2) {
                @memcpy(
                    queue.items[0 .. queue.items.len - queue_head],
                    queue.items[queue_head..],
                );
                queue.items.len -= queue_head;
                queue_head = 0;
            }
        }
    }

    self.elements.sortUnstable(struct {
        indices: []u32,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.indices[a_index] < ctx.indices[b_index];
        }
    }{
        .indices = slice.items(.sort_index_),
    });

    // correct the invalidated indices
    for (
        slice.items(.first_child),
        slice.items(.next_sibling),
    ) |*first_child, *next_sibling| {
        if (first_child.* != NONE_INDEX) {
            first_child.* = index_map[first_child.*];
        }
        if (next_sibling.* != NONE_INDEX) {
            next_sibling.* = index_map[next_sibling.*];
        }
    }
}

const PrettyIndex = struct {
    index: u32,
    engine: *const Self,

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const slice = value.engine.elements.slice();
        try writer.print("{} ({?s})", .{
            value.index,
            slice.items(.label)[value.index],
        });
    }
};

pub fn expectElementIndex(self: *const Self, expected: u32, actual: u32) !void {
    if (actual != expected) {
        const expected_pretty = PrettyIndex{ .index = expected, .engine = self };
        const actual_pretty = PrettyIndex{ .index = actual, .engine = self };

        std.debug.print("expected element index {}, got {}", .{
            expected_pretty,
            actual_pretty,
        });
        return error.TestExpectedEqual;
    }
}

pub fn expectElementIndices(
    self: *const Self,
    expected: []const u32,
    actual: []const u32,
) !void {
    var pretty_expected =
        try std.testing.allocator.alloc(PrettyIndex, expected.len);
    defer std.testing.allocator.free(pretty_expected);
    var pretty_actual =
        try std.testing.allocator.alloc(PrettyIndex, actual.len);
    defer std.testing.allocator.free(pretty_actual);

    for (expected, pretty_expected) |idx, *pretty| {
        pretty.* = .{ .index = idx, .engine = self };
    }
    for (actual, pretty_actual) |idx, *pretty| {
        pretty.* = .{ .index = idx, .engine = self };
    }

    return std.testing.expectEqualSlices(
        PrettyIndex,
        pretty_expected,
        pretty_actual,
    );
}

/// Dumps the tree in a human-readable format.
/// Useful for debugging.
///
/// ```zig
/// const alloc = std.testing.allocator;
/// const le = try LayoutEngine.init(alloc);
/// try le.appendChild(0, .{ .kind = .view });
/// try le.appendChild(0, .{ .kind = .view });
///
/// try std.testing.expectEqualStrings(
///     \\0
///     \\├─ 1
///     \\└─ 2
/// ,
///     try le.dumpTree(alloc, .{}),
/// );
/// ```
pub fn dumpTree(self: *const Self, alloc: std.mem.Allocator, opts: struct {
    show_index: bool = false,
    show_label: bool = true,
    show_backlink: bool = false,
}) ![]const u8 {
    const slice = self.elements.slice();

    var buf = std.ArrayList(u8).init(alloc);
    var buf_writer = buf.writer();
    var stack = std.ArrayList(u32).init(alloc);
    var depth: u32 = 0;

    // pre-order traversal
    var visiting: u32 = 0;

    // var i: u32 = 0;
    outer: while (true) {
        const next_sibling = slice.items(.next_sibling)[visiting];
        const first_child = slice.items(.first_child)[visiting];

        // visit
        if (depth > 0) {
            for (stack.items[1..]) |parent_next_sibling| {
                if (parent_next_sibling == NONE_INDEX) {
                    try buf_writer.writeAll("   ");
                } else {
                    try buf_writer.writeAll("│  ");
                }
            }
            if (next_sibling == NONE_INDEX) {
                try buf_writer.writeAll("└─ ");
            } else {
                try buf_writer.writeAll("├─ ");
            }
        }
        var is_first = true;
        if (opts.show_index) {
            if (!is_first) try buf_writer.writeAll(" ");
            is_first = false;

            try buf_writer.print(":{}", .{visiting});
        }
        if (opts.show_label) {
            if (!is_first) try buf_writer.writeAll(" ");
            is_first = false;

            if (slice.items(.label)[visiting]) |label| {
                try buf_writer.print("({s})", .{label});
            } else {
                try buf_writer.writeAll("(none)");
            }
        }
        if (opts.show_backlink) {
            if (!is_first) try buf_writer.writeAll(" ");
            is_first = false;

            const backlink = slice.items(.backlink)[visiting];
            if (backlink == NONE_INDEX) {
                try buf_writer.writeAll("^:none");
            } else {
                try buf_writer.print("^:{}", .{backlink});
            }
        }

        if (first_child != NONE_INDEX) {
            try stack.append(next_sibling);
            visiting = first_child;
            depth += 1;
        } else if (next_sibling != NONE_INDEX) {
            visiting = next_sibling;
        } else {
            while (true) {
                if (stack.items.len == 0) {
                    break :outer;
                }
                visiting = stack.pop();
                depth -= 1;

                if (visiting != NONE_INDEX)
                    break;
            }
        }

        try buf_writer.writeByte('\n');
    }

    return buf.toOwnedSlice();
}

test "tree mutations" {
    const alloc = std.testing.allocator;

    // arena for temp strings
    var arena = std.heap.ArenaAllocator.init(alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    // layout engine
    var le = try Self.init(alloc);
    defer (le.deinit() catch unreachable);

    try std.testing.expectEqualStrings(
        ":0 (root)",
        try le.dumpTree(arena_alloc, .{ .show_index = true }),
    );

    var view_1: u32 = undefined;
    try le.appendChildTree(0, .{
        .label = "1",
        .kind = .view,
        .ref = &view_1,
        .children = .{
            .{ .label = "1a", .kind = .view },
            .{ .label = "1b", .kind = .view },
        },
    });
    try le.appendChildTree(0, .{
        .label = "2",
        .kind = .view,
        .children = .{
            .{ .label = "2a", .kind = .view },
        },
    });

    try le.appendChildTree(view_1, .{
        .label = "1c",
        .kind = .view,
    });

    // insertion order
    try std.testing.expectEqualStrings(
        \\:0 (root)
        \\├─ :1 (1)
        \\│  ├─ :2 (1a)
        \\│  ├─ :3 (1b)
        \\│  └─ :6 (1c)
        \\└─ :4 (2)
        \\   └─ :5 (2a)
    ,
        try le.dumpTree(arena_alloc, .{ .show_index = true }),
    );

    try le.reindexElementsBreadthFirst();

    // breadth-first order
    try std.testing.expectEqualStrings(
        \\:0 (root)
        \\├─ :1 (1)
        \\│  ├─ :3 (1a)
        \\│  ├─ :4 (1b)
        \\│  └─ :5 (1c)
        \\└─ :2 (2)
        \\   └─ :6 (2a)
    ,
        try le.dumpTree(arena_alloc, .{ .show_index = true }),
    );
}

// =============================================================================
// API Frontend
//

// FIXME: once https://github.com/ziglang/zig/issues/6211 is fixed, we can
//        embed the Element fields instead of having the props field.
// pub const ElementTree = x: {
//     const ExtraFields = struct {
//         ref: ?*u32 = null,
//         // placeholder type
//         children: []void = undefined,
//     };

//     const fields = std.meta.fields(Element) ++ std.meta.fields(ExtraFields);

//     break :x @Type(std.builtin.Type{
//         .Struct = .{
//             .layout = .Auto,
//             .fields = &fields,
//             .decls = &.{},
//             .is_tuple = false,
//         },
//     });
// };

fn typeWithRef(comptime T: type) type {
    return if (std.meta.fieldIndex(T, "ref") != null)
        T
    else
        @Type(std.builtin.Type{
            .Struct = std.builtin.Type.Struct{
                .layout = .Auto,
                .fields = std.meta.fields(T) ++
                    std.meta.fields(struct { ref: *u32 }),
                .decls = &.{},
                .is_tuple = false,
            },
        });
}

fn treeWithRef(maybe_ref: *u32, tree: anytype) typeWithRef(@TypeOf(tree)) {
    if (std.meta.fieldIndex(@TypeOf(tree), "ref") != null) {
        return tree;
    } else {
        var ret: typeWithRef(@TypeOf(tree)) = undefined;
        ret.ref = maybe_ref;
        inline for (comptime std.meta.fieldNames(@TypeOf(tree))) |fname| {
            @field(ret, fname) = @field(tree, fname);
        }
        return ret;
    }
}

pub fn appendChildTree(self: *Self, parent: u32, tree: anytype) Err!void {
    const Tree = @TypeOf(tree);
    var el: Element = .{};

    inline for (comptime std.meta.fieldNames(Element)) |fname| {
        if (std.meta.fieldIndex(Tree, fname) != null)
            @field(el, fname) = @field(tree, fname);
    }

    const el_idx = try self.appendChild(parent, el);
    if (std.meta.fieldIndex(Tree, "ref") != null) {
        std.debug.assert(@TypeOf(tree.ref) == *u32);
        tree.ref.* = el_idx;
    }

    if (std.meta.fieldIndex(Tree, "children") != null) {
        if (tree.children.len > 0) {
            var ref_store: u32 = undefined;
            const first_child = treeWithRef(&ref_store, tree.children[0]);

            try self.appendChildTree(el_idx, first_child);
            var prev_sibling = first_child.ref.*;

            inline for (1..tree.children.len) |i| {
                const child = treeWithRef(&ref_store, tree.children[i]);

                try self.appendSiblingTree(prev_sibling, child);
                prev_sibling = child.ref.*;
            }
        }
    }
}

pub fn appendSiblingTree(self: *Self, sibling: u32, tree: anytype) Err!void {
    const Tree = @TypeOf(tree);
    var el: Element = .{};

    inline for (comptime std.meta.fieldNames(Element)) |fname| {
        if (std.meta.fieldIndex(Tree, fname) != null)
            @field(el, fname) = @field(tree, fname);
    }

    const el_idx = try self.appendSibling(sibling, el);
    if (std.meta.fieldIndex(Tree, "ref") != null) {
        std.debug.assert(@TypeOf(tree.ref) == *u32);
        tree.ref.* = el_idx;
    }

    if (std.meta.fieldIndex(Tree, "children") != null) {
        if (tree.children.len > 0) {
            var ref_store: u32 = undefined;
            const first_child = treeWithRef(&ref_store, tree.children[0]);

            try self.appendChildTree(el_idx, first_child);
            var prev_sibling = first_child.ref.*;

            inline for (1..tree.children.len) |i| {
                const child = treeWithRef(&ref_store, tree.children[i]);

                try self.appendSiblingTree(prev_sibling, child);
                prev_sibling = child.ref.*;
            }
        }
    }
}
