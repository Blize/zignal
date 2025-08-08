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
    username: [24]u8,
    username_len: usize,
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

            Client.sendMessage(self.socket, message, self.username[0..self.username_len]) catch |err| {
                std.log.err("Failed to send message: {}", .{err});
                break;
            };
        }

        _ = posix.close(self.socket);
    }

    fn sendMessage(socket: posix.socket_t, message: []u8, username: []const u8) !void {
        var formatted_message: [BUFFER_SIZE]u8 = undefined;
        var formatted_len: usize = 0;

        // Use "Anonymous" if no username is provided
        const display_username = if (username.len > 0) username else "Anonymous";

        // Format message as "username: message"
        if (std.fmt.bufPrint(formatted_message[0..], "{s}: {s}", .{ display_username, message })) |formatted| {
            formatted_len = formatted.len;
        } else |_| {
            // If formatting fails, just send the original message
            @memcpy(formatted_message[0..message.len], message);
            formatted_len = message.len;
        }

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(formatted_len), .little);

        const vec = [_]posix.iovec_const{
            .{ .base = &len_buf, .len = 4 },
            .{ .base = formatted_message[0..formatted_len].ptr, .len = formatted_len },
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

            const message = msg[0..msg_len];
            stdout.print("{s}\n", .{message}) catch continue;
            stdout.print("Message: ", .{}) catch continue;
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
