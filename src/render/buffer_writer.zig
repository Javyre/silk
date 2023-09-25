const std = @import("std");
const core = @import("mach-core");
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

        // NOTE: for some reason, even for uint16 bufffers we need to write a
        //       multiple of 4 bytes at a time. So we pad the buffer with zeroes
        const remainder = @rem(bytes.len, 4);
        if (remainder != 0) {
            const cutoff = bytes.len - remainder;

            core.device.getQueue().writeBuffer(
                self.buffer,
                self.len,
                bytes[0..cutoff],
            );

            var buff = std.mem.zeroes([4]u8);
            for (bytes[cutoff..], 0..) |b, i| {
                buff[i] = b;
            }

            core.device.getQueue().writeBuffer(
                self.buffer,
                self.len + cutoff,
                &buff,
            );
        } else {
            core.device.getQueue().writeBuffer(self.buffer, self.len, bytes);
        }

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
