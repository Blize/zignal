const std = @import("std");
const posix = std.posix;

pub const Writer = struct {
    socket: posix.socket_t,

    pub fn init(socket: posix.socket_t) Writer {
        return Writer{
            .socket = socket,
        };
    }

    /// Write a message to this socket with length prefix
    pub fn writeMessage(self: Writer, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        const vec = [_]posix.iovec_const{
            .{ .base = &len_buf, .len = 4 },
            .{ .base = message.ptr, .len = message.len },
        };

        _ = try posix.writev(self.socket, &vec);
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
        Writer.writeToSocket(socket, message) catch |err| {
            std.log.warn("[Writer]: Failed to write to socket: {}", .{err});
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
                std.log.warn("[Writer]: Failed to broadcast to socket: {}", .{err});
            };
        }
    }

    /// Broadcast message to all sockets in the list
    pub fn broadcastToAll(sockets: []const posix.socket_t, message: []const u8) void {
        Writer.broadcastMessage(sockets, message, null);
    }
};
