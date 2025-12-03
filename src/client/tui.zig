const std = @import("std");
const vaxis = @import("vaxis");
const posix = std.posix;

const config = @import("../config.zig");
const utils = @import("../utils.zig");
const Writer = @import("../writer.zig").Writer;
const Reader = @import("../reader.zig").Reader;
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

/// Event types for our TUI application
const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// TUI Client for the chat application
pub const TuiClient = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    username: []const u8,

    vx: vaxis.Vaxis,
    tty: vaxis.Tty,

    // Chat state
    messages: ScrollableList(ChatMessage),
    text_input: InputField,

    // Running state
    running: bool,
    connected: bool,

    // Receiver thread
    receiver_thread: ?std.Thread,

    // Thread-safe message queue
    pending_messages: std.ArrayList([]const u8),
    message_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t, username: []const u8) !*TuiClient {
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
            .username = username,
            .vx = vx,
            .tty = tty,
            .messages = ScrollableList(ChatMessage).init(allocator),
            .text_input = InputField.init(allocator),
            .running = true,
            .connected = true,
            .receiver_thread = null,
            .pending_messages = .{},
            .message_mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *TuiClient) void {
        self.running = false;
        posix.close(self.socket);

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

            // Poll for events with timeout
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

                // Handle Enter key - send message
                if (key.matches(Key.enter, .{})) {
                    try self.sendMessage();
                    return;
                }

                // Handle scroll
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

                // Pass to text input widget
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

        // Border style using Zig color
        const border_style: Cell.Style = .{
            .fg = colors.zig,
        };

        // Draw title bar
        const title_style: Cell.Style = .{
            .fg = colors.background,
            .bg = colors.zig,
            .bold = true,
        };

        // Fill title row
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

        // === CHAT VIEW with border ===
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

        // Render messages inside chat area (account for border)
        self.renderMessages(chat_area, chat_height - 2);

        // === INPUT AREA with border ===
        const input_row: u16 = 1 + chat_height;

        // Input box with border
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

        // Draw text input inside the bordered box
        self.text_input.draw(input_box);

        // === STATUS BAR ===
        const status_style: Cell.Style = .{
            .fg = colors.zig_dim,
        };
        const status_row: u16 = @intCast(height - 1);

        const status_text = " Enter: Send | PageUp/Down: Scroll | Ctrl+C: Exit ";

        for (status_text, 0..) |char, i| {
            if (i >= width) break;
            win.writeCell(@intCast(i), status_row, .{
                .char = .{ .grapheme = &[_]u8{char}, .width = 1 },
                .style = status_style,
            });
        }

        try self.vx.render(self.tty.writer());
    }

    fn renderMessages(self: *TuiClient, area: Window, max_lines: u16) void {
        if (self.messages.count() == 0) return;

        // Render function for each message
        const renderMessage = struct {
            pub fn render(msg: *const ChatMessage, row: u16, area_: Window) void {
                var timestamp_buf: [8]u8 = undefined;
                const timestamp = msg.getTimestampStr(&timestamp_buf);

                const timestamp_style: Cell.Style = .{ .fg = colors.timestamp };

                // Determine message style based on content
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
                    // Render username with unique color, message in text color
                    const username_part = msg.content[0..colon_pos];
                    const separator = ": ";
                    const message_part = msg.content[colon_pos + 2 ..];

                    // Get color based on username hash
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
                    // Regular message
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

        var formatted_message: [BUFFER_SIZE]u8 = undefined;
        const display_username = if (self.username.len > 0) self.username else "Anonymous";

        const formatted = std.fmt.bufPrint(&formatted_message, "{s}: {s}", .{
            display_username,
            message,
        }) catch {
            return;
        };

        try self.addMessage(formatted);

        const writer = Writer.init(self.socket);
        writer.writeMessage(formatted) catch |err| {
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

        // Auto-scroll to bottom when new message arrives
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
            const message = Reader.readClientMessage(self.socket, &message_buffer) catch |err| {
                if (self.running) {
                    var err_buf: [64]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "[System] Connection error: {}", .{err}) catch "[System] Connection error";
                    const owned = self.allocator.dupe(u8, err_msg) catch continue;

                    self.message_mutex.lock();
                    self.pending_messages.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                    };
                    self.message_mutex.unlock();

                    self.connected = false;
                    self.running = false;
                }
                break;
            };

            if (message == null) {
                const owned = self.allocator.dupe(u8, "[System] Disconnected from server") catch continue;

                self.message_mutex.lock();
                self.pending_messages.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                };
                self.message_mutex.unlock();

                self.connected = false;
                self.running = false;
                break;
            }

            const owned = self.allocator.dupe(u8, message.?) catch continue;

            self.message_mutex.lock();
            self.pending_messages.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
            self.message_mutex.unlock();
        }
    }
};
