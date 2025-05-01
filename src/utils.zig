const std = @import("std");

pub fn logMessage(
    logs: *std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    msg: []const u8,
    comptime T: type,
    value: ?T,
) !void {
    var buf: [128]u8 = undefined;

    const formatted = if (value) |val|
        try std.fmt.bufPrint(&buf, "{s} {}", .{ msg, val })
    else
        try std.fmt.bufPrint(&buf, "{s}", .{msg});

    try logs.append(try allocator.dupe(u8, formatted[0..]));
}

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
