const std = @import("std");

pub fn printHelp(progName: []const u8) void {
    std.debug.print(
        \\Usage: {s} <server|client> [IP] [PORT]
        \\
        \\Options:
        \\  server                Start the server.
        \\  client <IP> <PORT>    Start the client and connect to the specified IP and PORT.
        \\
        \\Examples:
        \\  {s} server
        \\  {s} client 127.0.0.1 8080
        \\
    , .{ progName, progName, progName });
}
