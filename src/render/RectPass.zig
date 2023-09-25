const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;

const geo = @import("../geo.zig");
const buffer_writer = @import("buffer_writer.zig");
const GPUBuffer = buffer_writer.GPUBuffer;

const Self = @This();

// Maximum number of vertices that can be written to a single buffer.
const MAX_VERTEX_COUNT = 8 * 1024;

pipeline: *gpu.RenderPipeline,
vertex_buffer: GPUBuffer,
index_buffer: GPUBuffer,

const Vertex = packed struct {
    position: geo.Vec2,
    normal: geo.Vec2,
    color: geo.Vec4,

    fn bufferLayout() gpu.VertexBufferLayout {
        return gpu.VertexBufferLayout.init(.{
            .array_stride = @sizeOf(Vertex),
            .step_mode = .vertex,
            .attributes = &.{
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(Vertex, "position"),
                    .shader_location = 0,
                },
                gpu.VertexAttribute{
                    .format = .float32x2,
                    .offset = @offsetOf(Vertex, "normal"),
                    .shader_location = 1,
                },
                gpu.VertexAttribute{
                    .format = .float32x4,
                    .offset = @offsetOf(Vertex, "color"),
                    .shader_location = 2,
                },
            },
        });
    }
};

pub fn init() Self {
    const shader_module = core.device.createShaderModuleWGSL(
        "rect_pass.wgsl",
        @embedFile("rect_pass.wgsl"),
    );
    defer shader_module.release();

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
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{Vertex.bufferLayout()},
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = shader_module,
            .entry_point = "frag_main",
            .targets = &.{color_target},
        }),
    };
    const pipeline = core.device.createRenderPipeline(&pipeline_descriptor);

    const vb_raw = core.device.createBuffer(&.{
        .label = "vertex_buffer",
        .usage = .{ .vertex = true, .copy_dst = true },
        .size = MAX_VERTEX_COUNT * @sizeOf(Vertex),
    });
    const ib_raw = core.device.createBuffer(&.{
        .label = "index_buffer",
        .usage = .{ .index = true, .copy_dst = true },
        .size = MAX_VERTEX_COUNT * @sizeOf(u16),
    });

    return .{
        .pipeline = pipeline,
        .vertex_buffer = .{ .buffer = vb_raw },
        .index_buffer = .{ .buffer = ib_raw },
    };
}

pub fn deinit(self: *Self) void {
    self.pipeline.release();
    self.vertex_buffer.buffer.release();
    self.index_buffer.buffer.release();

    self.* = undefined;
}

pub fn draw(
    self: *Self,
    output: *gpu.Texture,
    rects: []const geo.Rect,
) void {
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

    const win_dims = geo.ScreenDims{ .dims = .{
        @floatFromInt(output.getWidth()),
        @floatFromInt(output.getHeight()),
    } };

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .label = "rect_pass",
        .color_attachments = &.{color_attachment},
    });

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(self.pipeline);

    self.vertex_buffer.len = 0;
    self.index_buffer.len = 0;
    var vb_bw = std.io.bufferedWriter(self.vertex_buffer.writer());
    var ib_bw = std.io.bufferedWriter(self.index_buffer.writer());
    const vb = vb_bw.writer();
    const ib = ib_bw.writer();

    var v_idx: u16 = 0;
    for (rects) |rect| {
        v_idx += self.writeRect(v_idx, vb, ib, win_dims, rect) catch |err| {
            std.log.err("Failed to write rect: {}", .{err});
            break;
        };
    }

    vb_bw.flush() catch |err| {
        std.log.err("Failed to flush vertex buffer: {}", .{err});
    };
    ib_bw.flush() catch |err| {
        std.log.err("Failed to flush index buffer: {}", .{err});
    };

    pass.setVertexBuffer(0, self.vertex_buffer.buffer, 0, self.vertex_buffer.len);
    pass.setIndexBuffer(self.index_buffer.buffer, .uint16, 0, self.index_buffer.len);

    const index_count =
        @as(u32, @intCast(self.index_buffer.len)) / @sizeOf(u16);
    pass.drawIndexed(index_count, 1, 0, 0, 0);

    pass.end();
    pass.release();

    const queue = core.queue;
    const command = encoder.finish(null);
    encoder.release();
    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
}

fn writeRect(
    self: *Self,
    v_idx: u16,
    vb: anytype,
    ib: anytype,
    win_dims: geo.ScreenDims,
    rect: geo.Rect,
) !u16 {
    if (rect.radius.isZero()) {
        return self.writeRectSimple(v_idx, vb, ib, win_dims, rect);
    } else {
        return self.writeRectRounded(v_idx, vb, ib, win_dims, rect);
    }
}

fn writeRectSimple(
    self: *Self,
    v_idx: u16,
    vb: anytype,
    ib: anytype,
    win_dims: geo.ScreenDims,
    rect: geo.Rect,
) !u16 {
    _ = self;
    try vb.writeStruct(Vertex{
        .position = win_dims.normalize(rect.origin),
        .normal = .{ 0, 0 },
        .color = rect.color,
    });
    try vb.writeStruct(Vertex{
        .position = win_dims.normalize(rect.origin + geo.Vec2{ rect.size[0], 0 }),
        .normal = .{ 0, 0 },
        .color = rect.color,
    });
    try vb.writeStruct(Vertex{
        .position = win_dims.normalize(rect.origin + rect.size),
        .normal = .{ 0, 0 },
        .color = rect.color,
    });
    try vb.writeStruct(Vertex{
        .position = win_dims.normalize(rect.origin + geo.Vec2{ 0, rect.size[1] }),
        .normal = .{ 0, 0 },
        .color = rect.color,
    });

    try ib.writeIntNative(u16, v_idx + 0);
    try ib.writeIntNative(u16, v_idx + 1);
    try ib.writeIntNative(u16, v_idx + 2);
    try ib.writeIntNative(u16, v_idx + 0);
    try ib.writeIntNative(u16, v_idx + 2);
    try ib.writeIntNative(u16, v_idx + 3);

    return 4;
}

