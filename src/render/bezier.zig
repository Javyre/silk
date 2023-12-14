const std = @import("std");
const geo = @import("../geo.zig");

/// Converts a cubic bezier curve to a quadratic bezier curve.
///
/// Assumes the curve roughly corresponds to a degree-elevated
/// quadratic bezier curve.
pub fn cubic_to_quadratic_oneshot(
    curve: [4]geo.Vec2,
) struct { curve: [3]geo.Vec2, mse: f32 } {
    // We work backward from the degree elevation formula
    const p1_a = (geo.Vec2{ 3, 3 } * curve[1] - curve[0]) / geo.Vec2{ 2, 2 };
    const p1_b = (geo.Vec2{ 3, 3 } * curve[2] - curve[3]) / geo.Vec2{ 2, 2 };

    // Mean Squared Error
    const mse = @reduce(.Add, (p1_a - p1_b) * (p1_a - p1_b)) / 2.0;

    const p1_avg = (p1_a + p1_b) / geo.Vec2{ 2, 2 };

    return .{ .curve = .{ curve[0], p1_avg, curve[3] }, .mse = mse };
}

/// Splits a cubic bezier curve into two parts.
pub fn split_cubic_2(curve: [4]geo.Vec2, t: f32) [7]geo.Vec2 {
    const p0, const p1, const p2, const p3 = curve;
    const t2d = geo.Vec2{ t, t };

    const p01 = std.math.lerp(p0, p1, t2d);
    const p12 = std.math.lerp(p1, p2, t2d);
    const p23 = std.math.lerp(p2, p3, t2d);

    const p012 = std.math.lerp(p01, p12, t2d);
    const p123 = std.math.lerp(p12, p23, t2d);

    const p0123 = std.math.lerp(p012, p123, t2d);

    return .{ p0, p01, p012, p0123, p123, p23, p3 };
}

const CubicPartsIterator = struct {
    curve: [4]geo.Vec2,
    n_parts: u16,

    pub fn next(iter: *CubicPartsIterator) ?[4]geo.Vec2 {
        if (iter.n_parts == 0) {
            return null;
        }
        const split = split_cubic_2(
            iter.curve,
            1.0 / @as(f32, @floatFromInt(iter.n_parts)),
        );
        iter.curve = split[3..].*;
        iter.n_parts -= 1;
        return split[0..4].*;
    }
};

pub fn iter_split_cubic_n(curve: [4]geo.Vec2, n_parts: u16) CubicPartsIterator {
    return CubicPartsIterator{ .curve = curve, .n_parts = n_parts };
}

/// Converts a cubic bezier curve to a quadratic bezier curve.
///
/// If the tolerace can not be met with the given points_store space, the
/// closest attempt so far is returned.
pub fn cubic_to_quadratic(
    points_store: []geo.Vec2,
    curve: [4]geo.Vec2,
    tolerance: f32,
) []geo.Vec2 {
    var pts = struct {
        pts: []geo.Vec2,
        points_store: []geo.Vec2,
        fn append_point(pts: *@This(), p: geo.Vec2) !void {
            if (pts.pts.len == pts.points_store.len) {
                return error.OutOfMemory;
            }

            pts.pts.len += 1;
            pts.pts[pts.pts.len - 1] = p;
        }
    }{
        .pts = points_store[0..0],
        .points_store = points_store,
    };

    if (std.debug.runtime_safety)
        std.debug.assert(points_store.len >= 3);

    // max parts given the points_store size
    const max_parts = (points_store.len - 1) / 2;

    pts.append_point(curve[0]) catch unreachable;

    for (1..max_parts + 1) |n_parts| {
        pts.pts.len = 1;

        var total_error: f32 = 0.0;
        var parts_iter = iter_split_cubic_n(curve, @as(u16, @intCast(n_parts)));
        while (parts_iter.next()) |part| {
            const quadratic = cubic_to_quadratic_oneshot(part);

            total_error += quadratic.mse;
            for (quadratic.curve[1..]) |p| {
                pts.append_point(p) catch unreachable;
            }
        }

        const mean_error = total_error / @as(f32, @floatFromInt(n_parts));
        if (mean_error <= tolerance) {
            break;
        }
    }

    return pts.pts;
}
