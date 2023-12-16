const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const freetype = @import("mach-freetype");
const harfbuzz = @import("mach-harfbuzz");
const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

const geo = @import("../geo.zig");
const bezier = @import("bezier.zig");
const buffer_writer = @import("buffer_writer.zig");
const GArrayList = buffer_writer.GArrayList;

const Self = @This();

const MAX_GLYPH_POINT_COUNT = 128 * 1024;
const MAX_GLYPH_BAND_SEGMENT_COUNT = 1024;
const MAX_GLYPH_AXIS_BANDS = 12;
const MAX_GLYPH_BAND_HEIGHT = 1.0 / @as(f32, @floatFromInt(MAX_GLYPH_AXIS_BANDS));
const MAX_GLYPH_BANDS_DISPLAYED_COUNT = 1024;
const CURVES_PER_SEGMENT = 8;

ft_library: freetype.Library,
fc_config: *c.FcConfig,
loaded_fonts: std.StringArrayHashMap(Font),

loaded_glyph_band_segments: std.ArrayList(BandSegment),
loaded_glyphs: std.AutoArrayHashMap(LoadedGlyphKey, BandSegmentSlice),

pipeline: *gpu.RenderPipeline,
g_glyph_points: GArrayList(@Vector(2, f32)),
g_band_segment_curves: GArrayList(u32),
g_band_segments: GArrayList(BandSegmentInstance),
glyph_data_bgroup: *gpu.BindGroup,

alloc: std.mem.Allocator,

/// Loaded BandSegment.
const BandSegment = struct {
    // UV coords relative to EM-square of the glyph.
    top_left: geo.Vec2,
    size: geo.Vec2,
    band_axis: geo.Axis,
    segment_begin: u32,
    segment_length: u32,
};

const LoadedGlyphKey = struct {
    font_idx: u16,
    glyph_index: u32,
};

const BandSegmentSlice = packed struct {
    begin: u16,
    len: u16,

    fn slice(s: @This(), segments: []BandSegment) []BandSegment {
        return segments[s.begin..][0..s.len];
    }
};

const BandSegmentInstance = packed struct {
    top_left: geo.Vec2,
    size: geo.Vec2,

    em_window_top_left: geo.Vec2,
    em_window_size: geo.Vec2,

    // Index to the glyph in the storage buffer
    // negative: segment is part of a vertical band.
    // positive: segment is part of a horizontal band.
    // absolute value: idx of the of the idx of the first curve in the band segment.
    segment_begin: i32,
    segment_length: u32,

    fn bufferLayout() gpu.VertexBufferLayout {
        return gpu.VertexBufferLayout.init(.{
            .array_stride = @sizeOf(BandSegmentInstance),
            .step_mode = .instance,
            .attributes = &.{
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(BandSegmentInstance, "top_left"),
                    .shader_location = 0,
                },
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(BandSegmentInstance, "size"),
                    .shader_location = 1,
                },
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(BandSegmentInstance, "em_window_top_left"),
                    .shader_location = 2,
                },
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(BandSegmentInstance, "em_window_size"),
                    .shader_location = 3,
                },
                gpu.VertexAttribute{
                    .format = .sint32,
                    .offset = @offsetOf(BandSegmentInstance, "segment_begin"),
                    .shader_location = 4,
                },
                gpu.VertexAttribute{
                    .format = .uint32,
                    .offset = @offsetOf(BandSegmentInstance, "segment_length"),
                    .shader_location = 5,
                },
            },
        });
    }
};

