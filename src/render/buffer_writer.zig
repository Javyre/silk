const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;

pub fn GArrayList(comptime T: type) type {
    return struct {
        const Error = GPUBuffer.WriteError;

        buffer: GPUBuffer,

        pub fn initCapacity(desc: struct {
            label: ?[*:0]const u8 = null,
            usage: gpu.Buffer.UsageFlags,
            capacity: u64,
        }) @This() {
            return .{ .buffer = GPUBuffer{
                .buffer = core.device.createBuffer(&.{
                    .size = desc.capacity * @sizeOf(T),
                    .usage = desc.usage,
                    .label = desc.label,
                }),
            } };
        }

        pub fn deinit(self: *@This()) void {
            self.buffer.destroy();
        }

        pub fn writeOne(self: *@This(), value: T) Error!void {
            const written = try self.buffer.write(std.mem.asBytes(&value));
            std.debug.assert(written == @sizeOf(T));
        }

        pub fn write(self: *@This(), values: []const T) Error!void {
            const written = try self.buffer.write(std.mem.sliceAsBytes(values));
            std.debug.assert(written == values.len * @sizeOf(T));
        }

        /// Get the buffers current physical size in bytes.
        pub fn getSize(self: *const @This()) u64 {
            return self.buffer.buffer.getSize();
        }

        /// Get the current number of elements in the buffer.
        pub fn getLen(self: *const @This()) u64 {
            const bytes = self.buffer.len;

            if (std.debug.runtime_safety)
                std.debug.assert(bytes % @sizeOf(T) == 0);

            return bytes / @sizeOf(T);
        }

        pub fn getRawBuffer(self: *const @This()) *gpu.Buffer {
            return self.buffer.buffer;
        }

        pub fn clear(self: *@This()) void {
            self.buffer.len = 0;
        }

        // readAt()?
    };
}

/// DEPRECATED: use `GArrayList` instead
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
