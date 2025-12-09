const std = @import("std");
const net = std.net;
const posix = std.posix;

const Server = @import("server/server.zig").Server;
const Client = @import("client/client.zig").Client;
const config = @import("config.zig");
const printHelp = @import("utils.zig").printHelp;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
        var port: u16 = 8080;
        var max_clients: usize = config.MAX_CLIENTS - 1;

        var arg_index: usize = 2;
        while (arg_index < args.len) {
            if (std.mem.eql(u8, args[arg_index], "-p") or std.mem.eql(u8, args[arg_index], "--port")) {
                if (arg_index + 1 >= args.len) {
                    std.debug.print("Error: Port flag requires a value.\n", .{});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                }
                port = std.fmt.parseInt(u16, args[arg_index + 1], 10) catch {
                    std.debug.print("Error: Invalid port number '{s}'.\n", .{args[arg_index + 1]});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                };
                arg_index += 2;
            } else if (std.mem.eql(u8, args[arg_index], "-s") or std.mem.eql(u8, args[arg_index], "--size")) {
                if (arg_index + 1 >= args.len) {
                    std.debug.print("Error: Size flag requires a value.\n", .{});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                }
                const size = std.fmt.parseInt(usize, args[arg_index + 1], 10) catch {
                    std.debug.print("Error: Invalid size value '{s}'.\n", .{args[arg_index + 1]});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                };
                if (size == 0 or size > 4095) {
                    std.debug.print("Error: Size must be between 1 and 4095.\n", .{});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                }
                max_clients = size;
                arg_index += 2;
            } else {
                std.debug.print("Error: Unknown server option '{s}'.\n", .{args[arg_index]});
                printHelp(args[0]);
                return error.InvalidArguments;
            }
        }

        const address = try net.Address.parseIp4("0.0.0.0", port);
        var server = try Server.init(allocator, address, max_clients);
        defer server.deinit();
        try server.start();
    } else if (std.mem.eql(u8, args[1], "client")) {
        var username: ?[]const u8 = null;
        var ip: ?[]const u8 = null;
        var port: ?u16 = null;

        var arg_index: usize = 2;

        while (arg_index < args.len) {
            if (std.mem.eql(u8, args[arg_index], "-u") or std.mem.eql(u8, args[arg_index], "--username")) {
                if (arg_index + 1 >= args.len) {
                    std.debug.print("Error: Username flag requires a value.\n", .{});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                }
                username = args[arg_index + 1];
                arg_index += 2;
            } else if (ip == null) {
                ip = args[arg_index];
                arg_index += 1;
            } else if (port == null) {
                port = std.fmt.parseInt(u16, args[arg_index], 10) catch {
                    std.debug.print("Error: Invalid port number '{s}'.\n", .{args[arg_index]});
                    printHelp(args[0]);
                    return error.InvalidArguments;
                };
                arg_index += 1;
            } else {
                std.debug.print("Error: Too many arguments.\n", .{});
                printHelp(args[0]);
                return error.InvalidArguments;
            }
        }

        if (ip == null or port == null) {
            std.debug.print("Error: Missing required arguments (IP and PORT).\n", .{});
            printHelp(args[0]);
            return error.InvalidArguments;
        }

        const address = try net.Address.parseIp4(ip.?, port.?);
        const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        try posix.connect(socket, &address.any, address.getOsSockLen());

        var client = Client{
            .socket = socket,
            .address = address,
            .id = std.crypto.random.int(u32),
            .username = undefined,
            .username_len = 0,
        };

        if (username) |user| {
            if (user.len > 23) {
                std.debug.print("Error: Username too long (max 23 characters).\n", .{});
                return error.InvalidArguments;
            }
            @memset(&client.username, 0);
            @memcpy(client.username[0..user.len], user);
            client.username_len = user.len;
        }

        try client.startClient();
    } else {
        std.debug.print("Invalid option. Use 'server' or 'client'.\n", .{});
        printHelp(args[0]);
        return error.InvalidArguments;
    }
}
