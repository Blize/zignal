const std = @import("std");
const posix = std.posix;
const TuiClient = @import("tui.zig").TuiClient;

pub const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    id: u32,
    username: [24]u8,
    username_len: usize,

    pub fn startClient(self: *Client) !void {
        const allocator = std.heap.c_allocator;
        const username = self.username[0..self.username_len];

        var tui = try TuiClient.init(allocator, self.socket, username);
        defer tui.deinit();

        try tui.run();
    }
};
