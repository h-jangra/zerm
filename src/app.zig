const std = @import("std");
const posix = std.posix;
const terminal_mod = @import("terminal.zig");
const renderer_mod = @import("renderer.zig");
const tab_mod = @import("tab.zig");
const tree_mod = @import("tree.zig");
const input_mod = @import("input.zig");
const config = @import("config.zig");

pub var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var sigchld_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var sigterm_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    sigwinch_received.store(true, .monotonic);
}

fn handleSigchld(_: posix.SIG) callconv(.c) void {
    sigchld_received.store(true, .monotonic);
}

fn handleSigterm(_: posix.SIG) callconv(.c) void {
    sigterm_received.store(true, .monotonic);
}

fn getMilliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    terminal: terminal_mod.TerminalState,
    renderer: renderer_mod.Renderer,
    tabs: std.ArrayList(*tab_mod.Tab),
    active_tab_index: usize = 0,
    next_tab_id: u32 = 1,
    should_exit: bool = false,
    shell: ?[]const u8 = null,
    term_width: u16 = 80,
    term_height: u16 = 24,
    force_render: bool = true,

    pub fn init(allocator: std.mem.Allocator, shell_arg: ?[]const u8) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        var loaded_cfg = config.loadConfigFile(allocator);

        var effective_shell = shell_arg;
        if (effective_shell == null) {
            if (loaded_cfg.theme.custom_shell) |*sh| {
                effective_shell = std.mem.sliceTo(sh, 0);
            }
        }

        const term_state = try terminal_mod.TerminalState.init();
        const size = terminal_mod.TerminalState.getSize();

        const renderer = try renderer_mod.Renderer.init(allocator, size.cols, size.rows);
        const tabs = std.ArrayList(*tab_mod.Tab).empty;

        app.* = .{
            .allocator = allocator,
            .cfg = loaded_cfg,
            .terminal = term_state,
            .renderer = renderer,
            .tabs = tabs,
            .active_tab_index = 0,
            .next_tab_id = 1,
            .should_exit = false,
            .shell = effective_shell,
            .term_width = size.cols,
            .term_height = size.rows,
            .force_render = true,
        };

        try app.createTab();

        return app;
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.renderer.deinit();
        self.terminal.restore();
        self.cfg.deinit();
        self.allocator.destroy(self);
    }

    pub fn invalidate(self: *App) void {
        self.force_render = true;
        self.renderer.invalidate();
    }

    pub fn isDirty(self: *const App) bool {
        if (self.force_render) return true;
        if (self.active_tab_index >= self.tabs.items.len) return false;
        const tab = self.tabs.items[self.active_tab_index];
        var it = tab.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            if (pane_ptr.*.vterm.dirty) return true;
        }
        return false;
    }

    pub fn clearDirty(self: *App) void {
        self.force_render = false;
        if (self.active_tab_index >= self.tabs.items.len) return;
        const tab = self.tabs.items[self.active_tab_index];
        var it = tab.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            pane_ptr.*.vterm.dirty = false;
        }
    }

    pub fn isTabBarVisible(self: *const App) bool {
        return switch (self.cfg.theme.tab_bar_show) {
            .always => true,
            .never => false,
            .auto => self.tabs.items.len > 1,
        };
    }

    pub fn getTabArea(self: *const App) tree_mod.Rect {
        const tab_bar_h: u16 = if (self.isTabBarVisible()) 1 else 0;
        const h = if (self.term_height > tab_bar_h) self.term_height - tab_bar_h else 1;
        return .{
            .x = 0,
            .y = tab_bar_h,
            .width = self.term_width,
            .height = h,
        };
    }

    pub fn recomputeAllLayouts(self: *App) void {
        const area = self.getTabArea();
        for (self.tabs.items) |tab| {
            tab.computeLayout(area);
        }
    }

    pub fn createTab(self: *App) !void {
        const tab_id = self.next_tab_id;
        self.next_tab_id += 1;

        const area = self.getTabArea();
        const tab = try tab_mod.Tab.init(self.allocator, tab_id, area.width, area.height, self.shell);
        errdefer tab.deinit();

        try self.tabs.append(self.allocator, tab);
        self.active_tab_index = self.tabs.items.len - 1;
        self.recomputeAllLayouts();
        self.invalidate();
    }

    pub fn closeActiveTab(self: *App) void {
        if (self.tabs.items.len == 0) return;
        const tab = self.tabs.items[self.active_tab_index];
        _ = self.tabs.orderedRemove(self.active_tab_index);
        tab.deinit();

        if (self.tabs.items.len == 0) {
            self.should_exit = true;
            return;
        }

        if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        }

        self.recomputeAllLayouts();
        self.invalidate();
    }

    pub fn nextTab(self: *App) void {
        if (self.tabs.items.len <= 1) return;
        self.active_tab_index = (self.active_tab_index + 1) % self.tabs.items.len;
        self.invalidate();
    }

    pub fn prevTab(self: *App) void {
        if (self.tabs.items.len <= 1) return;
        if (self.active_tab_index == 0) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else {
            self.active_tab_index -= 1;
        }
        self.invalidate();
    }

    pub fn handleResize(self: *App) void {
        const size = terminal_mod.TerminalState.getSize();
        self.term_width = size.cols;
        self.term_height = size.rows;
        self.renderer.resize(size.cols, size.rows) catch {};
        self.recomputeAllLayouts();
        self.invalidate();
    }

    pub fn setupSignals() void {
        const sa_winch = posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa_winch, null);

        const sa_chld = posix.Sigaction{
            .handler = .{ .handler = handleSigchld },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.CHLD, &sa_chld, null);

        const sa_term = posix.Sigaction{
            .handler = .{ .handler = handleSigterm },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sa_term, null);
        posix.sigaction(posix.SIG.TERM, &sa_term, null);
        posix.sigaction(posix.SIG.HUP, &sa_term, null);
    }

    pub fn run(self: *App) !void {
        setupSignals();
        try self.terminal.enableRawMode();
        self.handleResize();

        var read_buf: [8192]u8 = undefined;
        var pty_read_buf: [65536]u8 = undefined;
        var pollfds_buf: [64]posix.pollfd = undefined;
        var last_render_time: i64 = getMilliTimestamp();
        const FRAME_TIME_MS: i64 = 8; // ~125 FPS for ultra-smooth animations and instant responsiveness

        try self.renderer.render(self.tabs.items, self.active_tab_index, &self.cfg.theme);
        self.clearDirty();

        while (!self.should_exit and self.tabs.items.len > 0) {
            if (sigwinch_received.swap(false, .monotonic)) {
                self.handleResize();
            }

            if (sigterm_received.load(.monotonic)) {
                break;
            }

            if (sigchld_received.swap(false, .monotonic)) {
                self.checkDeadChildren();
                if (self.tabs.items.len == 0 or self.should_exit) break;
            }

            var poll_count: usize = 0;
            pollfds_buf[poll_count] = .{
                .fd = posix.STDIN_FILENO,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            poll_count += 1;

            const Mapping = struct { tab_idx: usize, pane_id: u32 };
            var fd_mappings: [63]Mapping = undefined;

            for (self.tabs.items, 0..) |tab, t_i| {
                var it = tab.panes.valueIterator();
                while (it.next()) |pane_ptr| {
                    if (poll_count < pollfds_buf.len) {
                        pollfds_buf[poll_count] = .{
                            .fd = pane_ptr.*.pty.master,
                            .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                            .revents = 0,
                        };
                        fd_mappings[poll_count - 1] = .{ .tab_idx = t_i, .pane_id = pane_ptr.*.id };
                        poll_count += 1;
                    }
                }
            }

            const now = getMilliTimestamp();
            const elapsed = now - last_render_time;
            const poll_timeout: i32 = if (self.isDirty())
                @intCast(@max(0, FRAME_TIME_MS - elapsed))
            else
                50;

            const poll_res = posix.poll(pollfds_buf[0..poll_count], poll_timeout) catch |err| {
                if (err == error.Interrupted) continue;
                continue;
            };

            var user_input_received = false;
            var pty_output_received = false;
            if ((pollfds_buf[0].revents & posix.POLL.IN) != 0) {
                const n_read = posix.system.read(posix.STDIN_FILENO, &read_buf, read_buf.len);
                const n_val: isize = @bitCast(n_read);
                if (n_val > 0) {
                    user_input_received = true;
                    const input_slice = read_buf[0..@intCast(n_val)];
                    self.handleInput(input_slice);

                    if (self.active_tab_index < self.tabs.items.len) {
                        const tab = self.tabs.items[self.active_tab_index];
                        if (tab.getActivePane()) |pane| {
                            if (pane.readPtyOutput(&pty_read_buf)) {
                                pty_output_received = true;
                            }
                        }
                    }
                }
            }

            var dead_panes: [32]Mapping = undefined;
            var dead_count: usize = 0;

            var p_i: usize = 1;
            while (p_i < poll_count) : (p_i += 1) {
                const rev = pollfds_buf[p_i].revents;
                const map = fd_mappings[p_i - 1];

                if ((rev & posix.POLL.IN) != 0) {
                    if (map.tab_idx < self.tabs.items.len) {
                        const tab = self.tabs.items[map.tab_idx];
                        if (tab.panes.get(map.pane_id)) |pane| {
                            if (pane.readPtyOutput(&pty_read_buf)) {
                                pty_output_received = true;
                            } else {
                                if (dead_count < dead_panes.len) {
                                    dead_panes[dead_count] = map;
                                    dead_count += 1;
                                }
                            }
                        }
                    }
                }

                if ((rev & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                    if (dead_count < dead_panes.len) {
                        dead_panes[dead_count] = map;
                        dead_count += 1;
                    }
                }
            }

            if (dead_count > 0) {
                var d_idx: usize = 0;
                while (d_idx < dead_count) : (d_idx += 1) {
                    const map = dead_panes[d_idx];
                    self.removePaneById(map.tab_idx, map.pane_id);
                }
            }

            if (self.isDirty()) {
                const cur_time = getMilliTimestamp();
                const cur_elapsed = cur_time - last_render_time;
                if (user_input_received or pty_output_received or poll_res == 0 or cur_elapsed >= FRAME_TIME_MS or self.force_render) {
                    try self.renderer.render(self.tabs.items, self.active_tab_index, &self.cfg.theme);
                    self.clearDirty();
                    last_render_time = cur_time;
                }
            }
        }
    }

    fn handleInput(self: *App, input: []const u8) void {
        var idx: usize = 0;
        while (idx < input.len) {
            if (std.mem.startsWith(u8, input[idx..], "\x1b[<")) {
                var end_pos = idx + 3;
                while (end_pos < input.len and input[end_pos] != 'M' and input[end_pos] != 'm') : (end_pos += 1) {}
                if (end_pos < input.len and (input[end_pos] == 'M' or input[end_pos] == 'm')) {
                    const mouse_seq = input[idx .. end_pos + 1];
                    if (input_mod.parseSgrMouse(mouse_seq)) |m| {
                        self.handleMouse(m);
                    }
                    idx = end_pos + 1;
                    continue;
                }
            }

            if (input[idx] == 0x1b) {
                if (idx + 1 < input.len and input[idx + 1] == '[') {
                    var end_pos = idx + 2;
                    while (end_pos < input.len and (input[end_pos] < 0x40 or input[end_pos] > 0x7e)) : (end_pos += 1) {}
                    if (end_pos < input.len) {
                        const csi_seq = input[idx .. end_pos + 1];
                        const parsed = input_mod.parseInput(csi_seq, &self.cfg);
                        self.dispatchParsedInput(parsed);
                        idx = end_pos + 1;
                        continue;
                    }
                }
                const parsed = input_mod.parseInput(input[idx .. idx + 1], &self.cfg);
                self.dispatchParsedInput(parsed);
                idx += 1;
                continue;
            }

            const parsed = input_mod.parseInput(input[idx .. idx + 1], &self.cfg);
            self.dispatchParsedInput(parsed);
            idx += 1;
        }
    }

    fn clearAllSelections(self: *App) void {
        for (self.tabs.items) |tab| {
            var it = tab.panes.valueIterator();
            while (it.next()) |pane_ptr| {
                if (pane_ptr.*.selection.active or pane_ptr.*.selection.selecting) {
                    pane_ptr.*.clearSelection();
                    self.invalidate();
                }
            }
        }
    }

    fn dispatchParsedInput(self: *App, parsed: input_mod.InputResult) void {
        switch (parsed) {
            .action => |act| {
                if (act != .copy) {
                    self.clearAllSelections();
                }
                self.executeAction(act);
            },
            .mouse => |m| {
                self.handleMouse(m);
            },
            .raw => |raw_bytes| {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        if (pane.selection.active) {
                            if (raw_bytes.len == 1 and raw_bytes[0] == 0x03) {
                                // Ctrl+C with active selection: copy to clipboard and clear selection
                                pane.copySelectionToClipboard(self.allocator);
                                pane.clearSelection();
                                self.invalidate();
                                return;
                            }
                            pane.clearSelection();
                            self.invalidate();
                        }
                        if (pane.vterm.scroll_offset > 0) {
                            pane.vterm.scrollToBottom();
                            self.invalidate();
                        }
                        pane.writeToPty(raw_bytes);
                    }
                }
            },
            .single_byte => |b| {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        if (pane.selection.active) {
                            if (b == 0x03) {
                                // Ctrl+C with active selection: copy to clipboard and clear selection
                                pane.copySelectionToClipboard(self.allocator);
                                pane.clearSelection();
                                self.invalidate();
                                return;
                            }
                            pane.clearSelection();
                            self.invalidate();
                        }
                        if (pane.vterm.scroll_offset > 0) {
                            pane.vterm.scrollToBottom();
                            self.invalidate();
                        }
                        pane.writeToPty(&[_]u8{b});
                    }
                }
            },
        }
    }

    fn handleMouse(self: *App, m: input_mod.MouseEvent) void {
        const tab_bar_h: u16 = if (self.isTabBarVisible()) 1 else 0;

        if (tab_bar_h > 0 and m.y == 1) {
            self.clearAllSelections();
            if (!m.release and (m.btn & 3) == 0) {
                self.handleTabBarClick(m.x);
            }
            return;
        }

        if (self.active_tab_index < self.tabs.items.len) {
            const tab = self.tabs.items[self.active_tab_index];
            if (tab.root) |root| {
                const sx = if (m.x > 0) m.x - 1 else 0;
                const sy = if (m.y > 0) m.y - 1 else 0;

                var leaf_buf: [64]*tree_mod.Node = undefined;
                var leaf_count: usize = 0;
                root.collectLeavesSlice(&leaf_buf, &leaf_count);

                var target_leaf: ?*tree_mod.Node = null;
                for (leaf_buf[0..leaf_count]) |leaf| {
                    if (leaf.rect.contains(sx, sy)) {
                        target_leaf = leaf;
                        break;
                    }
                }
                if (target_leaf == null and leaf_count > 0) {
                    var min_dist: i32 = 999999;
                    for (leaf_buf[0..leaf_count]) |leaf| {
                        const c = leaf.rect.center();
                        const dx = c.cx - @as(i32, sx);
                        const dy = c.cy - @as(i32, sy);
                        const dist = dx * dx + dy * dy;
                        if (dist < min_dist) {
                            min_dist = dist;
                            target_leaf = leaf;
                        }
                    }
                }

                if (target_leaf) |leaf| {
                    const target_pane_id = leaf.data.leaf.id;
                    if (tab.focused_pane_id != target_pane_id) {
                        tab.focused_pane_id = target_pane_id;
                        self.invalidate();
                    }

                    if (tab.panes.get(target_pane_id)) |pane| {
                        const is_scroll_up = (m.btn & 64) != 0 and (m.btn & 3) == 0;
                        const is_scroll_down = (m.btn & 64) != 0 and (m.btn & 3) == 1;
                        const has_shift = (m.btn & 4) != 0;
                        const is_motion = (m.btn & 32) != 0;
                        const is_release = m.release or (m.btn & 3) == 3;
                        const button = m.btn & 3;
                        const is_left = (button == 0 and (m.btn & 64) == 0);

                        if (is_scroll_up) {
                            if (pane.vterm.mouse_reporting and !has_shift) {
                                self.forwardMouseToPane(pane, leaf.rect, m, sx, sy);
                            } else {
                                pane.vterm.scrollUp(3);
                                self.invalidate();
                            }
                            return;
                        } else if (is_scroll_down) {
                            if (pane.vterm.mouse_reporting and !has_shift) {
                                self.forwardMouseToPane(pane, leaf.rect, m, sx, sy);
                            } else {
                                pane.vterm.scrollDown(3);
                                self.invalidate();
                            }
                            return;
                        }

                        if (pane.vterm.mouse_reporting and !has_shift) {
                            self.forwardMouseToPane(pane, leaf.rect, m, sx, sy);
                        } else {
                            // Clear selection on other panes
                            for (self.tabs.items) |t| {
                                var it = t.panes.valueIterator();
                                while (it.next()) |other_ptr| {
                                    if (other_ptr.*.id != pane.id and (other_ptr.*.selection.active or other_ptr.*.selection.selecting)) {
                                        other_ptr.*.clearSelection();
                                        self.invalidate();
                                    }
                                }
                            }

                            const pane_x: u16 = if (sx >= leaf.rect.x) sx - leaf.rect.x else 0;
                            const pane_y: u16 = if (sy >= leaf.rect.y) sy - leaf.rect.y else 0;

                            if (is_release) {
                                if (pane.selection.selecting) {
                                    pane.selection.selecting = false;
                                    if (pane.selection.start_x == pane.selection.end_x and pane.selection.start_y == pane.selection.end_y) {
                                        // Single click with no movement: clear selection
                                        pane.selection.active = false;
                                    } else {
                                        // Mouse drag complete: activate selection and auto-copy to clipboard
                                        pane.selection.active = true;
                                        pane.copySelectionToClipboard(self.allocator);
                                    }
                                    self.invalidate();
                                }
                            } else if (is_motion) {
                                // Mouse drag motion (with any modifier: Shift, Ctrl, Alt)
                                if (pane.selection.selecting) {
                                    pane.selection.end_x = pane_x;
                                    pane.selection.end_y = pane_y;
                                    if (pane.selection.start_x != pane.selection.end_x or pane.selection.start_y != pane.selection.end_y) {
                                        pane.selection.active = true;
                                    }
                                    self.invalidate();
                                }
                            } else if (is_left and !m.release) {
                                // Mouse button down: start selection
                                pane.selection = .{
                                    .start_x = pane_x,
                                    .start_y = pane_y,
                                    .end_x = pane_x,
                                    .end_y = pane_y,
                                    .active = false,
                                    .selecting = true,
                                };
                                self.invalidate();
                            } else {
                                // Right click or middle click
                                if (pane.selection.active or pane.selection.selecting) {
                                    pane.clearSelection();
                                    self.invalidate();
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn forwardMouseToPane(self: *App, pane: *tab_mod.Pane, rect: tree_mod.Rect, m: input_mod.MouseEvent, sx: u16, sy: u16) void {
        _ = self;
        const pane_x = if (sx >= rect.x) (sx - rect.x) + 1 else 1;
        const pane_y = if (sy >= rect.y) (sy - rect.y) + 1 else 1;

        var mouse_buf: [64]u8 = undefined;
        const term_char: u8 = if (m.release) 'm' else 'M';
        const translated = std.fmt.bufPrint(&mouse_buf, "\x1b[<{d};{d};{d}{c}", .{
            m.btn,
            pane_x,
            pane_y,
            term_char,
        }) catch return;

        pane.writeToPty(translated);
    }

    fn handleTabBarClick(self: *App, click_x: u16) void {
        var x: u16 = 1;

        for (self.tabs.items, 0..) |tab, i| {
            if (i > 0) x += 1;

            const is_active = (i == self.active_tab_index);
            const fmt_pattern = if (is_active) self.cfg.theme.getActiveTabFormat() else self.cfg.theme.getInactiveTabFormat();

            var label_buf: [128]u8 = undefined;
            const label = config.formatTabLabel(fmt_pattern, i + 1, tab.getTitle(), is_active, &label_buf);
            const tab_len: u16 = @intCast(label.len);

            if (click_x >= x and click_x < x + tab_len) {
                self.active_tab_index = i;
                self.invalidate();
                return;
            }
            x += tab_len;
        }
    }

    fn executeAction(self: *App, act: config.Action) void {
        const area = self.getTabArea();
        const delta = self.cfg.theme.resize_delta;
        switch (act) {
            .copy => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        if (pane.selection.active) {
                            pane.copySelectionToClipboard(self.allocator);
                            pane.clearSelection();
                            self.invalidate();
                        }
                    }
                }
            },
            .new_tab => {
                self.createTab() catch {};
            },
            .close_pane => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    const should_close_tab = tab.closeActivePane(area);
                    if (should_close_tab) {
                        self.closeActiveTab();
                    }
                }
            },
            .next_tab => self.nextTab(),
            .prev_tab => self.prevTab(),
            .split_vertical => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    tab.splitActivePane(.vertical, area) catch {};
                    self.invalidate();
                }
            },
            .split_horizontal => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    tab.splitActivePane(.horizontal, area) catch {};
                    self.invalidate();
                }
            },
            .focus_up => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].navigateFocus(.up);
                    self.invalidate();
                }
            },
            .focus_down => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].navigateFocus(.down);
                    self.invalidate();
                }
            },
            .focus_left => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].navigateFocus(.left);
                    self.invalidate();
                }
            },
            .focus_right => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].navigateFocus(.right);
                    self.invalidate();
                }
            },
            .resize_up => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].resizeActivePane(.up, delta, area);
                    self.invalidate();
                }
            },
            .resize_down => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].resizeActivePane(.down, delta, area);
                    self.invalidate();
                }
            },
            .resize_left => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].resizeActivePane(.left, delta, area);
                    self.invalidate();
                }
            },
            .resize_right => {
                if (self.active_tab_index < self.tabs.items.len) {
                    self.tabs.items[self.active_tab_index].resizeActivePane(.right, delta, area);
                    self.invalidate();
                }
            },
            .scroll_page_up => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        const step = @max(1, pane.rect.height / 2);
                        pane.vterm.scrollUp(step);
                        self.invalidate();
                    }
                }
            },
            .scroll_page_down => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        const step = @max(1, pane.rect.height / 2);
                        pane.vterm.scrollDown(step);
                        self.invalidate();
                    }
                }
            },
            .scroll_to_bottom => {
                if (self.active_tab_index < self.tabs.items.len) {
                    const tab = self.tabs.items[self.active_tab_index];
                    if (tab.getActivePane()) |pane| {
                        pane.vterm.scrollToBottom();
                        self.invalidate();
                    }
                }
            },
        }
    }

    fn removePaneById(self: *App, tab_idx: usize, pane_id: u32) void {
        if (tab_idx >= self.tabs.items.len) return;
        const tab = self.tabs.items[tab_idx];
        const should_close_tab = tab.closePaneById(pane_id, self.getTabArea());
        if (should_close_tab) {
            _ = self.tabs.orderedRemove(tab_idx);
            tab.deinit();
            if (self.tabs.items.len == 0) {
                self.should_exit = true;
                return;
            }
            if (self.active_tab_index >= self.tabs.items.len) {
                self.active_tab_index = self.tabs.items.len - 1;
            }
            self.recomputeAllLayouts();
            self.invalidate();
        }
    }

    fn checkDeadChildren(self: *App) void {
        var t_i: usize = 0;
        while (t_i < self.tabs.items.len) {
            const tab = self.tabs.items[t_i];
            var dead_pane_id: ?u32 = null;

            var it = tab.panes.valueIterator();
            while (it.next()) |pane_ptr| {
                if (!pane_ptr.*.pty.checkAlive()) {
                    dead_pane_id = pane_ptr.*.id;
                    break;
                }
            }

            if (dead_pane_id) |pid| {
                self.removePaneById(t_i, pid);
                t_i = 0;
            } else {
                t_i += 1;
            }
        }
    }
};
