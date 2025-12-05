const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform socket abstraction
/// On POSIX systems, uses posix APIs
/// On Windows, uses Windows socket APIs
pub const is_windows = builtin.os.tag == .windows;

pub const socket_t = if (is_windows) std.os.windows.ws2_32.SOCKET else std.posix.socket_t;
pub const INVALID_SOCKET = if (is_windows) std.os.windows.ws2_32.INVALID_SOCKET else -1;

const ws2_32 = if (is_windows) std.os.windows.ws2_32 else undefined;
const posix = std.posix;

/// Initialize Windows sockets (no-op on POSIX)
pub fn init() !void {
    if (is_windows) {
        _ = try ws2_32.WSAStartup(2, 2);
    }
}

/// Cleanup Windows sockets (no-op on POSIX)
pub fn deinit() void {
    if (is_windows) {
        ws2_32.WSACleanup() catch {};
    }
}

/// Close a socket
pub fn close(sock: socket_t) void {
    if (is_windows) {
        _ = ws2_32.closesocket(sock);
    } else {
        posix.close(sock);
    }
}

/// Read from a socket
pub fn read(sock: socket_t, buf: []u8) !usize {
    if (is_windows) {
        const result = ws2_32.recv(sock, buf.ptr, @intCast(buf.len), 0);
        if (result == ws2_32.SOCKET_ERROR) {
            const err = ws2_32.WSAGetLastError();
            return switch (err) {
                ws2_32.WinsockError.WSAEWOULDBLOCK => error.WouldBlock,
                ws2_32.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                else => error.Unexpected,
            };
        }
        return @intCast(result);
    } else {
        return posix.read(sock, buf);
    }
}

/// Write to a socket
pub fn write(sock: socket_t, buf: []const u8) !usize {
    if (is_windows) {
        const result = ws2_32.send(sock, buf.ptr, @intCast(buf.len), 0);
        if (result == ws2_32.SOCKET_ERROR) {
            const err = ws2_32.WSAGetLastError();
            return switch (err) {
                ws2_32.WinsockError.WSAEWOULDBLOCK => error.WouldBlock,
                ws2_32.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                else => error.Unexpected,
            };
        }
        return @intCast(result);
    } else {
        return posix.write(sock, buf);
    }
}

/// Write all data to a socket (handles partial writes)
pub fn writeAll(sock: socket_t, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        sent += try write(sock, buf[sent..]);
    }
}

/// Create a socket
pub fn socket(family: u32, sock_type: u32, protocol: u32) !socket_t {
    if (is_windows) {
        const sock = ws2_32.socket(@intCast(family), @intCast(sock_type), @intCast(protocol));
        if (sock == ws2_32.INVALID_SOCKET) {
            return error.SocketCreateFailed;
        }
        return sock;
    } else {
        return posix.socket(family, sock_type, protocol);
    }
}

/// Connect to an address
pub fn connect(sock: socket_t, addr: *const std.posix.sockaddr, addrlen: std.posix.socklen_t) !void {
    if (is_windows) {
        const result = ws2_32.connect(sock, addr, @intCast(addrlen));
        if (result == ws2_32.SOCKET_ERROR) {
            return error.ConnectionFailed;
        }
    } else {
        try posix.connect(sock, addr, addrlen);
    }
}

/// Set socket to non-blocking mode
pub fn setNonBlocking(sock: socket_t) !void {
    if (is_windows) {
        var mode: c_ulong = 1;
        const result = ws2_32.ioctlsocket(sock, ws2_32.FIONBIO, &mode);
        if (result == ws2_32.SOCKET_ERROR) {
            return error.SetNonBlockingFailed;
        }
    } else {
        // On POSIX, use fcntl to set non-blocking mode
        const F_GETFL = 3;
        const F_SETFL = 4;
        const O_NONBLOCK = 0x0004; // macOS value, also works on Linux
        const flags = try posix.fcntl(sock, F_GETFL, 0);
        _ = try posix.fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    }
}

