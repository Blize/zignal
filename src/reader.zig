const std = @import("std");
const posix = std.posix;
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

    pub fn readMessage(self: *Reader, socket: posix.socket_t) !?[]const u8 {
        var buf = self.buf;

        while (true) {
            if (try self.bufferedMessage()) |msg| {
                return msg;
            }

            const pos = self.pos;
            const n = posix.read(socket, buf[pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    return null;
                },
                else => return err,
            };

            if (n == 0) {
                return error.Closed;
            }

            self.pos = pos + n;
        }
    }

    pub fn readClientMessage(socket: posix.socket_t, buffer: *[BUFFER_SIZE]u8) !?[]u8 {
        var len_buf: [4]u8 = undefined;
        const len_read = try posix.read(socket, &len_buf);

        if (len_read == 0) {
            return null;
        }

        if (len_read != 4) {
            return error.PartialLengthRead;
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .little);
        if (msg_len > BUFFER_SIZE) {
            return error.MessageTooLarge;
        }

        var total_read: usize = 0;
        while (total_read < msg_len) {
            const chunk = try posix.read(socket, buffer[total_read..msg_len]);
            if (chunk == 0) {
                return null;
            }
            total_read += chunk;
        }

        if (total_read != msg_len) {
            return error.IncompleteMessage;
        }

        return buffer[0..msg_len];
    }

    fn bufferedMessage(self: *Reader) !?[]const u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];

        if (unprocessed.len < 4) {
            try self.ensureSpace(4 - unprocessed.len);
            return null;
        }

        const message_len = std.mem.readInt(u32, unprocessed[0..4], .little);
        const total_len = message_len + 4;

        if (unprocessed.len < total_len) {
            try self.ensureSpace(total_len);
            return null;
        }

        self.start += total_len;
        return unprocessed[4..total_len];
    }

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

        const unprocessed = buf[start..self.pos];
        std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
        self.start = 0;
        self.pos = unprocessed.len;
    }
};
