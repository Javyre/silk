const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const freetype = @import("mach-freetype");
const harfbuzz = @import("mach-harfbuzz");

const geo = @import("../geo.zig");
const bezier = @import("bezier.zig");
const buffer_writer = @import("buffer_writer.zig");
const FontManager = @import("../FontManager.zig");
const GArrayList = buffer_writer.GArrayList;

const Self = @This();

const MAX_GLYPH_POINT_COUNT = 256;
const MAX_GLYPHS_LOADED_COUNT = 2048;
const MAX_GLYPHS_DISPLAYED_COUNT = 1024;
const MAX_GLYPH_AXIS_BANDS = 8;

font_manager: *FontManager,
loaded_glyphs: std.AutoArrayHashMap(LoadedGlyphKey, u32),

pipeline: *gpu.RenderPipeline,
g_glyph_data: GArrayList(u32),
g_glyph_instances: GArrayList(GGlyphInstance),
glyph_data_bgroup: *gpu.BindGroup,

alloc: std.mem.Allocator,

/// Loaded BandSegment.
const BandSegment = struct {
    // UV coords relative to EM-square of the glyph.
    top_left: geo.Vec2,
    size: geo.Vec2,
    band_axis: geo.Axis,
    curves_begin: u32,
    curves_length: u16,
};

const LoadedGlyphKey = struct {
    font_idx: u16,
    glyph_index: u32,
};

const GlyphWindowSlice = packed struct {
    begin: u16,
    len: u16,

    fn slice(s: @This(), windows: []GlyphWindow) []GlyphWindow {
        return windows[s.begin..][0..s.len];
    }
};

// TODO: have a single quad that figures out it's bands in the fragment shader.
// (i.e. band_idx = int(x % 0.1))
const GlyphWindow = struct {
    em_window_top_left: geo.Vec2,
    em_window_size: geo.Vec2,

    vert_curves_begin: u32,
    hori_curves_begin: u32,
    vh_curves_lengths: packed struct(u32) {
        hori: u16,
        vert: u16,
    },
};