/// Poll structure that works on both platforms
pub const PollFd = if (is_windows) struct {
    fd: socket_t,
    events: i16,
    revents: i16,

    pub const POLLIN: i16 = 0x0001;
    pub const POLLHUP: i16 = 0x0010;
    pub const POLLERR: i16 = 0x0008;
} else struct {
    fd: socket_t,
    events: i16,
    revents: i16,

    // POSIX poll constants (same on macOS and Linux)
    pub const POLLIN: i16 = 0x0001;
    pub const POLLHUP: i16 = 0x0010;
    pub const POLLERR: i16 = 0x0008;
};

/// Poll for socket events
pub fn poll(fds: []PollFd, timeout_ms: i32) !usize {
    if (is_windows) {
        const result = ws2_32.WSAPoll(@ptrCast(fds.ptr), @intCast(fds.len), timeout_ms);
        if (result == ws2_32.SOCKET_ERROR) {
            return error.PollFailed;
        }
        return @intCast(result);
    } else {
        // Cast our PollFd array to posix.pollfd
        const posix_fds: []posix.pollfd = @ptrCast(fds);
        const result = try posix.poll(posix_fds, timeout_ms);
        return result;
    }
}

/// Accept a connection
pub fn accept(sock: socket_t, addr: *std.posix.sockaddr, addrlen: *std.posix.socklen_t) !socket_t {
    if (is_windows) {
        const client = ws2_32.accept(sock, addr, @ptrCast(addrlen));
        if (client == ws2_32.INVALID_SOCKET) {
            const err = ws2_32.WSAGetLastError();
            return switch (err) {
                ws2_32.WinsockError.WSAEWOULDBLOCK => error.WouldBlock,
                else => error.AcceptFailed,
            };
        }
        return client;
    } else {
        return posix.accept(sock, addr, addrlen, posix.SOCK.NONBLOCK);
    }
}

/// Bind socket to address
pub fn bind(sock: socket_t, addr: *const std.posix.sockaddr, addrlen: std.posix.socklen_t) !void {
    if (is_windows) {
        const result = ws2_32.bind(sock, addr, @intCast(addrlen));
        if (result == ws2_32.SOCKET_ERROR) {
            return error.BindFailed;
        }
    } else {
        try posix.bind(sock, addr, addrlen);
    }
}

/// Listen for connections
pub fn listen(sock: socket_t, backlog: u31) !void {
    if (is_windows) {
        const result = ws2_32.listen(sock, backlog);
        if (result == ws2_32.SOCKET_ERROR) {
            return error.ListenFailed;
        }
    } else {
        try posix.listen(sock, backlog);
    }
}

/// Set socket option (simplified - just for SO_REUSEADDR)
pub fn setReuseAddr(sock: socket_t) !void {
    const value: c_int = 1;
    const value_bytes = std.mem.toBytes(value);
    
    if (is_windows) {
        const SOL_SOCKET: i32 = 0xffff;
        const SO_REUSEADDR: i32 = 4;
        const result = ws2_32.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &value_bytes, @intCast(value_bytes.len));
        if (result == ws2_32.SOCKET_ERROR) {
            return error.SetSockOptFailed;
        }
    } else {
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &value_bytes);
    }
}

/// Get socket name (local address)
pub fn getsockname(sock: socket_t, addr: *std.posix.sockaddr, addrlen: *std.posix.socklen_t) !void {
    if (is_windows) {
        const result = ws2_32.getsockname(sock, addr, @ptrCast(addrlen));
        if (result == ws2_32.SOCKET_ERROR) {
            return error.GetSockNameFailed;
        }
    } else {
        try posix.getsockname(sock, addr, addrlen);
    }
}

// Re-export common constants
pub const AF = posix.AF;
pub const SOCK = struct {
    pub const STREAM = posix.SOCK.STREAM;
    pub const DGRAM = posix.SOCK.DGRAM;
};
pub const IPPROTO = posix.IPPROTO;
pub const SO = posix.SO;
