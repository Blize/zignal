const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;
const Cell = vaxis.Cell;
const Key = vaxis.Key;
const Window = vaxis.Window;
const TextInput = vaxis.widgets.TextInput;

/// InputField component - wraps vaxis TextInput with additional functionality
pub const InputField = struct {
    inner: TextInput,
    allocator: Allocator,

    pub fn init(allocator: Allocator) InputField {
        return .{
            .inner = TextInput.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InputField) void {
        self.inner.deinit();
    }

    /// Handle key input for this input field
    pub fn handleKeyPress(self: *InputField, key: Key) !void {
        try self.inner.update(.{ .key_press = key });
    }

    /// Get the current input buffer content as a single slice
    pub fn getText(self: *const InputField, buffer: []u8) usize {
        const first = self.inner.buf.firstHalf();
        const second = self.inner.buf.secondHalf();
        const total_len = first.len + second.len;

        if (total_len == 0) {
            return 0;
        }

        if (total_len > buffer.len) {
            return 0; // Buffer too small
        }

        @memcpy(buffer[0..first.len], first);
        @memcpy(buffer[first.len..total_len], second);
        return total_len;
    }

    /// Get the current input as a slice (requires external buffer management)
    pub fn getTextAsSlice(self: *const InputField) struct { first: []const u8, second: []const u8 } {
        return .{
            .first = self.inner.buf.firstHalf(),
            .second = self.inner.buf.secondHalf(),
        };
    }

    /// Clear the input buffer
    pub fn clear(self: *InputField) void {
        self.inner.buf.clearRetainingCapacity();
    }

    /// Check if input is empty
    pub fn isEmpty(self: *const InputField) bool {
        const first = self.inner.buf.firstHalf();
        const second = self.inner.buf.secondHalf();
        return first.len == 0 and second.len == 0;
    }

    /// Get total length of input
    pub fn len(self: *const InputField) usize {
        return self.inner.buf.firstHalf().len + self.inner.buf.secondHalf().len;
    }

    /// Draw the input field in the given window
    pub fn draw(self: *InputField, area: Window) void {
        self.inner.draw(area);
    }

    /// Draw the input field with a label
    pub fn drawWithLabel(
        self: *InputField,
        area: Window,
        label: []const u8,
        label_style: Cell.Style,
    ) void {
        // Label
        const label_segment = [_]Cell.Segment{.{ .text = label, .style = label_style }};
        _ = area.print(&label_segment, .{ .row_offset = 0 });

        // Input area (after label)
        const label_len: u16 = @intCast(label.len);
        const input_area = area.child(.{
            .x_off = label_len,
            .y_off = 0,
            .width = if (area.width > label_len) area.width - label_len else 1,
            .height = 1,
        });
        self.draw(input_area);
    }
};