/// Staging area for loading and writing glyph data to the GPU.
///
/// Layout:
///
/// GlyphData: { // fields aligned to 4 bytes
///     info: GlyphInfo,
///     lengths: GlyphLengths,
///     vart_band_splits: []f32,
///     vert_band_ends: []u16,
///     vert_band_curves: []u16,
///     hori_band_splits: []f32,
///     hori_band_ends: []u16,
///     hori_band_curves: []u16,
///     points: []geo.Vec2,
/// }
const GGlyphDataBuilder = struct {
    const ArrayListU16 = std.ArrayListAligned(u16, @alignOf(u32));

    info: ?GlyphInfo = null,
    vert_band_splits: std.ArrayList(f32),
    /// Amount of curves in each vert band.
    vert_band_ends: ArrayListU16,
    vert_band_curves: ArrayListU16,
    hori_band_splits: std.ArrayList(f32),
    /// Amount of curves in each hori band.
    hori_band_ends: ArrayListU16,
    hori_band_curves: ArrayListU16,
    points: std.ArrayList(geo.Vec2),

    const GlyphInfo = packed struct(u128) {
        em_window_bottom_left: geo.Vec2,
        em_window_top_right: geo.Vec2,
    };
    const GlyphLengths = packed struct(u32) {
        /// Amount of vert bands
        vert_band_count: u16 = 0,
        /// Amount of hori bands
        hori_band_count: u16 = 0,
    };
    comptime {
        std.debug.assert(@sizeOf(GlyphInfo) == 4 * @sizeOf(u32));
        std.debug.assert(@sizeOf(GlyphLengths) == 1 * @sizeOf(u32));
    }

    fn init(alloc: std.mem.Allocator) GGlyphDataBuilder {
        return .{
            .info = null,
            .vert_band_splits = std.ArrayList(f32).init(alloc),
            .vert_band_ends = ArrayListU16.init(alloc),
            .vert_band_curves = ArrayListU16.init(alloc),
            .hori_band_splits = std.ArrayList(f32).init(alloc),
            .hori_band_ends = ArrayListU16.init(alloc),
            .hori_band_curves = ArrayListU16.init(alloc),
            .points = std.ArrayList(geo.Vec2).init(alloc),
        };
    }

    fn writePadded(
        src_bytes: []align(@alignOf(u32)) const u8,
        dest: *GArrayList(u32),
    ) !void {
        const remainder = src_bytes.len % @sizeOf(u32);
        const src_even = src_bytes[0 .. src_bytes.len - remainder];
        const src_rest = src_bytes[src_bytes.len - remainder ..];

        // aligncast safe since src_bytes is aligned.
        try dest.write(@alignCast(std.mem.bytesAsSlice(u32, src_even)));
        if (remainder > 0) {
            var extra: u32 = 0;
            @memcpy(std.mem.asBytes(&extra)[0..remainder], src_rest);
            try dest.writeOne(extra);
        }
    }

    fn write(self: *GGlyphDataBuilder, dest: *GArrayList(u32)) !void {
        const asBytes = std.mem.asBytes;
        const sliceAsBytes = std.mem.sliceAsBytes;

        const info: *const GlyphInfo =
            &(self.info orelse return error.InvalidState);
        try writePadded(asBytes(info), dest);
        try writePadded(asBytes(&GlyphLengths{
            .vert_band_count = @intCast(self.vert_band_ends.items.len / 2),
            .hori_band_count = @intCast(self.hori_band_ends.items.len / 2),
        }), dest);
        try writePadded(sliceAsBytes(self.vert_band_splits.items), dest);
        try writePadded(sliceAsBytes(self.vert_band_ends.items), dest);
        try writePadded(sliceAsBytes(self.vert_band_curves.items), dest);
        try writePadded(sliceAsBytes(self.hori_band_splits.items), dest);
        try writePadded(sliceAsBytes(self.hori_band_ends.items), dest);
        try writePadded(sliceAsBytes(self.hori_band_curves.items), dest);
        try writePadded(sliceAsBytes(self.points.items), dest);
    }
};

const GGlyphInstance = packed struct {
    top_left: geo.Vec2,
    scale: geo.Vec2,
    glyph_data_begin: u32,

    fn bufferLayout() gpu.VertexBufferLayout {
        return gpu.VertexBufferLayout.init(.{
            .array_stride = @sizeOf(GGlyphInstance),
            .step_mode = .instance,
            .attributes = &.{
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(GGlyphInstance, "top_left"),
                    .shader_location = 0,
                },
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(GGlyphInstance, "scale"),
                    .shader_location = 1,
                },
                gpu.VertexAttribute{
                    .format = .uint32,
                    .offset = @offsetOf(GGlyphInstance, "glyph_data_begin"),
                    .shader_location = 2,
                },
            },
        });
    }
};

pub const Text = struct {
    pos: geo.Vec2,
    text: []const u8,
    font_idx: u16,
    font_size: f32,
};

/// Curve at index 0 is a null curve that we use to pad out the
/// band segment curves buffer.
const NULL_CURVE = 0;

