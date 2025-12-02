const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const config = @import("../config.zig");
const Reader = @import("../reader.zig").Reader;
const Writer = @import("../writer.zig").Writer;

const BUFFER_SIZE = config.BUFFER_SIZE;
const MAX_CLIENTS = config.MAX_CLIENTS;

const log = std.log.scoped(.server);

/// Client represents a connected client with its socket and reader state
const ClientConnection = struct {
    reader: Reader,
    socket: posix.socket_t,
    address: std.net.Address,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address) !ClientConnection {
        const reader = try Reader.init(allocator, BUFFER_SIZE);
        return .{
            .reader = reader,
            .socket = socket,
            .address = address,
        };
    }

    fn deinit(self: *ClientConnection, allocator: Allocator) void {
        self.reader.deinit(allocator);
    }

    fn readMessage(self: *ClientConnection) !?[]const u8 {
        return self.reader.readMessage(self.socket);
    }
};

pub const Server = struct {
    allocator: Allocator,
    address: net.Address,
    max_clients: usize,

    // Poll file descriptors: [0] is listening socket, [1..] are client sockets
    polls: []posix.pollfd,

    // Client connections: only [0..connected] are valid
    clients: []ClientConnection,

    // Slice of polls starting from index 1, for easier management
    client_polls: []posix.pollfd,

    // Number of currently connected clients
    connected: usize,

    pub fn init(allocator: Allocator, address: net.Address, max_clients: ?usize) !Server {
        const actual_max = max_clients orelse MAX_CLIENTS;

        // +1 for the listening socket
        const polls = try allocator.alloc(posix.pollfd, actual_max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(ClientConnection, actual_max);
        errdefer allocator.free(clients);

        return .{
            .allocator = allocator,
            .address = address,
            .max_clients = actual_max,
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
        };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
    }

    pub fn start(self: *Server) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(self.address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &self.address.any, self.address.getOsSockLen());
        try posix.listen(listener, 128);

        var addr: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(net.Address);
        try posix.getsockname(listener, &addr.any, &addr_len);

        log.info("Listening on port: {}", .{addr.getPort()});

        // Setup the listening socket in polls[0]
        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        while (true) {
            // Poll all connected clients + the listening socket
            _ = try posix.poll(self.polls[0 .. self.connected + 1], -1);

            // Check if the listening socket is ready to accept
            if (self.polls[0].revents != 0) {
                self.acceptClients(listener) catch |err| {
                    log.err("Failed to accept clients: {}", .{err});
                };
            }

            // Process ready client sockets
            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    // This socket is not ready
                    i += 1;
                    continue;
                }

                var client = &self.clients[i];

                // Check for errors or disconnection
                if (revents & posix.POLL.HUP == posix.POLL.HUP) {
                    log.info("Client disconnected", .{});
                    self.removeClient(i);
                    continue;
                }

                // Read available data
                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    while (true) {
                        const msg = client.readMessage() catch |err| {
                            log.err("Error reading from client: {}", .{err});
                            self.removeClient(i);
                            break;
                        } orelse {
                            // No more complete messages available for this client
                            i += 1;
                            break;
                        };

                        log.info("Received message: {s}", .{msg});

                        // Broadcast to all other clients
                        const sockets = try self.allocator.alloc(posix.socket_t, self.connected);
                        defer self.allocator.free(sockets);
                        for (0..self.connected) |j| {
                            sockets[j] = self.clients[j].socket;
                        }
                        Writer.broadcastMessage(sockets, msg, client.socket);
                    }
                }
            }
        }
    }

    /// Accept all pending connections and add them to the client list
    fn acceptClients(self: *Server, listener: posix.socket_t) !void {
        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);

            const socket = posix.accept(listener, &client_address.any, &client_address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            if (self.connected >= self.max_clients) {
                log.warn("Max clients reached, rejecting new connection", .{});
                posix.close(socket);
                continue;
            }

            const client = ClientConnection.init(self.allocator, socket, client_address) catch |err| {
                log.err("Failed to initialize client: {}", .{err});
                posix.close(socket);
                continue;
            };

            const idx = self.connected;
            self.clients[idx] = client;
            self.client_polls[idx] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.connected += 1;

            log.info("Client connected. Total connections: {}", .{self.connected});

            // Send welcome message
            const welcome = "[Server] Thanks for joining!";
            Writer.writeToSocket(socket, welcome) catch |err| {
                log.warn("Failed to send welcome message: {}", .{err});
            };
        }
    }

    /// Remove a client from the connected list
    fn removeClient(self: *Server, idx: usize) void {
        var client = self.clients[idx];
        posix.close(client.socket);
        client.deinit(self.allocator);

        // Swap with the last client to maintain a compact array
        const last_idx = self.connected - 1;
        if (idx != last_idx) {
            self.clients[idx] = self.clients[last_idx];
            self.client_polls[idx] = self.client_polls[last_idx];
        }

        self.connected = last_idx;
        log.info("Client removed. Total connections: {}", .{self.connected});
    }
};
