const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = @import("std").mem.Allocator;

const config = @import("../config.zig");
const Client = @import("../client/client.zig").Client;
const MessageHandler = @import("../messageHandler.zig").MessageHandler;

const BUFFER_SIZE = config.BUFFER_SIZE;
const MAX_CLIENTS = config.MAX_CLIENTS;

pub const Server = struct {
    allocator: *Allocator,
    address: net.Address,
    maxClients: usize,
    messageBuffer: *[BUFFER_SIZE]u8,
    socket: ?posix.socket_t,

    clients: std.ArrayList(posix.socket_t),
    clientsMutex: std.Thread.Mutex,

    pub fn init(allocator: *Allocator, address: net.Address, maxClients: ?usize, messageBuffer: *[BUFFER_SIZE]u8) Server {
        return Server{
            .allocator = allocator,
            .address = address,
            .maxClients = maxClients orelse MAX_CLIENTS,
            .messageBuffer = messageBuffer,
            .socket = null,
            .clients = .empty,
            .clientsMutex = std.Thread.Mutex{},
        };
    }

    pub fn start(self: *Server) !void {
        var pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&pool, .{ .allocator = self.allocator.*, .n_jobs = self.maxClients });

        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(self.address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &self.address.any, self.address.getOsSockLen());
        try posix.listen(listener, 128);

        var addr: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(net.Address);
        try posix.getsockname(listener, &addr.any, &addr_len);

        std.log.info("[Server]: Listening on port: {}", .{addr.getPort()});

        while (true) {
            var clientAddress: net.Address = undefined;
            var clientAddressLen: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &clientAddress.any, &clientAddressLen, 0) catch |err| {
                std.log.err("[Server]: Failed to accpept new client: {}", .{err});
                continue;
            };

            self.clientsMutex.lock();
            self.clients.append(self.allocator.*, socket) catch {
                self.clientsMutex.unlock();
                std.log.err("[Server]: Failed to add client to list", .{});
                _ = posix.close(socket);
                continue;
            };
            self.clientsMutex.unlock();

            const rand = std.crypto.random;
            const client = Client{
                .socket = socket,
                .address = clientAddress,
                .id = rand.int(u32),
                .username = undefined,
                .username_len = 0,
                .buffer = undefined,
            };

            try pool.spawn(Server.handleClient, .{ self, client });
        }
    }

    fn handleClient(self: *Server, client: Client) void {
        std.log.info("[Server]: Client {} connected with id {}", .{ client.socket, client.id });

        const handler = MessageHandler.init(client.socket);
        const welcome = "[Server] |Thanks for joining| [Server]";
        handler.writeMessage(welcome) catch |err| {
            std.log.err("[Server]: Problem sending init mesage: {}", .{err});
        };

        var message_buffer: [BUFFER_SIZE]u8 = undefined;

        while (true) {
            const message = handler.readMessage(&message_buffer) catch |err| {
                std.log.warn("[Server]: Error reading message from client {}: {}", .{ client.id, err });
                break;
            };

            if (message == null) {
                std.log.info("[Server]: Client {} disconnected", .{client.id});
                break;
            }

            std.log.info("[Server]: Client {} has sent: {s}", .{ client.id, message.? });

            self.clientsMutex.lock();
            MessageHandler.broadcastMessage(self.clients.items, message.?, client.socket);
            self.clientsMutex.unlock();
        }

        _ = posix.close(client.socket);

        // Remove client from list
        self.clientsMutex.lock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            if (self.clients.items[i] == client.socket) {
                _ = self.clients.swapRemove(i);
                break;
            }
            i += 1;
        }
        self.clientsMutex.unlock();
    }
};