pub fn init(
    alloc: std.mem.Allocator,
    font_manager: *FontManager,
) !Self {
    const shader_module = core.device.createShaderModuleWGSL(
        "text_pass.wgsl",
        @embedFile("text_pass.wgsl"),
    );
    defer shader_module.release();

    const avg_glyph_data_size =
        (@sizeOf(GGlyphDataBuilder.GlyphInfo) +
        @sizeOf(GGlyphDataBuilder.GlyphLengths) +
        MAX_GLYPH_POINT_COUNT * @sizeOf(geo.Vec2)) /
        @sizeOf(u32);
    var g_glyph_data = GArrayList(u32).initCapacity(.{
        .label = "g_glyph_data",
        .usage = .{ .storage = true, .copy_dst = true },
        .capacity = avg_glyph_data_size * MAX_GLYPHS_LOADED_COUNT,
    });

    const g_glyph_instances = GArrayList(GGlyphInstance).initCapacity(.{
        .label = "glyph_instances",
        .usage = .{ .vertex = true, .copy_dst = true },
        .capacity = MAX_GLYPHS_DISPLAYED_COUNT,
    });

    const glyph_data_bgroup_layout = core.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .label = "glyph_data_bgroup_layout",
            .entries = &.{
                gpu.BindGroupLayout.Entry.buffer(
                    0,
                    .{ .vertex = true, .fragment = true },
                    .read_only_storage,
                    false,
                    0,
                ),
            },
        }),
    );
    const glyph_data_bgroup = core.device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .label = "glyph_data_bgroup",
            .layout = glyph_data_bgroup_layout,
            .entries = &.{
                gpu.BindGroup.Entry.buffer( //
                    0, g_glyph_data.getRawBuffer(), //
                    0, g_glyph_data.getSize()),
            },
        }),
    );

    const pipeline_layout = core.device.createPipelineLayout(
        &gpu.PipelineLayout.Descriptor.init(.{
            .label = "text_pass_pipeline_layout",
            .bind_group_layouts = &.{glyph_data_bgroup_layout},
        }),
    );

    // Fragment state
    const blend = gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
        },
    };
    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .layout = pipeline_layout,
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{
                GGlyphInstance.bufferLayout(),
            },
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = shader_module,
            .entry_point = "frag_main",
            .targets = &.{color_target},
        }),
    };
    const pipeline = core.device.createRenderPipeline(&pipeline_descriptor);

    return .{
        .font_manager = font_manager,
        .loaded_glyphs = std.AutoArrayHashMap(LoadedGlyphKey, u32).init(alloc),
        .pipeline = pipeline,
        .g_glyph_data = g_glyph_data,
        .g_glyph_instances = g_glyph_instances,
        .glyph_data_bgroup = glyph_data_bgroup,
        .alloc = alloc,
    };
}
pub fn deinit(self: *Self) !void {
    self.pipeline.release();
    self.glyph_data_bgroup.release();
    self.g_glyph_data.deinit();
    self.g_glyph_instances.deinit();

    self.loaded_glyphs.deinit();

    self.* = undefined;
}

