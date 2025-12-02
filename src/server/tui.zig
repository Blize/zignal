const std = @import("std");
const vaxis = @import("vaxis");
const posix = std.posix;
const net = std.net;

const config = @import("../config.zig");
const utils = @import("../utils.zig");

const Cell = vaxis.Cell;
const Key = vaxis.Key;
const Window = vaxis.Window;
const TextInput = vaxis.widgets.TextInput;

const colors = utils.colors;

/// Event types for server TUI
const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

/// Log entry with timestamp and level
pub const LogEntry = struct {
    message: []const u8,
    timestamp: i64,
    level: Level,
    allocator: std.mem.Allocator,

    pub const Level = enum {
        info,
        warn,
        err,
        debug,

        pub fn toString(self: Level) []const u8 {
            return switch (self) {
                .info => "INFO",
                .warn => "WARN",
                .err => "ERR ",
                .debug => "DBG ",
            };
        }

        pub fn color(self: Level) Cell.Color {
            return switch (self) {
                .info => colors.zig,
                .warn => .{ .rgb = .{ 229, 192, 123 } }, // Yellow
                .err => .{ .rgb = .{ 224, 108, 117 } }, // Red
                .debug => colors.zig_dim,
            };
        }
    };

    pub fn create(allocator: std.mem.Allocator, message: []const u8, level: Level) !LogEntry {
        const owned = try allocator.dupe(u8, message);
        return .{
            .message = owned,
            .timestamp = std.time.timestamp(),
            .level = level,
            .allocator = allocator,
        };
    }

    pub fn destroy(self: *LogEntry) void {
        self.allocator.free(self.message);
    }

    pub fn getTimestampStr(self: *const LogEntry, buf: []u8) []const u8 {
        return utils.time.formatTimestamp(self.timestamp, buf);
    }
};

