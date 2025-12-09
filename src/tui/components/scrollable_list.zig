const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;
const Cell = vaxis.Cell;
const Window = vaxis.Window;

/// Generic scrollable list component
/// Supports filtering, scrolling, and rendering of items
pub fn ScrollableList(comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(T),
        allocator: Allocator,
        scroll_offset: usize = 0,

        pub fn init(allocator: Allocator) Self {
            return .{
                .items = .{},
                .allocator = allocator,
                .scroll_offset = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn append(self: *Self, item: T) !void {
            try self.items.append(self.allocator, item);
        }

        pub fn removeAt(self: *Self, index: usize) ?T {
            if (index < self.items.items.len) {
                return self.items.orderedRemove(index);
            }
            return null;
        }

        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
            self.scroll_offset = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn scrollUp(self: *Self) void {
            if (self.scroll_offset < self.items.items.len) {
                self.scroll_offset += 1;
            }
        }

        pub fn scrollDown(self: *Self) void {
            if (self.scroll_offset > 0) {
                self.scroll_offset -= 1;
            }
        }

        pub fn getScrollOffset(self: *const Self) usize {
            return self.scroll_offset;
        }

        pub fn setScrollOffset(self: *Self, offset: usize) void {
            self.scroll_offset = @min(offset, @max(0, @as(i32, @intCast(self.items.items.len)) - 1));
        }

        pub fn get(self: *const Self, index: usize) ?*const T {
            if (index < self.items.items.len) {
                return &self.items.items[index];
            }
            return null;
        }

        pub fn getMut(self: *Self, index: usize) ?*T {
            if (index < self.items.items.len) {
                return &self.items.items[index];
            }
            return null;
        }

        pub fn draw(
            self: *Self,
            area: Window,
            max_lines: u16,
            render_fn: fn (*const T, u16, Window) void,
        ) void {
            if (max_lines == 0) return;
            if (self.items.items.len == 0) {
                const empty_style: Cell.Style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } }, .italic = true };
                const empty = [_]Cell.Segment{.{ .text = "  (empty)", .style = empty_style }};
                _ = area.print(&empty, .{ .row_offset = 0 });
                return;
            }

            if (self.scroll_offset > self.items.items.len) {
                self.scroll_offset = self.items.items.len;
            }

            const visible_count = self.items.items.len;
            const end_idx = if (visible_count > self.scroll_offset) visible_count - self.scroll_offset else 0;
            const display_count = @min(end_idx, max_lines);
            const display_start = if (end_idx > display_count) end_idx - display_count else 0;

            var row: u16 = 0;
            var i: usize = display_start;
            while (i < end_idx and row < max_lines) : (i += 1) {
                if (i >= self.items.items.len) break;

                const item = &self.items.items[i];
                render_fn(item, row, area);
                row += 1;
            }
        }

        pub fn drawFiltered(
            self: *Self,
            area: Window,
            max_lines: u16,
            filter_text: []const u8,
            should_include_fn: fn (*const T, []const u8) bool,
            render_fn: fn (*const T, u16, Window) void,
        ) void {
            if (max_lines == 0) return;

            var filtered_indices: [512]usize = undefined;
            var filtered_count: usize = 0;

            for (self.items.items, 0..) |*item, i| {
                if (should_include_fn(item, filter_text)) {
                    if (filtered_count < filtered_indices.len) {
                        filtered_indices[filtered_count] = i;
                        filtered_count += 1;
                    }
                }
            }

            if (filtered_count == 0) {
                const empty_style: Cell.Style = .{ .fg = .{ .rgb = .{ 128, 128, 128 } }, .italic = true };
                const empty = [_]Cell.Segment{.{ .text = "  No items match filter", .style = empty_style }};
                _ = area.print(&empty, .{ .row_offset = 0 });
                return;
            }

            if (self.scroll_offset > filtered_count) {
                self.scroll_offset = filtered_count;
            }

            const end_idx = if (filtered_count > self.scroll_offset) filtered_count - self.scroll_offset else 0;
            const display_count = @min(end_idx, max_lines);
            const display_start = if (end_idx > display_count) end_idx - display_count else 0;

            var row: u16 = 0;
            var i: usize = display_start;
            while (i < end_idx and row < max_lines) : (i += 1) {
                if (i >= filtered_count) break;
                const idx = filtered_indices[i];
                if (idx >= self.items.items.len) break;

                const item = &self.items.items[idx];
                render_fn(item, row, area);
                row += 1;
            }
        }
    };
}
