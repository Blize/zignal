const std = @import("std");
const BUFFER_SIZE = @import("../config.zig").BUFFER_SIZE;
const posix = std.posix;
const Writer = @import("../writer.zig").Writer;
const Reader = @import("../reader.zig").Reader;
const TuiClient = @import("tui.zig").TuiClient;

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
        // Use TUI mode
        const allocator = std.heap.c_allocator;
        const username = self.username[0..self.username_len];

        var tui = try TuiClient.init(allocator, self.socket, username);
        defer tui.deinit();

        try tui.run();
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

        const writer = Writer.init(socket);
        try writer.writeMessage(formatted_message[0..formatted_len]);
    }

    fn receiveMessages(self: Client) void {
        var stdout_buffer: [1024]u8 = undefined;
        var stdoutWrtier = std.fs.File.stdout().writer(&stdout_buffer);

        const writer: *std.Io.Writer = &stdoutWrtier.interface;

        var message_buffer: [BUFFER_SIZE]u8 = undefined;

        while (true) {
            const message = Reader.readClientMessage(self.socket, &message_buffer) catch |err| {
                std.log.warn("[Client]: Error reading message: {}", .{err});
                break;
            };

            if (message == null) {
                std.log.warn("[Client]: Disconnected from server", .{});
                break;
            }

            writer.print("{s}\n", .{message.?}) catch continue;
            writer.flush() catch {};
            writer.print("Message: ", .{}) catch continue;
            writer.flush() catch {};
        }

        posix.close(self.socket);
    }
    fn checkForCommands(command: []u8) CommandResult {
        var stdout_buffer: [8]u8 = undefined;
        var stdoutWrtier = std.fs.File.stdout().writer(&stdout_buffer);

        const writer: *std.Io.Writer = &stdoutWrtier.interface;
        if (std.mem.eql(u8, command, "\\exit")) {
            return .handledExit;
        }
        if (std.mem.eql(u8, command, "\\clear")) {
            writer.print("\x1b[2J\x1b[H", .{}) catch {};
            writer.flush() catch {};
            return .handledContinue;
        }

        return .noCommand;
    }
};