/// Server TUI for monitoring
pub const ServerTui = struct {
    allocator: std.mem.Allocator,

    // Vaxis components
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,

    // Server info
    ip: []const u8,
    port: *u16,
    connected: *usize,
    max_clients: usize,

    // Display buffers (persistent for rendering)
    port_display: [8]u8,
    port_display_len: usize,
    conn_display: [32]u8,
    conn_display_len: usize,

    // Log state
    logs: std.ArrayList(LogEntry),
    filter_input: TextInput,
    scroll_offset: usize,

    // Running state
    running: *bool,

    // Thread-safe log queue
    pending_logs: std.ArrayList(struct { msg: []const u8, level: LogEntry.Level }),
    log_mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        ip: []const u8,
        port: *u16,
        connected: *usize,
        max_clients: usize,
        running: *bool,
    ) !*ServerTui {
        const self = try allocator.create(ServerTui);
        errdefer allocator.destroy(self);

        var tty_buf: [1024]u8 = undefined;
        var tty = try vaxis.Tty.init(&tty_buf);
        errdefer tty.deinit();

        var vx = try vaxis.Vaxis.init(allocator, .{});
        errdefer vx.deinit(allocator, tty.writer());

        self.* = .{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .ip = ip,
            .port = port,
            .connected = connected,
            .max_clients = max_clients,
            .port_display = undefined,
            .port_display_len = 0,
            .conn_display = undefined,
            .conn_display_len = 0,
            .logs = .{},
            .filter_input = TextInput.init(allocator),
            .scroll_offset = 0,
            .running = running,
            .pending_logs = .{},
            .log_mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *ServerTui) void {
        // Clean up logs
        for (self.logs.items) |*entry| {
            entry.destroy();
        }
        self.logs.deinit(self.allocator);

        // Clean up pending logs
        self.log_mutex.lock();
        for (self.pending_logs.items) |item| {
            self.allocator.free(item.msg);
        }
        self.pending_logs.deinit(self.allocator);
        self.log_mutex.unlock();

        self.filter_input.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();

        self.allocator.destroy(self);
    }

    pub fn run(self: *ServerTui) !void {
        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();

        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

        try self.addLog("Server TUI started", .info);

        while (self.running.*) {
            // Process pending logs from server thread
            self.processPendingLogs();

            // Poll for events
            while (loop.tryEvent()) |event| {
                try self.handleEvent(event);
            }

            try self.render();

            std.Thread.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }

    /// Queue a log message from another thread
    pub fn queueLog(self: *ServerTui, message: []const u8, level: LogEntry.Level) void {
        const owned = self.allocator.dupe(u8, message) catch return;

        self.log_mutex.lock();
        defer self.log_mutex.unlock();

        self.pending_logs.append(self.allocator, .{ .msg = owned, .level = level }) catch {
            self.allocator.free(owned);
        };
    }

    fn processPendingLogs(self: *ServerTui) void {
        self.log_mutex.lock();
        defer self.log_mutex.unlock();

        for (self.pending_logs.items) |item| {
            self.addLog(item.msg, item.level) catch {};
            self.allocator.free(item.msg);
        }
        self.pending_logs.clearRetainingCapacity();
    }

    fn handleEvent(self: *ServerTui, event: Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.running.* = false;
                    return;
                }

                if (key.matches('l', .{ .ctrl = true })) {
                    self.vx.queueRefresh();
                    return;
                }

                // Clear filter with Escape
                if (key.matches(Key.escape, .{})) {
                    self.filter_input.buf.clearRetainingCapacity();
                    return;
                }

                // Scroll logs
                if (key.matches(Key.page_up, .{})) {
                    if (self.scroll_offset < self.logs.items.len) {
                        self.scroll_offset += 5;
                    }
                    return;
                }

                if (key.matches(Key.page_down, .{})) {
                    if (self.scroll_offset >= 5) {
                        self.scroll_offset -= 5;
                    } else {
                        self.scroll_offset = 0;
                    }
                    return;
                }

                // Pass to filter input
                try self.filter_input.update(.{ .key_press = key });
            },
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
            },
            else => {},
        }
    }

    fn render(self: *ServerTui) !void {
        const win = self.vx.window();
        win.clear();

        const width = win.width;
        const height = win.height;

        if (height < 12 or width < 50) {
            return; // Terminal too small
        }

        const border_style: Cell.Style = .{ .fg = colors.zig };
        const title_style: Cell.Style = .{ .fg = colors.background, .bg = colors.zig, .bold = true };

        // === TITLE BAR ===
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            win.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = title_style });
        }
        const title_text = " ⚡ ZIGNAL SERVER ";
        const title_start: u16 = if (width > title_text.len) @intCast((width - title_text.len) / 2) else 0;
        const title_segment = [_]Cell.Segment{.{ .text = title_text, .style = title_style }};
        _ = win.print(&title_segment, .{ .col_offset = title_start });

        // === INFO BOX ===
        const info_height: u16 = 5;
        const info_box = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = width,
            .height = info_height,
            .border = .{ .where = .all, .style = border_style },
        });
        self.renderInfoBox(info_box);

        // === FILTER INPUT ===
        const filter_height: u16 = 3;
        const filter_row: u16 = 1 + info_height;
        const filter_box = win.child(.{
            .x_off = 0,
            .y_off = filter_row,
            .width = width,
            .height = filter_height,
            .border = .{ .where = .all, .style = border_style },
        });
        self.renderFilterBox(filter_box);

        // === LOGS BOX ===
        const logs_row: u16 = filter_row + filter_height;
        const logs_height: u16 = @intCast(@max(1, height - logs_row - 2));
        const logs_box = win.child(.{
            .x_off = 0,
            .y_off = logs_row,
            .width = width,
            .height = logs_height,
            .border = .{ .where = .all, .style = border_style },
        });
        self.renderLogs(logs_box, logs_height - 2);

        // === STATUS BAR ===
        const status_style: Cell.Style = .{ .fg = colors.zig_dim };
        const status_row: u16 = @intCast(height - 1);
        const status_text = " PageUp/Down: Scroll | Esc: Clear Filter | Ctrl+C: Shutdown ";

        for (status_text, 0..) |char, i| {
            if (i >= width) break;
            win.writeCell(@intCast(i), status_row, .{
                .char = .{ .grapheme = &[_]u8{char}, .width = 1 },
                .style = status_style,
            });
        }

        try self.vx.render(self.tty.writer());
    }

    fn renderInfoBox(self: *ServerTui, area: Window) void {
        const label_style: Cell.Style = .{ .fg = colors.zig, .bold = true };
        const value_style: Cell.Style = .{ .fg = colors.text };
        const connected_style: Cell.Style = .{
            .fg = if (self.connected.* > 0) colors.connected else colors.zig_dim,
            .bold = true,
        };

        // Row 0: IP
        const ip_label = [_]Cell.Segment{
            .{ .text = "  IP: ", .style = label_style },
            .{ .text = self.ip, .style = value_style },
        };
        _ = area.print(&ip_label, .{ .row_offset = 0 });

        // Row 1: Port - format into persistent buffer
        const port_text = std.fmt.bufPrint(&self.port_display, "{d}", .{self.port.*}) catch "?";
        self.port_display_len = port_text.len;
        const port_label = [_]Cell.Segment{
            .{ .text = "  Port: ", .style = label_style },
            .{ .text = self.port_display[0..self.port_display_len], .style = value_style },
        };
        _ = area.print(&port_label, .{ .row_offset = 1 });

        // Row 2: Connected - format into persistent buffer
        const conn_text = std.fmt.bufPrint(&self.conn_display, "{d}/{d}", .{ self.connected.*, self.max_clients }) catch "?/?";
        self.conn_display_len = conn_text.len;
        const conn_label = [_]Cell.Segment{
            .{ .text = "  Connected: ", .style = label_style },
            .{ .text = self.conn_display[0..self.conn_display_len], .style = connected_style },
        };
        _ = area.print(&conn_label, .{ .row_offset = 2 });
    }

    fn renderFilterBox(self: *ServerTui, area: Window) void {
        const label_style: Cell.Style = .{ .fg = colors.zig, .bold = true };

        // Label
        const label = [_]Cell.Segment{.{ .text = " Filter: ", .style = label_style }};
        _ = area.print(&label, .{ .row_offset = 0 });

        // Input area (after label)
        const input_area = area.child(.{
            .x_off = 9,
            .y_off = 0,
            .width = if (area.width > 11) area.width - 11 else 1,
            .height = 1,
        });
        self.filter_input.draw(input_area);
    }

    fn renderLogs(self: *ServerTui, area: Window, max_lines: u16) void {
        // Get current filter
        const filter_first = self.filter_input.buf.firstHalf();
        const filter_second = self.filter_input.buf.secondHalf();
        var filter_buf: [256]u8 = undefined;
        const filter_len = filter_first.len + filter_second.len;
        if (filter_len > 0 and filter_len <= filter_buf.len) {
            @memcpy(filter_buf[0..filter_first.len], filter_first);
            @memcpy(filter_buf[filter_first.len..filter_len], filter_second);
        }
        const filter = if (filter_len > 0 and filter_len <= filter_buf.len) filter_buf[0..filter_len] else "";

        // Collect filtered logs
        var filtered_indices: [512]usize = undefined;
        var filtered_count: usize = 0;

        for (self.logs.items, 0..) |entry, i| {
            // Apply filter
            if (filter.len > 0) {
                if (std.mem.indexOf(u8, entry.message, filter) == null) {
                    continue;
                }
            }
            if (filtered_count < filtered_indices.len) {
                filtered_indices[filtered_count] = i;
                filtered_count += 1;
            }
        }

        if (filtered_count == 0) {
            const empty_style: Cell.Style = .{ .fg = colors.zig_dim, .italic = true };
            const empty = [_]Cell.Segment{.{ .text = "  No logs to display", .style = empty_style }};
            _ = area.print(&empty, .{ .row_offset = 0 });
            return;
        }

        // Calculate visible range (from bottom with scroll offset)
        const start_idx = if (filtered_count > self.scroll_offset) filtered_count - self.scroll_offset else 0;
        const visible_count = @min(start_idx, max_lines);
        const display_start = if (start_idx > visible_count) start_idx - visible_count else 0;

        var row: u16 = 0;
        var i: usize = display_start;
        while (i < start_idx and row < max_lines) : (i += 1) {
            const entry = &self.logs.items[filtered_indices[i]];

            var timestamp_buf: [8]u8 = undefined;
            const timestamp = entry.getTimestampStr(&timestamp_buf);

            const timestamp_style: Cell.Style = .{ .fg = colors.timestamp };
            const level_style: Cell.Style = .{ .fg = entry.level.color(), .bold = true };
            const msg_style: Cell.Style = .{ .fg = colors.text };

            const segments = [_]Cell.Segment{
                .{ .text = " ", .style = .{} },
                .{ .text = timestamp, .style = timestamp_style },
                .{ .text = " [", .style = .{ .fg = colors.zig_dim } },
                .{ .text = entry.level.toString(), .style = level_style },
                .{ .text = "] ", .style = .{ .fg = colors.zig_dim } },
                .{ .text = entry.message, .style = msg_style },
            };
            _ = area.print(&segments, .{ .row_offset = row, .wrap = .word });

            row += 1;
        }
    }

    fn addLog(self: *ServerTui, message: []const u8, level: LogEntry.Level) !void {
        const entry = try LogEntry.create(self.allocator, message, level);
        try self.logs.append(self.allocator, entry);

        // Auto-scroll to bottom
        self.scroll_offset = 0;
    }
};
