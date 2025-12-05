const std = @import("std");
const net = @import("net.zig");

pub const Writer = struct {
    socket: net.socket_t,

    pub fn init(socket: net.socket_t) Writer {
        return Writer{
            .socket = socket,
        };
    }

    /// Write a message to this socket with length prefix
    pub fn writeMessage(self: Writer, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        // Write length prefix
        try net.writeAll(self.socket, &len_buf);
        // Write message
        try net.writeAll(self.socket, message);
    }

    /// Write a message to this socket with error handling
    pub fn writeMessageSafe(self: Writer, message: []const u8) bool {
        self.writeMessage(message) catch |err| {
            std.log.warn("[Writer]: Failed to write message: {}", .{err});
            return false;
        };
        return true;
    }

    /// Write to a specific socket (useful for broadcasting)
    pub fn writeToSocket(socket: net.socket_t, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        // Write length prefix
        try net.writeAll(socket, &len_buf);
        // Write message
        try net.writeAll(socket, message);
    }

    /// Write to a specific socket with error handling
    pub fn writeToSocketSafe(socket: net.socket_t, message: []const u8) bool {
        Writer.writeToSocket(socket, message) catch |err| {
            std.log.warn("[Writer]: Failed to write to socket: {}", .{err});
            return false;
        };
        return true;
    }

    /// Broadcast message to multiple sockets (excluding sender)
    pub fn broadcastMessage(sockets: []const net.socket_t, message: []const u8, excludeSocket: ?net.socket_t) void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        for (sockets) |socket| {
            if (excludeSocket) |exclude| {
                if (socket == exclude) continue;
            }

            net.writeAll(socket, &len_buf) catch |err| {
                std.log.warn("[Writer]: Failed to broadcast length to socket: {}", .{err});
                continue;
            };
            net.writeAll(socket, message) catch |err| {
                std.log.warn("[Writer]: Failed to broadcast message to socket: {}", .{err});
                continue;
            };
        }
    }

    /// Broadcast message to all sockets in the list
    pub fn broadcastToAll(sockets: []const net.socket_t, message: []const u8) void {
        Writer.broadcastMessage(sockets, message, null);
    }
};