const Font = struct {
    ft_face: freetype.Face,
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

pub fn init(alloc: std.mem.Allocator) !Self {
    const shader_module = core.device.createShaderModuleWGSL(
        "text_pass.wgsl",
        @embedFile("text_pass.wgsl"),
    );
    defer shader_module.release();

    var g_glyph_points = GArrayList(@Vector(2, f32)).initCapacity(.{
        .label = "glyph_points",
        .usage = .{ .storage = true, .copy_dst = true },
        .capacity = MAX_GLYPH_POINT_COUNT,
    });

    // Curve at index 0 is a null curve that we use to pad out the
    // band segment curves buffer.
    try g_glyph_points.writeOne(.{ -1.0, -1.0 });
    try g_glyph_points.writeOne(.{ -1.0, -1.0 });
    try g_glyph_points.writeOne(.{ -1.0, -1.0 });

    var g_band_segment_curves = GArrayList(u32).initCapacity(.{
        .label = "glyph_band_segment_curves",
        .usage = .{ .storage = true, .copy_dst = true },
        .capacity = MAX_GLYPH_BAND_SEGMENT_COUNT * 12, // CURVES_PER_SEGMENT,
    });

    // To avoid curve index 0 having an ambiguous sign. (i.e. sign(idx) == 0)
    try g_band_segment_curves.writeOne(NULL_CURVE);

    const g_band_segments = GArrayList(BandSegmentInstance).initCapacity(.{
        .label = "glyph_band_segments",
        .usage = .{ .vertex = true, .copy_dst = true },
        .capacity = MAX_GLYPH_BANDS_DISPLAYED_COUNT,
    });

    const glyph_data_bgroup_layout = core.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .label = "glyph_data_bgroup_layout",
            .entries = &.{
                gpu.BindGroupLayout.Entry.buffer(
                    0,
                    .{ .fragment = true },
                    .read_only_storage,
                    false,
                    0,
                ),
                gpu.BindGroupLayout.Entry.buffer(
                    1,
                    .{ .fragment = true },
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
                    0, g_glyph_points.getRawBuffer(), //
                    0, g_glyph_points.getSize()),
                gpu.BindGroup.Entry.buffer( //
                    1, g_band_segment_curves.getRawBuffer(), //
                    0, g_band_segment_curves.getSize()),
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
                BandSegmentInstance.bufferLayout(),
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
        .ft_library = try freetype.Library.init(),
        .fc_config = c.FcInitLoadConfigAndFonts() orelse
            return error.FcInitFailed,
        .loaded_fonts = std.StringArrayHashMap(Font).init(alloc),
        .loaded_glyph_band_segments = std.ArrayList(BandSegment).init(alloc),
        .loaded_glyphs = std.AutoArrayHashMap(
            LoadedGlyphKey,
            BandSegmentSlice,
        ).init(alloc),
        .pipeline = pipeline,
        .g_glyph_points = g_glyph_points,
        .g_band_segment_curves = g_band_segment_curves,
        .g_band_segments = g_band_segments,
        .glyph_data_bgroup = glyph_data_bgroup,
        .alloc = alloc,
    };
}
pub fn deinit(self: *Self) !void {
    self.pipeline.release();
    self.glyph_data_bgroup.release();
    self.g_glyph_points.deinit();
    self.g_band_segment_curves.deinit();
    self.g_band_segments.deinit();

    c.FcConfigDestroy(self.fc_config);
    c.FcFini();
    self.ft_library.deinit();
    self.loaded_fonts.deinit();
    self.loaded_glyphs.deinit();
    self.loaded_glyph_band_segments.deinit();

    self.* = undefined;
}

pub fn getFontIndex(self: *Self, name: []const u8) ?u16 {
    if (self.loaded_fonts.getIndex(name)) |idx|
        return @as(u16, @intCast(idx));
    return null;
}

pub fn loadFont(self: *Self, name: [:0]const u8) !u16 {
    const pat = c.FcNameParse(name) orelse return error.FcNameParseFailed;
    if (c.FcConfigSubstitute(self.fc_config, pat, c.FcMatchPattern) != c.FcTrue)
        return error.OutOfMemory;
    c.FcDefaultSubstitute(pat);

    var result: c.FcResult = undefined;
    const font = c.FcFontMatch(self.fc_config, pat, &result) orelse {
        return error.FcNoFontFound;
    };

    // The filename holding the font relative to the config's sysroot
    var path: ?[*:0]u8 = undefined;
    if (c.FcPatternGetString(font, c.FC_FILE, 0, &path) != c.FcResultMatch) {
        return error.FcPatternGetFailed;
    }

    // The index of the font within the file
    var index: c_int = undefined;
    if (c.FcPatternGetInteger(font, c.FC_INDEX, 0, &index) != c.FcResultMatch) {
        return error.FcPatternGetFailed;
    }

    const ft_face = try self.ft_library.createFace(path orelse unreachable, index);

    // TODO: find better value to use as key here. The fontconfig search pattern
    //       string is not reliable as it implies certain default values and is
    //       not portable across other font matching libs we'll eventually have
    //       to option to use.
    const gop = try self.loaded_fonts.getOrPut(name);
    if (gop.found_existing)
        @panic("TODO");
    gop.value_ptr.* = .{
        .ft_face = ft_face,
    };
    return @as(u16, @intCast(gop.index));
}

pub fn getOrLoadFont(self: *Self, name: [:0]const u8) !u16 {
    if (self.getFontIndex(name)) |idx| {
        return idx;
    }
    return self.loadFont(name);
}

fn readGlyphOutline(
    outline: freetype.Outline,
    upem: f32,
    points: *std.ArrayList(@Vector(2, f32)),
    points_base_idx: u32,
    curves: *std.ArrayList(u32),
    reverse_fill: bool,
) !void {
    const DecomposeCtx = struct {
        points: *std.ArrayList(@Vector(2, f32)),
        points_base_idx: u32,
        curves: *std.ArrayList(u32),
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
                @intCast(ctx.points_base_idx + ctx.points.items.len - 3),
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
                @intCast(ctx.points_base_idx + ctx.points.items.len - 3),
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
                    @intCast(ctx.points_base_idx + ctx.points.items.len - 3),
                );
            }
        }
    };
    var decompose_ctx = DecomposeCtx{
        .points = points,
        .curves = curves,
        .points_base_idx = points_base_idx,
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
        const points_len = @as(u32, @intCast(points.items.len));
        for (curves.items) |*curve| {
            // idx relative to only the points in the glyph.
            const old_curve_idx = curve.* - points_base_idx;

            // -2 to point to the last point in the curve that is now the new
            // first point.
            const new_curve_idx = points_len - old_curve_idx - 1 - 2;

            curve.* = points_base_idx + new_curve_idx;
        }
    }
}

