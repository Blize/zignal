const std = @import("std");
const net = @import("net.zig");
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const BUFFER_SIZE = config.BUFFER_SIZE;

/// Reader handles buffered reading from sockets with support for non-blocking I/O.
/// It manages partial message reads and can handle WouldBlock errors gracefully.
pub const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    pub fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
        };
    }

    pub fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    /// Try to read a complete message from the socket.
    /// Returns:
    ///   - ![]const u8 on success (the message bytes)
    ///   - null if no complete message is available yet (WouldBlock or incomplete)
    ///   - error.Closed if the connection is closed (0 bytes read)
    pub fn readMessage(self: *Reader, socket: net.socket_t) !?[]const u8 {
        var buf = self.buf;

        while (true) {
            // Try to extract a complete message from our buffer
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }

            // No complete message yet, try to read more from the socket
            const pos = self.pos;
            const n = net.read(socket, buf[pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // No data available right now, return null
                    return null;
                },
                else => return err,
            };

            if (n == 0) {
                // Connection closed
                return error.Closed;
            }

            self.pos = pos + n;
        }
    }

    /// Read a complete message from the socket (blocking)
    /// Returns the message bytes or null on disconnect
    pub fn readClientMessage(socket: net.socket_t, buffer: *[BUFFER_SIZE]u8) !?[]u8 {
        var len_buf: [4]u8 = undefined;
        var len_read: usize = 0;

        // Read the 4-byte length prefix
        while (len_read < 4) {
            const n = try net.read(socket, len_buf[len_read..]);
            if (n == 0) {
                return null; // Connection closed
            }
            len_read += n;
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .little);
        if (msg_len > BUFFER_SIZE) {
            return error.MessageTooLarge;
        }

        var total_read: usize = 0;
        while (total_read < msg_len) {
            const chunk = try net.read(socket, buffer[total_read..msg_len]);
            if (chunk == 0) {
                return null; // Connection closed mid-message
            }
            total_read += chunk;
        }

        return buffer[0..msg_len];
    }

    /// Check if we have a complete buffered message available
    /// Returns the message if available, or null if we need more data
    fn bufferedMessage(self: *Reader) !?[]const u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];

        // Need at least 4 bytes for the length prefix
        if (unprocessed.len < 4) {
            try self.ensureSpace(4 - unprocessed.len);
            return null;
        }

        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);

        // Total length: 4 bytes for prefix + message content
        const total_len = message_len + 4;

        // Check if we have the complete message
        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        // We have a complete message. Mark it as consumed and return it.
        self.start += total_len;
        return unprocessed[4..total_len];
    }

    /// Ensure we have enough space in the buffer to accommodate `space` bytes
    /// This may compact the buffer by moving unprocessed data to the beginning
    fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
        const buf = self.buf;
        if (buf.len < space) {
            return error.BufferTooSmall;
        }

        const start = self.start;
        const spare = buf.len - start;
        if (spare >= space) {
            return;
        }

        // Compact the buffer: move unprocessed data to the beginning
        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};
