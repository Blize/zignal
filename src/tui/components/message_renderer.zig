const std = @import("std");
const vaxis = @import("vaxis");

const utils = @import("../../utils.zig");
const colors = utils.colors;

const Cell = vaxis.Cell;
const Window = vaxis.Window;

/// Renders a chat message with appropriate styling based on message type.
/// Handles system, server, help, and user messages with different colors/styles.
pub fn renderChatMessage(
    content: []const u8,
    timestamp: []const u8,
    row: u16,
    area: Window,
) void {
    const timestamp_style: Cell.Style = .{ .fg = colors.timestamp };

    if (std.mem.startsWith(u8, content, "[System]")) {
        const style: Cell.Style = .{ .fg = colors.zig, .italic = true };
        const segments = [_]Cell.Segment{
            .{ .text = timestamp, .style = timestamp_style },
            .{ .text = " ", .style = .{} },
            .{ .text = content, .style = style },
        };
        _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });
    } else if (std.mem.startsWith(u8, content, "[Server]")) {
        const style: Cell.Style = .{ .fg = colors.zig, .bold = true };
        const segments = [_]Cell.Segment{
            .{ .text = timestamp, .style = timestamp_style },
            .{ .text = " ", .style = .{} },
            .{ .text = content, .style = style },
        };
        _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });
    } else if (std.mem.startsWith(u8, content, "[Help]")) {
        const style: Cell.Style = .{ .fg = colors.zig_dim, .italic = true };
        const segments = [_]Cell.Segment{
            .{ .text = timestamp, .style = timestamp_style },
            .{ .text = " ", .style = .{} },
            .{ .text = content, .style = style },
        };
        _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });
    } else if (std.mem.indexOf(u8, content, ": ")) |colon_pos| {
        const username_part = content[0..colon_pos];
        const separator = ": ";
        const message_part = content[colon_pos + 2 ..];

        const user_color = colors.forUsername(username_part);
        const username_style: Cell.Style = .{ .fg = user_color, .bold = true };
        const text_style: Cell.Style = .{ .fg = colors.text };

        const segments = [_]Cell.Segment{
            .{ .text = timestamp, .style = timestamp_style },
            .{ .text = " ", .style = .{} },
            .{ .text = username_part, .style = username_style },
            .{ .text = separator, .style = username_style },
            .{ .text = message_part, .style = text_style },
        };
        _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });
    } else {
        const style: Cell.Style = .{ .fg = colors.text };
        const segments = [_]Cell.Segment{
            .{ .text = timestamp, .style = timestamp_style },
            .{ .text = " ", .style = .{} },
            .{ .text = content, .style = style },
        };
        _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });
    }
}