fn loadGlyphBandSements(
    self: *Self,
    comptime axis: geo.Axis,
    curves: []u32,
    points: []geo.Vec2,
    points_base_idx: u32,
) !void {
    if (curves.len == 0)
        return;

    const coaxis = switch (axis) {
        .x => .y,
        .y => .x,
    };

    // Greedy algorithm to partition into band segments:
    // Sort curves by their rough min x/y bounding box value.
    // Take every `curves_per_segment` curves and put them in a segment.

    const SortCtx = struct {
        points: []@Vector(2, f32),
        points_base_idx: u32,

        fn getTightBounds(
            ctx: *@This(),
            comptime axis_: geo.Axis,
            idx: u32,
        ) [5]f32 {
            const axis__ = @intFromEnum(axis_);
            const p = ctx.points;
            const b = ctx.points_base_idx;

            const p0 = p[idx - b][axis__];
            const p1 = p[idx - b + 1][axis__];
            const p2 = p[idx - b + 2][axis__];

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
        ) fn (comptime geo.Axis) fn (*@This(), u32) f32 {
            const Ctx = @This();
            const minmax_ = switch (minmax) {
                .min => std.sort.min,
                .max => std.sort.max,
            };

            return struct {
                fn ff(comptime axis_: geo.Axis) fn (*Ctx, u32) f32 {
                    return struct {
                        fn f(ctx: *Ctx, idx: u32) f32 {
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
        ) fn (ctx: *@This(), lhs: u32, rhs: u32) bool {
            const Ctx = @This();
            return struct {
                fn f(ctx: *Ctx, lhs: u32, rhs: u32) bool {
                    const bound = curveBound(.min)(axis_);
                    return bound(ctx, lhs) < bound(ctx, rhs);
                }
            }.f;
        }

        fn ascMax(
            comptime axis_: geo.Axis,
        ) fn (ctx: *@This(), lhs: u32, rhs: u32) bool {
            const Ctx = @This();
            return struct {
                fn f(ctx: *Ctx, lhs: u32, rhs: u32) bool {
                    const bound = curveBound(.max)(axis_);
                    return bound(ctx, lhs) < bound(ctx, rhs);
                }
            }.f;
        }
    };
    var sort_ctx = SortCtx{
        .points = points,
        .points_base_idx = points_base_idx,
    };

    std.mem.sortUnstable(u32, curves, &sort_ctx, SortCtx.ascMin(axis));

    var band_curves: []u32 = curves[0..0];
    var band_axis_begin: f32 = SortCtx.min(axis)(&sort_ctx, curves[0]);
    var band_axis_end: f32 = 0;
    var i: u16 = 0;
    while (i < curves.len) {
        band_curves.len += 1;

        const have_next_curve = i + 1 < curves.len;

        band_axis_end = if (have_next_curve)
            SortCtx.min(axis)(&sort_ctx, curves[i + 1])
        else
            SortCtx.max(axis)(&sort_ctx, std.sort.max(
                u32,
                band_curves,
                &sort_ctx,
                SortCtx.ascMax(axis),
            ) orelse unreachable);

        // Sample disk per pixel is slightly larger than 1 pixel for antialiasing.
        // To compensate for this, we add an inset to each band to make sure we
        // have enough information in each.
        //
        // This avoids inaccuracy for pixels on the edge of a band not being
        // aware of their sample disk's coverage of a curve technically outside
        // the bounds of the band.
        const band_inset = 0.008;

        i += 1;

        if ((!have_next_curve) or
            ((band_curves.len >= CURVES_PER_SEGMENT) and
            (band_axis_end - band_axis_begin >= MAX_GLYPH_BAND_HEIGHT)))
        {
            // inset to the bottom of this band.
            if (have_next_curve) band_axis_end -= band_inset;

            // commit our band.

            const band_coaxis_begin = SortCtx.min(coaxis)(&sort_ctx, std.sort.min(
                u32,
                band_curves,
                &sort_ctx,
                SortCtx.ascMin(coaxis),
            ) orelse unreachable);
            const band_coaxis_end = SortCtx.max(coaxis)(&sort_ctx, std.sort.max(
                u32,
                band_curves,
                &sort_ctx,
                SortCtx.ascMax(coaxis),
            ) orelse unreachable);

            const first_curve_idx = self.g_band_segment_curves.getLen();
            try self.g_band_segment_curves.write(band_curves);

            try self.loaded_glyph_band_segments.append(.{
                .top_left = switch (axis) {
                    .x => geo.Vec2{ band_axis_begin, band_coaxis_end },
                    .y => geo.Vec2{ band_coaxis_begin, band_axis_end },
                },
                .size = switch (axis) {
                    .x => geo.Vec2{
                        band_axis_end - band_axis_begin,
                        band_coaxis_end - band_coaxis_begin,
                    },
                    .y => geo.Vec2{
                        band_coaxis_end - band_coaxis_begin,
                        band_axis_end - band_axis_begin,
                    },
                },
                .segment_begin = @intCast(first_curve_idx),
                .segment_length = @intCast(band_curves.len),
                .band_axis = axis,
            });

            if (have_next_curve) {
                // take back the curves that intersect the next band.

                std.mem.sortUnstable( //
                    u32, band_curves, &sort_ctx, SortCtx.ascMax(axis));

                i -= for (band_curves, 0..) |bc, k| {
                    // inset to the top of the next band
                    if (SortCtx.max(axis)(&sort_ctx, bc) >
                        band_axis_end - band_inset)
                        break @as(u16, @intCast(band_curves.len - k));
                } else 0;
            }

            band_curves = curves[i..][0..0];
            band_axis_begin = band_axis_end;
        }
    }
}

// TODO: make the function instead:
//       - compute and store the glyph's fixed sized segments
// Returns the number of written band segments.
fn loadGlyph(
    self: *Self,
    key: LoadedGlyphKey,
) !BandSegmentSlice {
    const font = &self.loaded_fonts.values()[key.font_idx];
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

    var points = std.ArrayList(@Vector(2, f32)).init(arena_alloc);
    var curves = std.ArrayList(u32).init(arena_alloc);
    const points_base_idx: u32 = @intCast(self.g_glyph_points.getLen());

    const upem: f32 = @floatFromInt(font.ft_face.unitsPerEM());

    try readGlyphOutline(
        outline,
        upem,
        &points,
        points_base_idx,
        &curves,
        flags.reverse_fill,
    );
    try self.g_glyph_points.write(points.items);

    // NOTE: starting here we can mutate `points` as it's
    //       already been written to the GPU.

    const first_segment_idx: u16 =
        @intCast(self.loaded_glyph_band_segments.items.len);

    // Vertical Partition:

    try self.loadGlyphBandSements(.x, curves.items, points.items, points_base_idx);
    try self.loadGlyphBandSements(.y, curves.items, points.items, points_base_idx);

    const last_segment_idx: u16 =
        @intCast(self.loaded_glyph_band_segments.items.len);
    return .{
        .begin = first_segment_idx,
        .len = last_segment_idx - first_segment_idx,
    };
}

fn getOrLoadGlyph(self: *Self, key: LoadedGlyphKey) !BandSegmentSlice {
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

    self.g_band_segments.clear();

    const hb_buffer = harfbuzz.Buffer.init() orelse return error.OutOfMemory;

    for (texts) |text| {
        // TODO: font size should be in pt per EM.
        // Pixels Per EM
        const ppem: geo.Vec2 = @splat(text.font_size);

        const font = &self.loaded_fonts.values()[text.font_idx];
        hb_buffer.reset();
        hb_buffer.addUTF8(text.text, 0, null);
        // TODO: allow specifying direction/script/language
        hb_buffer.guessSegmentProps();

        const hb_face = harfbuzz.Face.fromFreetypeFace(font.ft_face);
        const hb_font = harfbuzz.Font.init(hb_face);
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
            const glyph_band_segments = try self.getOrLoadGlyph(.{
                .font_idx = text.font_idx,
                .glyph_index = glyph_index,
            });

            const band_segments = glyph_band_segments.slice(
                self.loaded_glyph_band_segments.items,
            );

            for (0..band_segments.len) |i| {
                const segment = band_segments[band_segments.len - i - 1];

                // extend the segment by a bit on each side to avoid
                // clipping the glyph's antialiased curves.
                const segment_px_padding = switch (segment.band_axis) {
                    .x => geo.Vec2{ 0, 1.0 },
                    .y => geo.Vec2{ 1.0, 0 },
                };
                const segment_em_padding = segment_px_padding / ppem;

                // convert em-space coords to screen-space:
                const ss_top_left = @floor((cursor + offset) * ppem) + (geo.Vec2{
                    segment.top_left[0],
                    1 - segment.top_left[1],
                } * ppem) - segment_px_padding;
                const ss_size = (segment.size * ppem) +
                    (segment_px_padding * geo.Vec2{ 2, 2 });

                const em_window_top_left = segment.top_left -
                    (segment_em_padding * geo.Vec2{ 1, -1 });
                const em_window_size = segment.size +
                    (segment_em_padding * geo.Vec2{ 2, 2 });

                try self.g_band_segments.writeOne(.{
                    .top_left = out_dims.normalize(ss_top_left),
                    .size = out_dims.normalize_delta(ss_size),
                    .em_window_top_left = em_window_top_left,
                    .em_window_size = em_window_size,
                    .segment_begin = switch (segment.band_axis) {
                        .x => -@as(i32, @intCast(segment.segment_begin)),
                        .y => @intCast(segment.segment_begin),
                    },
                    .segment_length = segment.segment_length,
                });
            }

            cursor += advance;
        }
    }

    const seg_insts = self.g_band_segments.getLen();
    pass.setVertexBuffer(
        0,
        self.g_band_segments.getRawBuffer(),
        0,
        seg_insts * @sizeOf(BandSegmentInstance),
    );
    pass.setBindGroup(0, self.glyph_data_bgroup, null);
    pass.draw(6, @intCast(seg_insts), 0, 0);

    pass.end();
    pass.release();

    const queue = core.queue;
    const command = encoder.finish(null);
    encoder.release();
    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
}