fn readGlyphOutline(
    outline: freetype.Outline,
    upem: f32,
    points: *std.ArrayList(geo.Vec2),
    curves: *std.ArrayList(u16),
    reverse_fill: bool,
) !void {
    const DecomposeCtx = struct {
        points: *std.ArrayList(geo.Vec2),
        curves: *std.ArrayList(u16),
        upem: f32,

        fn move_to(ctx: *@This(), to: freetype.Vector) !void {
            try ctx.points.append(.{
                @as(f32, @floatFromInt(to.x)) / ctx.upem,
                @as(f32, @floatFromInt(to.y)) / ctx.upem,
            });
        }
        fn line_to(ctx: *@This(), to: freetype.Vector) !void {
            const p0 = ctx.points.items[ctx.points.items.len - 1];
            const p2 = geo.Vec2{
                @as(f32, @floatFromInt(to.x)) / ctx.upem,
                @as(f32, @floatFromInt(to.y)) / ctx.upem,
            };

            const midpoint = (p2 + p0) / geo.Vec2{ 2, 2 };

            try ctx.points.append(midpoint);
            try ctx.points.append(p2);
            try ctx.curves.append(
                @intCast(ctx.points.items.len - 3),
            );
        }
        fn conic_to(
            ctx: *@This(),
            ctrl: freetype.Vector,
            to: freetype.Vector,
        ) !void {
            try ctx.points.append(.{
                @as(f32, @floatFromInt(ctrl.x)) / ctx.upem,
                @as(f32, @floatFromInt(ctrl.y)) / ctx.upem,
            });
            try ctx.points.append(.{
                @as(f32, @floatFromInt(to.x)) / ctx.upem,
                @as(f32, @floatFromInt(to.y)) / ctx.upem,
            });
            try ctx.curves.append(
                @intCast(ctx.points.items.len - 3),
            );
        }
        fn cubic_to(
            ctx: *@This(),
            ctrl1: freetype.Vector,
            ctrl2: freetype.Vector,
            to: freetype.Vector,
        ) !void {
            const cubic = [4]geo.Vec2{ ctx.points.getLast(), .{
                @as(f32, @floatFromInt(ctrl1.x)) / ctx.upem,
                @as(f32, @floatFromInt(ctrl1.y)) / ctx.upem,
            }, .{
                @as(f32, @floatFromInt(ctrl2.x)) / ctx.upem,
                @as(f32, @floatFromInt(ctrl2.y)) / ctx.upem,
            }, .{
                @as(f32, @floatFromInt(to.x)) / ctx.upem,
                @as(f32, @floatFromInt(to.y)) / ctx.upem,
            } };

            const max_parts = 8;
            var points_store: [max_parts * 2 + 1]geo.Vec2 = undefined;
            const quadratic = bezier.cubic_to_quadratic(&points_store, cubic, 1e-4);

            const new_points = quadratic[1..];
            for (0..new_points.len / 2) |i| {
                try ctx.points.append(new_points[2 * i]);
                try ctx.points.append(new_points[2 * i + 1]);
                try ctx.curves.append(
                    @intCast(ctx.points.items.len - 3),
                );
            }
        }
    };
    var decompose_ctx = DecomposeCtx{
        .points = points,
        .curves = curves,
        .upem = upem,
    };
    try outline.decompose(&decompose_ctx, .{
        .move_to = DecomposeCtx.move_to,
        .line_to = DecomposeCtx.line_to,
        .conic_to = DecomposeCtx.conic_to,
        .cubic_to = DecomposeCtx.cubic_to,
        .shift = 0,
        .delta = 0,
    });

    if (reverse_fill) {
        // Reverse the order of the points.
        // This is to support PostScript/OTF fonts which use
        // counter-clockwise winding for the glyph outlines.
        std.mem.reverse(geo.Vec2, points.items);
        const points_len = @as(u16, @intCast(points.items.len));
        for (curves.items) |*curve| {
            // -2 to point to the last point in the curve that is now the new
            // first point.
            curve.* = points_len - curve.* - 1 - 2;
        }
    }
}

