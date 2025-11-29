const std = @import("std");
const posix = std.posix;
const config = @import("./config.zig");

const BUFFER_SIZE = config.BUFFER_SIZE;

pub const MessageHandler = struct {
    socket: posix.socket_t,

    pub fn init(socket: posix.socket_t) MessageHandler {
        return MessageHandler{
            .socket = socket,
        };
    }

    /// Write a message to a single socket with length prefix
    pub fn writeMessage(self: MessageHandler, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        const vec = [_]posix.iovec_const{
            .{ .base = &len_buf, .len = 4 },
            .{ .base = message.ptr, .len = message.len },
        };

        _ = try posix.writev(self.socket, &vec);
    }

    /// Write a message to a single socket with error handling
    pub fn writeMessageSafe(self: MessageHandler, message: []const u8) bool {
        self.writeMessage(message) catch |err| {
            std.log.warn("[MessageHandler]: Failed to write message: {}", .{err});
            return false;
        };
        return true;
    }

    /// Read a message from socket with length prefix
    /// Returns the message bytes read or null on disconnect/error
    pub fn readMessage(self: MessageHandler, buffer: *[BUFFER_SIZE]u8) !?[]u8 {
        var len_buf: [4]u8 = undefined;
        const len_read = posix.read(self.socket, &len_buf) catch |err| {
            return err;
        };

        if (len_read == 0) {
            return null; // Connection closed
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
            const chunk = posix.read(self.socket, buffer[total_read..msg_len]) catch |err| {
                return err;
            };
            if (chunk == 0) {
                return null; // Connection closed mid-message
            }
            total_read += chunk;
        }

        if (total_read != msg_len) {
            return error.IncompleteMessage;
        }

        return buffer[0..msg_len];
    }

    /// Write to a specific socket (useful for broadcasting)
    pub fn writeToSocket(socket: posix.socket_t, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        const vec = [_]posix.iovec_const{
            .{ .base = &len_buf, .len = 4 },
            .{ .base = message.ptr, .len = message.len },
        };

        _ = try posix.writev(socket, &vec);
    }

    /// Write to a specific socket with error handling
    pub fn writeToSocketSafe(socket: posix.socket_t, message: []const u8) bool {
        MessageHandler.writeToSocket(socket, message) catch |err| {
            std.log.warn("[MessageHandler]: Failed to write to socket: {}", .{err});
            return false;
        };
        return true;
    }

    /// Broadcast message to multiple sockets (excluding sender)
    pub fn broadcastMessage(sockets: []const posix.socket_t, message: []const u8, excludeSocket: ?posix.socket_t) void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        for (sockets) |socket| {
            if (excludeSocket) |exclude| {
                if (socket == exclude) continue;
            }

            const vec = [_]posix.iovec_const{
                .{ .base = &len_buf, .len = 4 },
                .{ .base = message.ptr, .len = message.len },
            };

            _ = posix.writev(socket, &vec) catch |err| {
                std.log.warn("[MessageHandler]: Failed to broadcast to socket: {}", .{err});
            };
        }
    }

    /// Broadcast message to all sockets in the list
    pub fn broadcastToAll(sockets: []const posix.socket_t, message: []const u8) void {
        MessageHandler.broadcastMessage(sockets, message, null);
    }
};
