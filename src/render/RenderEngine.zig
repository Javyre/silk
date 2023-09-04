const std = @import("std");
const core = @import("core");
const gpu = core.gpu;

const geo = @import("geo.zig");
const RectPass = @import("RectPass.zig");

const Self = @This();

rect_pass: RectPass,
rect_buffer: std.ArrayList(geo.Rect),

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .rect_pass = RectPass.init(),
        .rect_buffer = std.ArrayList(geo.Rect).init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    defer self.rect_buffer.deinit();
    defer self.rect_pass.deinit();
}

pub fn writeRect(self: *Self, rect: geo.Rect) !void {
    try self.rect_buffer.append(rect);
}

pub fn flushScene(self: *Self, output: *gpu.Texture) void {
    self.rect_pass.draw(output, self.rect_buffer.items);
    self.rect_buffer.clearRetainingCapacity();
}