fn writeRectRounded(
    self: *Self,
    v_idx: u16,
    vb: anytype,
    ib: anytype,
    win_dims: geo.ScreenDims,
    rect: geo.Rect,
) !u16 {
    _ = self;
    // approximate (lower-bound) vertices per pixel-length along arc-path.
    // a + b > circumference(a, b) / 4
    const smoothness: f32 = 0.3;

    var transparent = rect.color;
    transparent[3] = 0;

    // center point
    try vb.writeStruct(Vertex{
        .position = win_dims.normalize(
            rect.origin + (rect.size / @as(geo.Vec2, @splat(2))),
        ),
        .normal = .{ 0, 0 },
        .color = rect.color,
    });

    var corner_radii: [4]geo.Vec2 = .{
        rect.radius.top_left,
        rect.radius.top_right,
        rect.radius.bottom_right,
        rect.radius.bottom_left,
    };
    var arc_vertex_count: [4]u16 = undefined;
    for (&corner_radii, &arc_vertex_count) |*rad, *vertex_count| {
        const smooth_corner =
            @reduce(.And, rad.* >= @as(geo.Vec2, @splat(0.5)));
        if (!smooth_corner) {
            rad.* = @splat(0);
        }

        vertex_count.* = @max(
            @as(u16, @intFromFloat(@reduce(.Add, rad.*) * smoothness)),
            1,
        );
    }

    const arc_origins = .{
        // top left
        rect.origin + corner_radii[0],

        // top right
        rect.origin + geo.Vec2{
            rect.size[0] - corner_radii[1][0],
            corner_radii[1][1],
        },

        // bottom right
        rect.origin + rect.size - corner_radii[2],

        // bottom left
        rect.origin + geo.Vec2{
            corner_radii[3][0],
            rect.size[1] - corner_radii[3][1],
        },
    };

    const V = struct {
        base_idx: u16,
        corner_v_count: [4]u16,
        corner_v_count_total: u16,

        const Slot = enum(u8) { inner = 0, outer = 1 };
        const vert_per_point: u16 = std.meta.fields(Slot).len;

        fn idx(v: @This(), slot: Slot, i: u16) u16 {
            const base = v.base_idx + @intFromEnum(slot);
            return base + (i % v.corner_v_count_total) * vert_per_point;
        }
    };
    const v = V{
        .base_idx = v_idx + 1,
        .corner_v_count = arc_vertex_count,
        .corner_v_count_total = @reduce(
            .Add,
            @as(@Vector(4, u16), arc_vertex_count),
        ),
    };

    inline for (
        arc_origins,
        corner_radii,
        v.corner_v_count,
        0..,
    ) |arc_origin, radius, v_count, _c| {
        const corner = @as(u16, @intCast(_c));
        const fcorner = @as(f32, @floatFromInt(corner));

        for (0..v_count) |_s| {
            const step = @as(u16, @intCast(_s));
            const fstep = @as(f32, @floatFromInt(step));
            const fvcount = @as(f32, @floatFromInt(v_count));

            // Avoid division by zero.
            // (theta)
            const t = if (v_count == 1) ( //
                0 //
            ) else ( //
                ((fstep / (fvcount - 1)) + fcorner) * (0.5 * std.math.pi) //
            );

            const normal = geo.Vec2{
                -std.math.cos(t),
                -std.math.sin(t),
            };
            const pos = arc_origin + radius * normal;

            try vb.writeStruct(Vertex{
                .position = win_dims.normalize(pos),
                .normal = win_dims.normalize_delta(geo.Vec2{ -1, -1 } * normal),
                .color = rect.color,
            });

            try vb.writeStruct(Vertex{
                .position = win_dims.normalize(pos),
                .normal = win_dims.normalize_delta(normal),
                .color = transparent,
            });
        }
    }

    for (0..v.corner_v_count_total) |_i| {
        const i = @as(u16, @intCast(_i));

        // inner rounded corner to center
        try ib.writeIntNative(u16, v_idx);
        try ib.writeIntNative(u16, v.idx(.inner, i));
        try ib.writeIntNative(u16, v.idx(.inner, i + 1));

        // outer rounded corner to inner rounded corner
        //
        // quad(outer.i, outer.i + 1, inner.i + 1, inner.i)
        try ib.writeIntNative(u16, v.idx(.outer, i));
        try ib.writeIntNative(u16, v.idx(.outer, i + 1));
        try ib.writeIntNative(u16, v.idx(.inner, i + 1));
        try ib.writeIntNative(u16, v.idx(.inner, i));
        try ib.writeIntNative(u16, v.idx(.outer, i));
        try ib.writeIntNative(u16, v.idx(.inner, i + 1));
    }

    return v.corner_v_count_total * 2 + 1;
}
