const std = @import("std");
const vaxis = @import("vaxis");

const Cell = vaxis.Cell;

pub const colors = struct {
    pub const zig: Cell.Color = .{ .rgb = .{ 235, 168, 66 } };
    pub const zig_dim: Cell.Color = .{ .rgb = .{ 180, 128, 50 } };
    pub const background: Cell.Color = .{ .rgb = .{ 30, 30, 35 } };
    pub const text: Cell.Color = .{ .rgb = .{ 220, 220, 220 } };
    pub const timestamp: Cell.Color = .{ .rgb = .{ 120, 120, 130 } };
    pub const connected: Cell.Color = .{ .rgb = .{ 152, 195, 121 } };
    pub const disconnected: Cell.Color = .{ .rgb = .{ 224, 108, 117 } };

    pub const user_palette = [_]Cell.Color{
        .{ .rgb = .{ 235, 168, 66 } }, // Zig orange
        .{ .rgb = .{ 86, 182, 194 } }, // Cyan
        .{ .rgb = .{ 198, 120, 221 } }, // Purple
        .{ .rgb = .{ 152, 195, 121 } }, // Green
        .{ .rgb = .{ 224, 108, 117 } }, // Red
        .{ .rgb = .{ 229, 192, 123 } }, // Yellow
        .{ .rgb = .{ 97, 175, 239 } }, // Blue
        .{ .rgb = .{ 209, 154, 102 } }, // Orange
    };

    pub fn forUsername(username: []const u8) Cell.Color {
        var hash: u32 = 0;
        for (username) |c| {
            hash = hash *% 31 +% c;
        }
        return user_palette[hash % user_palette.len];
    }
};

pub const time = struct {
    pub fn formatTimestamp(timestamp: i64, buf: []u8) []const u8 {
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        return std.fmt.bufPrint(buf, "[{d:0>2}:{d:0>2}]", .{ hours, minutes }) catch "[??:??]";
    }
};

pub fn printHelp(progName: []const u8) void {
    std.debug.print(
        \\Usage: {s} <server|client> [OPTIONS]
        \\
        \\Options:
        \\  server [OPTIONS]                    Start the server.
        \\  client [OPTIONS] <IP> <PORT>        Start the client and connect to the specified IP and PORT.
        \\
        \\Server Options:
        \\  -p, --port <port>       Set the server port (default: 8080, 0 for any available)
        \\  -s, --size <size>       Set max number of clients (1-4095, default: 4095)
        \\
        \\Client Options:
        \\  -u, --username <name>   Set username for chat messages (max 23 characters)
        \\
        \\Examples:
        \\  {s} server
        \\  {s} server -p 9000
        \\  {s} server --port 0 --size 100
        \\  {s} client 127.0.0.1 8080
        \\  {s} client -u Alice 127.0.0.1 8080
        \\  {s} client 127.0.0.1 8080 -u Bob
        \\  {s} client --username Charlie 127.0.0.1 8080
        \\
    , .{ progName, progName, progName, progName, progName, progName, progName, progName });
}
