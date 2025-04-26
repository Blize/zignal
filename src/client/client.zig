const std = @import("std");
const BUFFER_SIZE = @import("../config.zig").BUFFER_SIZE;
const posix = std.posix;

const CommandResult = enum {
    handledContinue,
    handledExit,
    noCommand,
};

pub const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    id: u32,
    username: [24]?u8,
    buffer: [BUFFER_SIZE]u8,

    pub fn startClient(self: *Client) !void {
        const stdout = std.io.getStdOut().writer();
        const stdin = std.io.getStdIn().reader();
        var line_buf: [BUFFER_SIZE]u8 = undefined;

        // Start receive thread
        var thread = try std.Thread.spawn(.{}, Client.receiveMessages, .{self.*});
        thread.detach();

        while (true) {
            stdout.print("Message: ", .{}) catch continue;

            const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch continue;
            if (line == null) break;
            const message = line.?;

            const result = Client.checkForCommands(message);
            switch (result) {
                .handledContinue => continue,
                .handledExit => break,
                .noCommand => {},
            }

            Client.sendMessage(self.socket, message) catch |err| {
                std.log.err("Failed to send message: {}", .{err});
                break;
            };
        }

        _ = posix.close(self.socket);
    }

    fn sendMessage(socket: posix.socket_t, message: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(message.len), .little);

        const vec = [_]posix.iovec_const{
            .{ .base = &len_buf, .len = 4 },
            .{ .base = message.ptr, .len = message.len },
        };

        _ = try posix.writev(socket, &vec);
    }

    fn receiveMessages(self: Client) void {
        const stdout = std.io.getStdOut().writer();

        while (true) {
            // Step 1: Read 4 bytes for length
            var len_buf: [4]u8 = undefined;
            const len_read = posix.read(self.socket, &len_buf) catch {
                std.log.warn("[Client]: Disconnected from server", .{});
                break;
            };

            if (len_read != 4) {
                std.log.warn("[Client]: Partial length header received: {}", .{len_read});
                break;
            }

            const msg_len = std.mem.readInt(u32, &len_buf, .little);
            if (msg_len > BUFFER_SIZE) {
                std.log.err("[Client]: Message too long: {}", .{msg_len});
                break;
            }

            // Step 2: Read message content
            var msg: [BUFFER_SIZE]u8 = undefined;
            var total_read: usize = 0;

            while (total_read < msg_len) {
                const chunk = posix.read(self.socket, msg[total_read..msg_len]) catch {
                    std.log.warn("[Client]: Error reading message content", .{});
                    break;
                };
                if (chunk == 0) break;
                total_read += chunk;
            }

            if (total_read != msg_len) {
                std.log.warn("[Client]: Incomplete message received", .{});
                break;
            }

            stdout.print("\nMessage: {s}", .{msg[0..msg_len]}) catch continue;
            stdout.print("\nMessage: ", .{}) catch continue;
        }

        posix.close(self.socket);
    }
    fn checkForCommands(command: []u8) CommandResult {
        const stdout = std.io.getStdOut().writer();
        if (std.mem.eql(u8, command, "\\exit")) {
            return .handledExit;
        }
        if (std.mem.eql(u8, command, "\\clear")) {
            stdout.print("\x1b[2J\x1b[H", .{}) catch {};
            return .handledContinue;
        }
        return .noCommand;
    }
};
