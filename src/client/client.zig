const std = @import("std");
const posix = std.posix;
const TuiClient = @import("tui.zig").TuiClient;
const utils = @import("../utils.zig");

pub const Command = enum {
    exit,
    clear,
    help,

    pub fn parse(message: []const u8) ?Command {
        if (std.mem.eql(u8, message, "/exit")) return .exit;
        if (std.mem.eql(u8, message, "/clear")) return .clear;
        if (std.mem.eql(u8, message, "/help")) return .help;
        return null;
    }

    pub fn helpText() []const u8 {
        return "[Help] Commands: /exit, /clear, /help";
    }
};

pub const ChatMessage = struct {
    content: []const u8,
    timestamp: i64,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, content: []const u8) !ChatMessage {
        const owned = try allocator.dupe(u8, content);
        return .{
            .content = owned,
            .timestamp = std.time.timestamp(),
            .allocator = allocator,
        };
    }

    pub fn destroy(self: *ChatMessage) void {
        self.allocator.free(self.content);
    }

    pub fn getTimestampStr(self: *const ChatMessage, buf: []u8) []const u8 {
        return utils.time.formatTimestamp(self.timestamp, buf);
    }
};

pub const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    id: u32,
    username: [24]u8,
    username_len: usize,

    pub fn startClient(self: *Client) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const username = self.username[0..self.username_len];

        var tui = try TuiClient.init(allocator, self.socket, self.address, username);
        defer tui.deinit();

        try tui.run();
    }
};
