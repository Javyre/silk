const std = @import("std");
const core = @import("mach").core;
const gpu = core.gpu;

const geo = @import("../geo.zig");
const FontManager = @import("../FontManager.zig");
const TextPass = @import("TextPass.zig");
const RectPass = @import("RectPass.zig");

const Self = @This();

text_pass: TextPass,
text_buffer: std.ArrayList(TextPass.Text),
rect_pass: RectPass,
rect_buffer: std.ArrayList(geo.Rect),

pub fn init(alloc: std.mem.Allocator, font_manager: *FontManager) !Self {
    return .{
        .text_pass = try TextPass.init(alloc, font_manager),
        .text_buffer = std.ArrayList(TextPass.Text).init(alloc),
        .rect_pass = RectPass.init(),
        .rect_buffer = std.ArrayList(geo.Rect).init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    defer self.text_pass.deinit() catch unreachable;
    defer self.text_buffer.deinit();
    defer self.rect_pass.deinit();
    defer self.rect_buffer.deinit();
}

pub fn writeRect(self: *Self, rect: geo.Rect) !void {
    try self.rect_buffer.append(rect);
}

// TODO: This is a temporary api for text rendering. It should be reworked
//       to be actually efficient (and more sensical).
// NOTE: Shaping and Rendering is the responsibility of the render engine but
//       Text LAYOUT is the responsibility of the caller.
pub fn writeText(
    self: *Self,
    pos: geo.Vec2,
    text: []const u8,
    font_idx: u16,
    font_size: f32,
) !void {
    try self.text_buffer.append(
        .{
            .pos = pos,
            .text = text,
            .font_idx = font_idx,
            .font_size = font_size,
        },
    );
}

pub fn flushScene(self: *Self, output: *gpu.Texture) !void {
    self.rect_pass.draw(output, self.rect_buffer.items);
    self.rect_buffer.clearRetainingCapacity();
    try self.text_pass.draw(output, self.text_buffer.items);
    self.text_buffer.clearRetainingCapacity();
}