fn loadGlyphBandSegments(
    comptime axis: geo.Axis,
    curves: []u16,
    points: []geo.Vec2,
    staged_band_splits: *std.ArrayList(f32),
    staged_band_curves: *std.ArrayListAligned(u16, @alignOf(u32)),
    staged_band_ends: *std.ArrayListAligned(u16, @alignOf(u32)),
) !struct {
    min_axis: f32,
    max_axis: f32,
} {
    if (curves.len == 0)
        return .{
            .min_axis = 0,
            .max_axis = 0,
        };

    const coaxis = switch (axis) {
        .x => .y,
        .y => .x,
    };

    const SortCtx = struct {
        points: []const @Vector(2, f32),

        fn getTightBounds(
            ctx: *@This(),
            comptime axis_: geo.Axis,
            idx: u16,
        ) [5]f32 {
            const axis__ = @intFromEnum(axis_);
            const p = ctx.points;

            const p0 = p[idx][axis__];
            const p1 = p[idx + 1][axis__];
            const p2 = p[idx + 2][axis__];

            // midpoints
            const e1 = (p1 + p0) / 2;
            const e2 = (p2 + p1) / 2;

            // midpoints of midpoints
            const m1 = (p0 + e1) / 2;
            const m2 = (e1 + e2) / 2;
            const m3 = (e2 + p2) / 2;

            return .{ p0, m1, m2, m3, p2 };
        }

        fn curveBound(
            comptime minmax: enum { min, max },
        ) fn (comptime geo.Axis) fn (*@This(), u16) f32 {
            const Ctx = @This();
            const minmax_ = switch (minmax) {
                .min => std.sort.min,
                .max => std.sort.max,
            };

            return struct {
                fn ff(comptime axis_: geo.Axis) fn (*Ctx, u16) f32 {
                    return struct {
                        fn f(ctx: *Ctx, idx: u16) f32 {
                            return minmax_(
                                f32,
                                &ctx.getTightBounds(axis_, idx),
                                {},
                                std.sort.asc(f32),
                            ) orelse unreachable;
                        }
                    }.f;
                }
            }.ff;
        }

        const min = curveBound(.min);
        const max = curveBound(.max);

        fn ascMin(
            comptime axis_: geo.Axis,
        ) fn (ctx: *@This(), lhs: u16, rhs: u16) bool {
            const Ctx = @This();
            return struct {
                fn f(ctx: *Ctx, lhs: u16, rhs: u16) bool {
                    const bound = curveBound(.min)(axis_);
                    return bound(ctx, lhs) < bound(ctx, rhs);
                }
            }.f;
        }

        fn ascMax(
            comptime axis_: geo.Axis,
        ) fn (ctx: *@This(), lhs: u16, rhs: u16) bool {
            const Ctx = @This();
            return struct {
                fn f(ctx: *Ctx, lhs: u16, rhs: u16) bool {
                    const bound = curveBound(.max)(axis_);
                    return bound(ctx, lhs) < bound(ctx, rhs);
                }
            }.f;
        }
    };
    var sort_ctx = SortCtx{ .points = points };

    // we add an extra EM amount of margin to let antialiasing take place
    // slightly outside the bounds.
    const aa_margin = 0.01;

    std.mem.sortUnstable(u16, curves, &sort_ctx, SortCtx.ascMin(axis));
    const min_axis = SortCtx.min(axis)(&sort_ctx, curves[0]) - aa_margin;
    const max_axis = SortCtx.max(axis)(&sort_ctx, std.sort.max(
        u16,
        curves,
        &sort_ctx,
        SortCtx.ascMax(axis),
    ) orelse unreachable) + aa_margin;

    const band_axis_size = x: {
        // we need our floats to behave the same as on the gpu
        @setFloatMode(.Strict);
        break :x (max_axis - min_axis) / MAX_GLYPH_AXIS_BANDS;
    };

    // Extra EM space on either axis-extremity from which the band should still
    // include curves.
    const band_overshoot = 0.01;

    var curve_cursor: u16 = 0;
    for (0..MAX_GLYPH_AXIS_BANDS) |i| {
        const is_last_band = i == MAX_GLYPH_AXIS_BANDS - 1;

        const band_axis_end = x: {
            @setFloatMode(.Strict);
            if (!is_last_band) {
                break :x min_axis + band_axis_size *
                    @as(f32, @floatFromInt(i + 1));
            } else {
                break :x max_axis;
            }
        };

        const band_curves_begin = curve_cursor;

        // find end
        if (is_last_band) {
            curve_cursor = @as(u16, @intCast(curves.len));
        } else {
            while (curve_cursor < curves.len) {
                const curve_axis_begin = SortCtx.min(axis)(
                    &sort_ctx,
                    curves[curve_cursor],
                );
                if (curve_axis_begin > band_axis_end + band_overshoot) {
                    break;
                }

                curve_cursor += 1;
            }
        }
        const band_curves_end = curve_cursor;
        const band_curves = curves[band_curves_begin..band_curves_end];

        // Split into two segments
        std.mem.sortUnstable( //
            u16, band_curves, &sort_ctx, SortCtx.ascMin(coaxis));

        const median_idx = band_curves.len / 2;
        const split_point = SortCtx.min(coaxis)(
            &sort_ctx,
            band_curves[median_idx],
        );
        try staged_band_splits.append(split_point);

        const split_curve_idx_1 = for (
            band_curves[median_idx..],
            median_idx..,
        ) |bc, k| {
            if (SortCtx.min(coaxis)(&sort_ctx, bc) > split_point)
                break @as(u16, @intCast(k - 1));
        } else median_idx;

        const band_curves_1 = band_curves[0 .. split_curve_idx_1 + 1];
        try staged_band_curves.appendSlice(band_curves_1);
        try staged_band_ends.append(
            @intCast(staged_band_curves.items.len - 1),
        );

        std.mem.sortUnstable( //
            u16, band_curves, &sort_ctx, SortCtx.ascMax(coaxis));

        const split_curve_idx_2 = for (band_curves, 0..) |bc, k| {
            if (SortCtx.max(coaxis)(&sort_ctx, bc) >= split_point)
                break @as(u16, @intCast(k));
        } else unreachable;

        const band_curves_2 = band_curves[split_curve_idx_2..];
        try staged_band_curves.appendSlice(band_curves_2);
        try staged_band_ends.append(
            @intCast(staged_band_curves.items.len - 1),
        );

        // take back the curves that intersect the next band.
        if (!is_last_band) {
            std.mem.sortUnstable( //
                u16, band_curves, &sort_ctx, SortCtx.ascMax(axis));

            curve_cursor -= for (band_curves, 0..) |bc, k| {
                // overshoot the top of the next band
                if (SortCtx.max(axis)(&sort_ctx, bc) >
                    band_axis_end - band_overshoot)
                    break @as(u16, @intCast(band_curves.len - k));
            } else 0;
        }
    }

    return .{
        .min_axis = min_axis,
        .max_axis = max_axis,
    };
}

