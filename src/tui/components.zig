/// TUI Components - reusable UI elements for both server and client
pub const InputField = @import("components/input_field.zig").InputField;
pub const renderChatMessage = @import("components/message_renderer.zig").renderChatMessage;
pub fn ScrollableList(comptime T: type) type {
    return @import("components/scrollable_list.zig").ScrollableList(T);
}
