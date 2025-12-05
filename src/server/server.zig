const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const config = @import("../config.zig");
const xnet = @import("../net.zig");
const Reader = @import("../reader.zig").Reader;
const Writer = @import("../writer.zig").Writer;
const ServerTui = @import("tui.zig").ServerTui;
const LogEntry = @import("tui.zig").LogEntry;

const posix = std.posix;
const net = std.net;

const BUFFER_SIZE = config.BUFFER_SIZE;
const MAX_CLIENTS = config.MAX_CLIENTS;

// Buffer for local IP (static so it persists)
var local_ip_buf: [16]u8 = undefined;

/// Get the local network IP address by creating a UDP socket
/// and checking what source address would be used to reach 8.8.8.8
fn getLocalIp() ?[]const u8 {
    // Create a UDP socket (doesn't actually send anything)
    const sock = xnet.socket(xnet.AF.INET, xnet.SOCK.DGRAM, 0) catch return null;
    defer xnet.close(sock);

    // "Connect" to Google DNS - this doesn't send data, just sets the route
    const dest = net.Address.parseIp4("8.8.8.8", 53) catch return null;
    xnet.connect(sock, &dest.any, dest.getOsSockLen()) catch return null;

    // Get the local address that would be used
    var local_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    xnet.getsockname(sock, &local_addr.any, &addr_len) catch return null;

    // Format the IP address
    const bytes = @as(*const [4]u8, @ptrCast(&local_addr.in.sa.addr));
    const len = std.fmt.bufPrint(&local_ip_buf, "{}.{}.{}.{}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return null;

    return local_ip_buf[0..len.len];
}

/// Client represents a connected client with its socket and reader state
const ClientConnection = struct {
    reader: Reader,
    socket: xnet.socket_t,
    address: std.net.Address,

    fn init(allocator: Allocator, socket: xnet.socket_t, address: std.net.Address) !ClientConnection {
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
    polls: []xnet.PollFd,

    // Client connections: only [0..connected] are valid
    clients: []ClientConnection,

    // Slice of polls starting from index 1, for easier management
    client_polls: []xnet.PollFd,

    // Number of currently connected clients
    connected: usize,

    // Running state (shared with TUI)
    running: bool,

    // TUI reference for logging
    tui: ?*ServerTui,

    // Actual bound port (may differ from requested if 0 was used)
    bound_port: u16,

    // Local IP address for display
    local_ip: [16]u8,
    local_ip_len: usize,

    pub fn init(allocator: Allocator, address: net.Address, max_clients: ?usize) !Server {
        const actual_max = max_clients orelse MAX_CLIENTS;

        // Initialize platform-specific networking
        try xnet.init();

        // +1 for the listening socket
        const polls = try allocator.alloc(xnet.PollFd, actual_max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(ClientConnection, actual_max);
        errdefer allocator.free(clients);

        // Get local IP
        var local_ip: [16]u8 = undefined;
        var local_ip_len: usize = 0;
        if (getLocalIp()) |ip| {
            @memcpy(local_ip[0..ip.len], ip);
            local_ip_len = ip.len;
        } else {
            const fallback = "127.0.0.1";
            @memcpy(local_ip[0..fallback.len], fallback);
            local_ip_len = fallback.len;
        }

        return .{
            .allocator = allocator,
            .address = address,
            .max_clients = actual_max,
            .polls = polls,
            .clients = clients,
            .client_polls = polls[1..],
            .connected = 0,
            .running = true,
            .tui = null,
            .bound_port = 0,
            .local_ip = local_ip,
            .local_ip_len = local_ip_len,
        };
    }

    pub fn deinit(self: *Server) void {
        // Clean up all connected clients
        for (0..self.connected) |i| {
            xnet.close(self.clients[i].socket);
            self.clients[i].deinit(self.allocator);
        }
        self.connected = 0;

        self.allocator.free(self.polls);
        self.allocator.free(self.clients);

        xnet.deinit();
    }

    fn log(self: *Server, comptime fmt: []const u8, args: anytype, level: LogEntry.Level) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (self.tui) |tui| {
            tui.queueLog(msg, level);
        }
    }

    pub fn start(self: *Server) !void {
        // Create socket (non-blocking set separately for Windows compatibility)
        const listener = try xnet.socket(xnet.AF.INET, xnet.SOCK.STREAM, xnet.IPPROTO.TCP);
        defer xnet.close(listener);

        // Set non-blocking mode
        try xnet.setNonBlocking(listener);

        // Set socket options
        xnet.setReuseAddr(listener) catch {};

        try xnet.bind(listener, &self.address.any, self.address.getOsSockLen());
        try xnet.listen(listener, 128);

        var addr: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(net.Address);
        try xnet.getsockname(listener, &addr.any, &addr_len);

        self.bound_port = addr.getPort();
        self.log("Listening on port: {}", .{self.bound_port}, .info);

        // Start TUI in separate thread
        const tui = try ServerTui.init(
            self.allocator,
            self.local_ip[0..self.local_ip_len],
            &self.bound_port,
            &self.connected,
            self.max_clients,
            &self.running,
        );
        defer tui.deinit();
        self.tui = tui;

        // Start TUI thread
        const tui_thread = try std.Thread.spawn(.{}, runTui, .{tui});

        // Setup the listening socket in polls[0]
        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = xnet.PollFd.POLLIN,
        };

        while (self.running) {
            // Poll with timeout so we can check running state
            _ = xnet.poll(self.polls[0 .. self.connected + 1], 100) catch |err| {
                self.log("Poll error: {}", .{err}, .err);
                continue;
            };

            // Check if the listening socket is ready to accept
            if (self.polls[0].revents != 0) {
                self.acceptClients(listener) catch |err| {
                    self.log("Failed to accept clients: {}", .{err}, .err);
                };
            }

            // Process ready client sockets
            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    i += 1;
                    continue;
                }

                var client = &self.clients[i];

                // Check for errors or disconnection
                if (revents & xnet.PollFd.POLLHUP == xnet.PollFd.POLLHUP) {
                    self.log("Client disconnected", .{}, .warn);
                    self.removeClient(i);
                    continue;
                }

                // Read available data
                if (revents & xnet.PollFd.POLLIN == xnet.PollFd.POLLIN) {
                    while (true) {
                        const msg = client.readMessage() catch |err| {
                            self.log("Error reading from client: {}", .{err}, .err);
                            self.removeClient(i);
                            break;
                        } orelse {
                            i += 1;
                            break;
                        };

                        self.log("Message: {s}", .{msg}, .info);

                        // Broadcast to all other clients
                        const sockets = self.allocator.alloc(xnet.socket_t, self.connected) catch continue;
                        defer self.allocator.free(sockets);
                        for (0..self.connected) |j| {
                            sockets[j] = self.clients[j].socket;
                        }
                        Writer.broadcastMessage(sockets, msg, client.socket);
                    }
                }
            }
        }

        self.log("Server shutting down...", .{}, .info);
        tui_thread.join();
    }

    fn runTui(tui: *ServerTui) void {
        tui.run() catch {};
    }

    /// Accept all pending connections and add them to the client list
    fn acceptClients(self: *Server, listener: xnet.socket_t) !void {
        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);

            const socket = xnet.accept(listener, &client_address.any, &client_address_len) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            // Set new client socket to non-blocking
            xnet.setNonBlocking(socket) catch {
                xnet.close(socket);
                continue;
            };

            if (self.connected >= self.max_clients) {
                self.log("Max clients reached, rejecting connection", .{}, .warn);
                xnet.close(socket);
                continue;
            }

            const client = ClientConnection.init(self.allocator, socket, client_address) catch |err| {
                self.log("Failed to initialize client: {}", .{err}, .err);
                xnet.close(socket);
                continue;
            };

            const idx = self.connected;
            self.clients[idx] = client;
            self.client_polls[idx] = .{
                .fd = socket,
                .revents = 0,
                .events = xnet.PollFd.POLLIN,
            };
            self.connected += 1;

            self.log("Client connected (total: {})", .{self.connected}, .info);

            // Send welcome message
            const welcome = "[Server] Thanks for joining!";
            Writer.writeToSocket(socket, welcome) catch |err| {
                self.log("Failed to send welcome: {}", .{err}, .warn);
            };
        }
    }

    /// Remove a client from the connected list
    fn removeClient(self: *Server, idx: usize) void {
        var client = self.clients[idx];
        xnet.close(client.socket);
        client.deinit(self.allocator);

        // Swap with the last client to maintain a compact array
        const last_idx = self.connected - 1;
        if (idx != last_idx) {
            self.clients[idx] = self.clients[last_idx];
            self.client_polls[idx] = self.client_polls[last_idx];
        }

        self.connected = last_idx;
        self.log("Client removed (total: {})", .{self.connected}, .info);
    }
};