/// Returns the index of the first encoded u32 of the glyph data.
fn loadGlyph(
    self: *Self,
    key: LoadedGlyphKey,
) !u32 {
    const font = self.font_manager.getFont(key.font_idx);
    try font.ft_face.loadGlyph(key.glyph_index, .{
        .no_bitmap = true,
        .no_scale = true,
        .no_hinting = true,
    });
    const glyph = font.ft_face.glyph();
    const outline = glyph.outline() orelse {
        std.log.err("Failed to get outline for glyph {s} {s}", .{
            font.ft_face.familyName() orelse "(null)",
            font.ft_face.styleName() orelse "(null)",
        });
        return error.FontNotOutline;
    };

    const flags = outline.flags();
    if (flags.even_odd_fill) {
        std.log.warn("Glyph {x} in {s} {s} has even-odd fill. This is currently unsupported", .{
            key.glyph_index,
            font.ft_face.familyName() orelse "(null)",
            font.ft_face.styleName() orelse "(null)",
        });
    }

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var builder = GGlyphDataBuilder.init(arena_alloc);
    // Array of all the curves in the glyph.
    // Only used to compute the band segments, not written to the glyphdata
    // directly.
    var curves = std.ArrayList(u16).init(arena_alloc);

    const upem: f32 = @floatFromInt(font.ft_face.unitsPerEM());

    try readGlyphOutline(
        outline,
        upem,
        &builder.points,
        &curves,
        flags.reverse_fill,
    );
    const x_bounds = try loadGlyphBandSegments(
        .x,
        curves.items,
        builder.points.items,
        &builder.vert_band_splits,
        &builder.vert_band_curves,
        &builder.vert_band_ends,
    );
    const y_bounds = try loadGlyphBandSegments(
        .y,
        curves.items,
        builder.points.items,
        &builder.hori_band_splits,
        &builder.hori_band_curves,
        &builder.hori_band_ends,
    );
    builder.info = .{
        .em_window_bottom_left = .{ x_bounds.min_axis, y_bounds.min_axis },
        .em_window_top_right = .{ x_bounds.max_axis, y_bounds.max_axis },
    };

    const data_begin: u32 = @intCast(self.g_glyph_data.getLen());
    try builder.write(&self.g_glyph_data);
    return data_begin;
}

