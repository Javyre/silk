const std = @import("std");

// (x, y) or (w, h)
pub const Vec2 = @Vector(2, f32);
// (x, y, z, w) or (r, g, b, a)
pub const Vec4 = @Vector(4, f32);

pub const ScreenDims = struct {
    dims: Vec2,

    pub fn normalize(self: ScreenDims, p: Vec2) Vec2 {
        return ( //
            ((@as(Vec2, @splat(2)) * p / self.dims) -
            @as(Vec2, @splat(1))) * @as(Vec2, .{ 1, -1 }) //
        );
    }

    pub fn normalize_delta(self: ScreenDims, p: Vec2) Vec2 {
        return ( //
            (@as(Vec2, @splat(2)) * p / self.dims) * @as(Vec2, .{ 1, -1 }) //
        );
    }
};

pub const Rect = struct {
    origin: Vec2,
    size: Vec2,
    color: Vec4,
    radius: Rect.Radius = .{},

    pub const Radius = struct {
        top_left: Vec2 = @as(Vec2, @splat(0)),
        top_right: Vec2 = @as(Vec2, @splat(0)),
        bottom_right: Vec2 = @as(Vec2, @splat(0)),
        bottom_left: Vec2 = @as(Vec2, @splat(0)),

        pub fn isZero(self: Rect.Radius) bool {
            for (std.mem.asBytes(&self)) |byte| {
                if (byte != 0) {
                    return false;
                }
            }
            return true;
        }
    };

    pub fn uniformRadius(radius: f32) Rect.Radius {
        return .{
            .top_left = @as(Vec2, @splat(radius)),
            .top_right = @as(Vec2, @splat(radius)),
            .bottom_right = @as(Vec2, @splat(radius)),
            .bottom_left = @as(Vec2, @splat(radius)),
        };
    }
};
