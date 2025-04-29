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