fn getOrLoadGlyph(self: *Self, key: LoadedGlyphKey) !u32 {
    const gop = try self.loaded_glyphs.getOrPut(key);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    errdefer self.loaded_glyphs.swapRemoveAt(gop.index);

    const seg_slice = try self.loadGlyph(key);
    gop.value_ptr.* = seg_slice;
    return seg_slice;
}

pub fn draw(self: *Self, output: *gpu.Texture, texts: []const Text) !void {
    @setFloatMode(.Optimized);

    const output_view = output.createView(&.{
        .label = "rect_pass_output_view",
    });
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = output_view,
        // Shouldn't be used since .load_op = .load
        .clear_value = undefined,
        .load_op = .load,
        .store_op = .store,
    };
    defer output_view.release();

    const out_dims = geo.ScreenDims{ .dims = .{
        @floatFromInt(output.getWidth()),
        @floatFromInt(output.getHeight()),
    } };

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .label = "text_pass",
        .color_attachments = &.{color_attachment},
    });

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(self.pipeline);

    self.g_glyph_instances.clear();

    const hb_buffer = harfbuzz.Buffer.init() orelse return error.OutOfMemory;
    defer hb_buffer.deinit();

    for (texts) |text| {
        // TODO: font size should be in pt per EM.
        // Pixels Per EM
        const ppem: geo.Vec2 = @splat(text.font_size);

        const font = self.font_manager.getFont(text.font_idx);
        hb_buffer.reset();
        hb_buffer.addUTF8(text.text, 0, null);
        // TODO: allow specifying direction/script/language
        hb_buffer.guessSegmentProps();

        const hb_face = harfbuzz.Face.fromFreetypeFace(font.ft_face);
        defer hb_face.deinit();
        const hb_font = harfbuzz.Font.init(hb_face);
        defer hb_font.deinit();
        // 64ths of an em.
        hb_font.setScale(64, 64);

        hb_font.shape(hb_buffer, null);

        var cursor = text.pos / ppem;
        for (
            hb_buffer.getGlyphInfos(),
            hb_buffer.getGlyphPositions().?,
        ) |glyph_info, glyph_pos| {
            const advance = geo.Vec2{
                @as(f32, @floatFromInt(glyph_pos.x_advance)) /
                    @as(f32, 64),
                -@as(f32, @floatFromInt(glyph_pos.y_advance)) /
                    @as(f32, 64),
            };
            const offset = geo.Vec2{
                @as(f32, @floatFromInt(glyph_pos.x_offset)) /
                    @as(f32, 64),
                -@as(f32, @floatFromInt(glyph_pos.y_offset)) /
                    @as(f32, 64),
            };
            const glyph_index = glyph_info.codepoint;

            // Get or load the glyph outline.
            const glyph_data_begin = try self.getOrLoadGlyph(.{
                .font_idx = text.font_idx,
                .glyph_index = glyph_index,
            });

            // convert em-space coords to screen-space:
            const ss_top_left = @floor((cursor + offset) * ppem);
            const ss_scale = ppem;

            try self.g_glyph_instances.writeOne(.{
                .top_left = out_dims.normalize(ss_top_left),
                .scale = out_dims.normalize_delta(ss_scale),
                .glyph_data_begin = glyph_data_begin,
            });

            cursor += advance;
        }
    }

    const glyph_insts = self.g_glyph_instances.getLen();
    pass.setVertexBuffer(
        0,
        self.g_glyph_instances.getRawBuffer(),
        0,
        glyph_insts * @sizeOf(GGlyphInstance),
    );
    pass.setBindGroup(0, self.glyph_data_bgroup, null);
    pass.draw(6, @intCast(glyph_insts), 0, 0);

    pass.end();
    pass.release();

    const queue = core.queue;
    const command = encoder.finish(null);
    encoder.release();
    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
}
