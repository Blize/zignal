const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = @import("std").mem.Allocator;

const config = @import("../config.zig");
const Client = @import("../client/client.zig").Client;

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
            .clients = std.ArrayList(posix.socket_t).init(allocator.*),
            .clientsMutex = std.Thread.Mutex{},
        };
    }

    pub fn start(self: *Server) !void {
        std.log.info("[Server]: Starting Server: {}\n", .{self.address.getPort()});

        var pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&pool, .{ .allocator = self.allocator.*, .n_jobs = self.maxClients });

        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(self.address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &self.address.any, self.address.getOsSockLen());
        try posix.listen(listener, 128);

        while (true) {
            var clientAddress: net.Address = undefined;
            var clientAddressLen: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &clientAddress.any, &clientAddressLen, 0) catch |err| {
                std.debug.print("error accept: {}\n", .{err});
                continue;
            };

            self.clientsMutex.lock();
            self.clients.append(socket) catch {
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
                .buffer = undefined,
            };

            try pool.spawn(Server.handleClient, .{ self, client });
        }
    }

    fn handleClient(self: *Server, client: Client) void {
        std.log.info("[Server]: Client {} connected with id {}", .{ client.socket, client.id });

        while (true) {
            var lenBuf: [4]u8 = undefined;
            const lenRead = posix.read(client.socket, &lenBuf) catch |err| {
                std.log.warn("[Server]: Failed to read length: {}", .{err});
                break;
            };
            if (lenRead == 0) {
                std.log.info("[Server]: Client {} disconnected", .{client.id});
                break;
            }
            if (lenRead != 4) {
                std.log.warn("[Server]: Partial length read from client {}: {} bytes", .{ client.id, lenRead });
                break;
            }

            const msgLen = std.mem.readInt(u32, &lenBuf, .little);
            if (msgLen > BUFFER_SIZE) {
                std.log.err("[Server]: Client {} sent too large message: {}", .{ client.id, msgLen });
                break;
            }

            var message: [BUFFER_SIZE]u8 = undefined;
            var totalRead: usize = 0;
            while (totalRead < msgLen) {
                const chunk = posix.read(client.socket, message[totalRead..msgLen]) catch |err| {
                    std.log.warn("[Server]: Error reading message from client {}: {}", .{ client.id, err });
                    break;
                };
                if (chunk == 0) {
                    std.log.info("[Server]: Client {} disconnected mid-message", .{client.id});
                    break;
                }
                totalRead += chunk;
            }

            if (totalRead != msgLen) {
                std.log.warn("[Server]: Incomplete message from client {}", .{client.id});
                break;
            }

            std.log.info("[Server]: Client {} has sent: {s}", .{ client.id, message[0..msgLen] });

            self.broadcastMessage(client.socket, message[0..msgLen]);
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

    pub fn broadcastMessage(self: *Server, senderSocket: posix.socket_t, message: []const u8) void {
        self.clientsMutex.lock();
        defer self.clientsMutex.unlock();

        var lenBuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenBuf, @intCast(message.len), .little);

        for (self.clients.items) |socket| {
            if (socket == senderSocket) continue;

            const vec = [_]posix.iovec_const{
                .{ .base = &lenBuf, .len = 4 },
                .{ .base = message.ptr, .len = message.len },
            };

            const res = posix.writev(socket, &vec);
            if (res) |_| {
                std.log.info("[Server]: Broadcasted to client {}", .{socket});
            } else |err| {
                std.log.warn("[Server]: Failed to send to client {}: {}", .{ socket, err });
            }
        }
    }
};
