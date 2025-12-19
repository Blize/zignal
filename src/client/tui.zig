const std = @import("std");
const vaxis = @import("vaxis");
const posix = std.posix;

const config = @import("../config.zig");
const utils = @import("../utils.zig");
const Writer = @import("../writer.zig").Writer;
const Reader = @import("../reader.zig").Reader;
const Packet = @import("../networking/packet.zig").Packet;
const client = @import("client.zig");
const components = @import("../tui/components.zig");
const ChatMessage = client.ChatMessage;
const Command = client.Command;

const BUFFER_SIZE = config.BUFFER_SIZE;

const Cell = vaxis.Cell;
const Key = vaxis.Key;
const Window = vaxis.Window;
const InputField = components.InputField;
const ScrollableList = components.ScrollableList;

const colors = utils.colors;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

pub const TuiClient = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    address: std.net.Address,
    username: []const u8,

    vx: vaxis.Vaxis,
    tty: vaxis.Tty,

    messages: ScrollableList(ChatMessage),
    text_input: InputField,

    running: bool,
    connected: bool,
    reconnecting: bool,
    socket_valid: bool,

    receiver_thread: ?std.Thread,

    pending_messages: std.ArrayList([]const u8),
    message_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t, address: std.net.Address, username: []const u8) !*TuiClient {
        const self = try allocator.create(TuiClient);
        errdefer allocator.destroy(self);

        var tty_buf: [1024]u8 = undefined;
        var tty = try vaxis.Tty.init(&tty_buf);
        errdefer tty.deinit();

        var vx = try vaxis.Vaxis.init(allocator, .{});
        errdefer vx.deinit(allocator, tty.writer());

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .address = address,
            .username = username,
            .vx = vx,
            .tty = tty,
            .messages = ScrollableList(ChatMessage).init(allocator),
            .text_input = InputField.init(allocator),
            .running = true,
            .connected = true,
            .reconnecting = false,
            .socket_valid = true,
            .receiver_thread = null,
            .pending_messages = .{},
            .message_mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *TuiClient) void {
        self.running = false;
        if (self.socket_valid) {
            posix.close(self.socket);
            self.socket_valid = false;
        }

        if (self.receiver_thread) |thread| {
            thread.join();
        }

        for (self.messages.items.items) |*msg| {
            msg.destroy();
        }
        self.messages.deinit();

        self.message_mutex.lock();
        for (self.pending_messages.items) |msg| {
            self.allocator.free(msg);
        }
        self.pending_messages.deinit(self.allocator);
        self.message_mutex.unlock();

        self.text_input.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();

        self.allocator.destroy(self);
    }

    pub fn run(self: *TuiClient) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();

        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());

        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        self.receiver_thread = try std.Thread.spawn(.{}, receiveMessages, .{self});

        try self.addMessage("[System] Welcome to Zignal Chat! Type your message and press Enter to send. Press Ctrl+C to exit.");

        while (self.running) {
            self.processPendingMessages();

            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            try self.render();

            // Small sleep to prevent busy loop
            std.Thread.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }

    fn handleEvent(self: *TuiClient, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.running = false;
                    return;
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    self.vx.queueRefresh();
                    return;
                }

                if (key.matches(Key.enter, .{})) {
                    try self.sendMessage();
                    return;
                }

                if (key.matches(Key.page_up, .{})) {
                    var i: usize = 0;
                    while (i < 5) : (i += 1) {
                        self.messages.scrollUp();
                    }
                    return;
                }

                if (key.matches(Key.page_down, .{})) {
                    var i: usize = 0;
                    while (i < 5) : (i += 1) {
                        self.messages.scrollDown();
                    }
                    return;
                }

                if (key.matches(Key.up, .{})) {
                    self.messages.scrollUp();
                    return;
                }

                if (key.matches(Key.down, .{})) {
                    self.messages.scrollDown();
                    return;
                }

                try self.text_input.handleKeyPress(key);
            },
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
            },
            else => {},
        }
    }

    fn render(self: *TuiClient) !void {
        const win = self.vx.window();
        win.clear();

        const width = win.width;
        const height = win.height;

        if (height < 10 or width < 40) {
            return; // Terminal too small
        }

        const border_style: Cell.Style = .{
            .fg = colors.zig,
        };

        const title_style: Cell.Style = .{
            .fg = colors.background,
            .bg = colors.zig,
            .bold = true,
        };

        var col: u16 = 0;
        while (col < width) : (col += 1) {
            win.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = title_style });
        }

        const title_text = "ZIGNAL ";
        const title_start: u16 = if (width > title_text.len) @intCast((width - title_text.len) / 2) else 0;
        const title_segment = [_]Cell.Segment{.{ .text = title_text, .style = title_style }};
        _ = win.print(&title_segment, .{ .col_offset = title_start });

        const status_indicator = if (self.connected) " ● Connected " else " ○ Disconnected ";
        const status_indicator_style: Cell.Style = .{
            .fg = if (self.connected) colors.connected else colors.disconnected,
            .bg = colors.zig,
            .bold = true,
        };
        const status_start: u16 = if (width > status_indicator.len) @intCast(width - status_indicator.len) else 0;
        const status_segment = [_]Cell.Segment{.{ .text = status_indicator, .style = status_indicator_style }};
        _ = win.print(&status_segment, .{ .col_offset = status_start });

        const input_height: u16 = 3;
        const chat_height: u16 = @intCast(@max(1, height - 4 - input_height));
        const chat_area = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = width,
            .height = chat_height,
            .border = .{
                .where = .all,
                .style = border_style,
            },
        });

        self.renderMessages(chat_area, chat_height - 2);

        const input_row: u16 = 1 + chat_height;

        const input_box = win.child(.{
            .x_off = 0,
            .y_off = input_row,
            .width = width,
            .height = input_height,
            .border = .{
                .where = .all,
                .style = border_style,
            },
        });

        self.text_input.draw(input_box);

        try self.vx.render(self.tty.writer());
    }

    fn renderMessages(self: *TuiClient, area: Window, max_lines: u16) void {
        if (self.messages.count() == 0) return;

        const renderMessage = struct {
            pub fn render(msg: *const ChatMessage, row: u16, area_: Window) void {
                var timestamp_buf: [8]u8 = undefined;
                const timestamp = msg.getTimestampStr(&timestamp_buf);

                const timestamp_style: Cell.Style = .{ .fg = colors.timestamp };

                if (std.mem.startsWith(u8, msg.content, "[System]")) {
                    const style: Cell.Style = .{ .fg = colors.zig, .italic = true };
                    const segments = [_]Cell.Segment{
                        .{ .text = timestamp, .style = timestamp_style },
                        .{ .text = " ", .style = .{} },
                        .{ .text = msg.content, .style = style },
                    };
                    _ = area_.print(&segments, .{ .row_offset = row, .wrap = .word });
                } else if (std.mem.startsWith(u8, msg.content, "[Server]")) {
                    const style: Cell.Style = .{ .fg = colors.zig, .bold = true };
                    const segments = [_]Cell.Segment{
                        .{ .text = timestamp, .style = timestamp_style },
                        .{ .text = " ", .style = .{} },
                        .{ .text = msg.content, .style = style },
                    };
                    _ = area_.print(&segments, .{ .row_offset = row, .wrap = .word });
                } else if (std.mem.startsWith(u8, msg.content, "[Help]")) {
                    const style: Cell.Style = .{ .fg = colors.zig_dim, .italic = true };
                    const segments = [_]Cell.Segment{
                        .{ .text = timestamp, .style = timestamp_style },
                        .{ .text = " ", .style = .{} },
                        .{ .text = msg.content, .style = style },
                    };
                    _ = area_.print(&segments, .{ .row_offset = row, .wrap = .word });
                } else if (std.mem.indexOf(u8, msg.content, ": ")) |colon_pos| {
                    const username_part = msg.content[0..colon_pos];
                    const separator = ": ";
                    const message_part = msg.content[colon_pos + 2 ..];

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
                    _ = area_.print(&segments, .{ .row_offset = row, .wrap = .word });
                } else {
                    const style: Cell.Style = .{ .fg = colors.text };
                    const segments = [_]Cell.Segment{
                        .{ .text = timestamp, .style = timestamp_style },
                        .{ .text = " ", .style = .{} },
                        .{ .text = msg.content, .style = style },
                    };
                    _ = area_.print(&segments, .{ .row_offset = row, .wrap = .word });
                }
            }
        }.render;

        self.messages.draw(area, @intCast(max_lines), renderMessage);
    }

    fn sendMessage(self: *TuiClient) !void {
        var message_buf: [BUFFER_SIZE]u8 = undefined;
        const message_len = self.text_input.getText(&message_buf);

        if (message_len == 0) return;

        const message = message_buf[0..message_len];

        if (Command.parse(message)) |cmd| {
            self.text_input.clear();
            switch (cmd) {
                .exit => {
                    self.running = false;
                },
                .clear => {
                    for (self.messages.items.items) |*msg| {
                        msg.destroy();
                    }
                    self.messages.clear();
                },
                .help => {
                    try self.addMessage(Command.helpText());
                },
            }
            return;
        }

        const display_username = if (self.username.len > 0) self.username else "Anonymous";

        const packet = Packet.createMessage(display_username, message);
        var packet_buf: [BUFFER_SIZE]u8 = undefined;
        const serialized = packet.serialize(&packet_buf) catch |err| {
            var err_buf: [64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "[System] Failed to serialize: {}", .{err}) catch "[System] Failed to serialize";
            try self.addMessage(err_msg);
            return;
        };

        // Display locally
        var formatted_message: [BUFFER_SIZE]u8 = undefined;
        const formatted = packet.message.format(&formatted_message);
        try self.addMessage(formatted);

        const writer = Writer.init(self.socket);
        writer.writeMessage(serialized) catch |err| {
            var err_buf: [64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "[System] Failed to send message: {}", .{err}) catch "[System] Failed to send message";
            try self.addMessage(err_msg);
            return;
        };

        self.text_input.clear();
    }

    fn addMessage(self: *TuiClient, content: []const u8) !void {
        const msg = try ChatMessage.create(self.allocator, content);
        try self.messages.append(msg);

        self.messages.scroll_offset = 0;
    }

    fn processPendingMessages(self: *TuiClient) void {
        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        for (self.pending_messages.items) |msg| {
            self.addMessage(msg) catch {};
            self.allocator.free(msg);
        }
        self.pending_messages.clearRetainingCapacity();
    }

    fn receiveMessages(self: *TuiClient) void {
        var message_buffer: [BUFFER_SIZE]u8 = undefined;

        while (self.running) {
            if (self.reconnecting) {
                self.attemptReconnect();
                continue;
            }

            const message = Reader.readClientMessage(self.socket, &message_buffer) catch |err| {
                if (self.running) {
                    var err_buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "[System] Connection lost: {}. Attempting to reconnect...", .{err}) catch "[System] Connection lost. Attempting to reconnect...";
                    const owned = self.allocator.dupe(u8, err_msg) catch continue;

                    self.message_mutex.lock();
                    self.pending_messages.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                    };
                    self.message_mutex.unlock();

                    self.connected = false;
                    self.reconnecting = true;
                    posix.close(self.socket);
                    self.socket_valid = false;
                }
                continue;
            };

            if (message == null) {
                const owned = self.allocator.dupe(u8, "[System] Disconnected from server. Attempting to reconnect...") catch continue;

                self.message_mutex.lock();
                self.pending_messages.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
                self.message_mutex.unlock();

                self.connected = false;
                self.reconnecting = true;
                posix.close(self.socket);
                self.socket_valid = false;
                continue;
            }

            const packet = Packet.deserialize(message.?) catch {
                // Fallback: treat as raw text
                const owned = self.allocator.dupe(u8, message.?) catch continue;
                self.message_mutex.lock();
                self.pending_messages.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
                self.message_mutex.unlock();
                continue;
            };

            switch (packet) {
                .message => |msg| {
                    var format_buf: [BUFFER_SIZE]u8 = undefined;
                    const formatted = msg.format(&format_buf);
                    const owned = self.allocator.dupe(u8, formatted) catch continue;

                    self.message_mutex.lock();
                    self.pending_messages.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                    };
                    self.message_mutex.unlock();
                },
                .handshake => {
                    // TODO: Handle handshake packets
                },
                .config => {
                    // TODO: Handle config packets
                },
            }
        }
    }

    fn attemptReconnect(self: *TuiClient) void {
        std.Thread.sleep(3 * std.time.ns_per_s);

        if (!self.running) return;

        const new_socket = posix.socket(self.address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "[System] Reconnect failed (socket): {}. Retrying in 3 seconds...", .{err}) catch "[System] Reconnect failed. Retrying in 3 seconds...";
            const owned = self.allocator.dupe(u8, err_msg) catch return;

            self.message_mutex.lock();
            self.pending_messages.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
            self.message_mutex.unlock();
            return;
        };

        posix.connect(new_socket, &self.address.any, self.address.getOsSockLen()) catch |err| {
            posix.close(new_socket);
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "[System] Reconnect failed (connect): {}. Retrying in 3 seconds...", .{err}) catch "[System] Reconnect failed. Retrying in 3 seconds...";
            const owned = self.allocator.dupe(u8, err_msg) catch return;

            self.message_mutex.lock();
            self.pending_messages.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
            self.message_mutex.unlock();
            return;
        };

        self.socket = new_socket;
        self.connected = true;
        self.reconnecting = false;
        self.socket_valid = true;

        const owned = self.allocator.dupe(u8, "[System] Reconnected to server!") catch return;

        self.message_mutex.lock();
        self.pending_messages.append(self.allocator, owned) catch {
            self.allocator.free(owned);
        };
        self.message_mutex.unlock();
    }
};
