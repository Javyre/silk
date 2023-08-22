const std = @import("std");
const core = @import("core");
const gpu = core.gpu;

pub const GPUBuffer = struct {
    buffer: *gpu.Buffer,
    len: u64 = 0,

    const Self = @This();
    const Writer = std.io.Writer(*Self, WriteError, write);

    pub const WriteError = error{NoSpaceLeft};

    fn write(self: *Self, bytes: []const u8) WriteError!usize {
        if (self.buffer.getSize() < self.len + bytes.len)
            return error.NoSpaceLeft;

        core.device.getQueue().writeBuffer(self.buffer, self.len, bytes);
        self.len += bytes.len;
        return bytes.len;
    }

    pub fn writer(self: *Self) Writer {
        return Writer{ .context = self };
    }

    pub fn destroy(self: *Self) void {
        self.buffer.destroy();
    }
};
