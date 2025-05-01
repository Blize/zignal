const std = @import("std");
const net = std.net;
const posix = std.posix;

const Server = @import("server/server.zig").Server;
const Client = @import("client/client.zig").Client;
const config = @import("config.zig");
const printHelp = @import("utils.zig").printHelp;

pub fn main() !void {
    var allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp(args[0]);
        return error.MissingArguments;
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        printHelp(args[0]);
        return;
    }

    if (std.mem.eql(u8, args[1], "server")) {
        const address = try net.Address.parseIp4("0.0.0.0", 0);
        var buffer: [config.BUFFER_SIZE]u8 = undefined;
        var server = Server.init(&allocator, address, config.MAX_CLIENTS, &buffer);
        try server.start();
    } else if (std.mem.eql(u8, args[1], "client")) {
        if (args.len != 4) {
            printHelp(args[0]);
            return error.InvalidArguments;
        }

        const ip = args[2];
        const port = try std.fmt.parseInt(u16, args[3], 10);
        const address = try net.Address.parseIp4(ip, port);
        const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        try posix.connect(socket, &address.any, address.getOsSockLen());

        var client = Client{
            .socket = socket,
            .address = address,
            .id = std.crypto.random.int(u32),
            .username = undefined,
            .buffer = undefined,
        };
        try client.startClient();
    } else {
        std.debug.print("Invalid option. Use 'server' or 'client'.\n", .{});
        printHelp(args[0]);
        return error.InvalidArguments;
    }
}
