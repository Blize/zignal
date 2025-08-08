const std = @import("std");

pub fn printHelp(progName: []const u8) void {
    std.debug.print(
        \\Usage: {s} <server|client> [OPTIONS] <IP> <PORT>
        \\
        \\Options:
        \\  server                              Start the server.
        \\  client [OPTIONS] <IP> <PORT>        Start the client and connect to the specified IP and PORT.
        \\
        \\Client Options:
        \\  -u, --username <name>   Set username for chat messages (max 23 characters)
        \\
        \\Examples:
        \\  {s} server
        \\  {s} client 127.0.0.1 8080
        \\  {s} client -u Alice 127.0.0.1 8080
        \\  {s} client 127.0.0.1 8080 -u Bob
        \\  {s} client --username Charlie 127.0.0.1 8080
        \\
    , .{ progName, progName, progName, progName, progName, progName });
}
