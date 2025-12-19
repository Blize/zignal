const std = @import("std");
const config = @import("../config.zig");

pub const MAX_USERNAME_LEN = config.MAX_USERNAME_LEN;
pub const MAX_MESSAGE_LEN = config.BUFFER_SIZE;

pub const PacketError = error{
    InvalidPacketType,
    InvalidData,
    BufferTooSmall,
    MessageTooLarge,
    UsernameTooLong,
};

pub const PacketType = enum(u8) {
    handshake = 0,
    message = 1,
    config = 2,

    pub fn fromByte(byte: u8) PacketError!PacketType {
        return std.meta.intToEnum(PacketType, byte) catch PacketError.InvalidPacketType;
    }

    pub fn toByte(self: PacketType) u8 {
        return @intFromEnum(self);
    }
};

/// TODO
pub const Handshake = struct {
    // TODO: Add fields for encryption handshake
    _placeholder: u8 = 0,

    pub fn serialize(self: Handshake, buffer: []u8) PacketError![]u8 {
        _ = self;
        if (buffer.len < 1) return PacketError.BufferTooSmall;
        buffer[0] = 0;
        return buffer[0..1];
    }

    pub fn deserialize(data: []const u8) PacketError!Handshake {
        _ = data;
        return .{};
    }
};

/// TODO
pub const Config = struct {
    // TODO: Add fields for config updates
    _placeholder: u8 = 0,

    pub fn serialize(self: Config, buffer: []u8) PacketError![]u8 {
        _ = self;
        if (buffer.len < 1) return PacketError.BufferTooSmall;
        buffer[0] = 0;
        return buffer[0..1];
    }

    pub fn deserialize(data: []const u8) PacketError!Config {
        _ = data;
        return .{};
    }
};

pub const Message = struct {
    sender: []const u8,
    content: []const u8,
    timestamp: i64,

    pub fn init(sender: []const u8, content: []const u8, timestamp: i64) Message {
        return .{
            .sender = sender,
            .content = content,
            .timestamp = timestamp,
        };
    }

    pub fn create(sender: []const u8, content: []const u8) Message {
        return init(sender, content, std.time.timestamp());
    }

    /// Serialize message to bytes
    /// Format: [sender_len: 1][sender: sender_len][timestamp: 8][content_len: 2][content: content_len]
    pub fn serialize(self: Message, buffer: []u8) PacketError![]u8 {
        if (self.sender.len > MAX_USERNAME_LEN) return PacketError.UsernameTooLong;
        if (self.content.len > MAX_MESSAGE_LEN) return PacketError.MessageTooLarge;

        const sender_len: u8 = @intCast(self.sender.len);
        const content_len: u16 = @intCast(self.content.len);
        const total_len = 1 + sender_len + 8 + 2 + content_len;

        if (buffer.len < total_len) return PacketError.BufferTooSmall;

        var pos: usize = 0;

        buffer[pos] = sender_len;
        pos += 1;

        @memcpy(buffer[pos .. pos + sender_len], self.sender);
        pos += sender_len;

        std.mem.writeInt(i64, buffer[pos..][0..8], self.timestamp, .little);
        pos += 8;

        std.mem.writeInt(u16, buffer[pos..][0..2], content_len, .little);
        pos += 2;

        @memcpy(buffer[pos .. pos + content_len], self.content);
        pos += content_len;

        return buffer[0..pos];
    }

    /// Deserialize message from bytes
    pub fn deserialize(data: []const u8) PacketError!Message {
        if (data.len < 1) return PacketError.InvalidData;

        var pos: usize = 0;

        const sender_len = data[pos];
        pos += 1;

        if (data.len < pos + sender_len + 8 + 2) return PacketError.InvalidData;

        const sender = data[pos .. pos + sender_len];
        pos += sender_len;

        const timestamp = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;

        const content_len = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        if (data.len < pos + content_len) return PacketError.InvalidData;

        const content = data[pos .. pos + content_len];

        return .{
            .sender = sender,
            .content = content,
            .timestamp = timestamp,
        };
    }

    /// Format message for display: "sender: content"
    pub fn format(self: Message, buffer: []u8) []u8 {
        const result = std.fmt.bufPrint(buffer, "{s}: {s}", .{ self.sender, self.content }) catch return buffer[0..0];
        return result;
    }
};

/// Tagged union representing all packet types
pub const Packet = union(PacketType) {
    handshake: Handshake,
    message: Message,
    config: Config,

    pub fn serialize(self: Packet, buffer: []u8) PacketError![]u8 {
        if (buffer.len < 1) return PacketError.BufferTooSmall;

        buffer[0] = @intFromEnum(self);

        const payload = switch (self) {
            .handshake => |h| try h.serialize(buffer[1..]),
            .message => |m| try m.serialize(buffer[1..]),
            .config => |c| try c.serialize(buffer[1..]),
        };

        return buffer[0 .. 1 + payload.len];
    }

    pub fn deserialize(data: []const u8) PacketError!Packet {
        if (data.len < 1) return PacketError.InvalidData;

        const packet_type = try PacketType.fromByte(data[0]);
        const payload = data[1..];

        return switch (packet_type) {
            .handshake => .{ .handshake = try Handshake.deserialize(payload) },
            .message => .{ .message = try Message.deserialize(payload) },
            .config => .{ .config = try Config.deserialize(payload) },
        };
    }

    /// Helper to create a message packet
    pub fn createMessage(sender: []const u8, content: []const u8) Packet {
        return .{ .message = Message.create(sender, content) };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PacketType conversion" {
    try std.testing.expectEqual(@as(u8, 0), PacketType.handshake.toByte());
    try std.testing.expectEqual(@as(u8, 1), PacketType.message.toByte());
    try std.testing.expectEqual(@as(u8, 2), PacketType.config.toByte());
    try std.testing.expectEqual(PacketType.handshake, try PacketType.fromByte(0));
    try std.testing.expectEqual(PacketType.message, try PacketType.fromByte(1));
    try std.testing.expectEqual(PacketType.config, try PacketType.fromByte(2));
    try std.testing.expectError(PacketError.InvalidPacketType, PacketType.fromByte(255));
}

test "Message serialization roundtrip" {
    var buffer: [256]u8 = undefined;

    const msg = Message.init("Alice", "Hello, World!", 1234567890);
    const bytes = try msg.serialize(&buffer);
    const parsed = try Message.deserialize(bytes);

    try std.testing.expectEqualStrings("Alice", parsed.sender);
    try std.testing.expectEqualStrings("Hello, World!", parsed.content);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.timestamp);
}

test "Message format" {
    var format_buf: [256]u8 = undefined;
    const msg = Message.init("Alice", "Hello!", 0);
    const formatted = msg.format(&format_buf);
    try std.testing.expectEqualStrings("Alice: Hello!", formatted);
}

test "Packet message roundtrip" {
    var buffer: [512]u8 = undefined;

    const packet = Packet.createMessage("Bob", "Test message");
    const bytes = try packet.serialize(&buffer);
    const parsed = try Packet.deserialize(bytes);

    switch (parsed) {
        .message => |m| {
            try std.testing.expectEqualStrings("Bob", m.sender);
            try std.testing.expectEqualStrings("Test message", m.content);
        },
        else => return error.UnexpectedPacketType,
    }
}
