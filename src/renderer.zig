const std = @import("std");
const posix = std.posix;
const vterm_mod = @import("vterm.zig");
const tree_mod = @import("tree.zig");
const tab_mod = @import("tab.zig");
const config = @import("config.zig");

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    front: []vterm_mod.Cell,
    back: []vterm_mod.Cell,
    out_buf: std.ArrayList(u8),
    current_cursor_shape: u8 = 0,
    prev_cursor_x: u16 = 0xFFFF,
    prev_cursor_y: u16 = 0xFFFF,
    prev_cursor_visible: bool = true,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        const w = @max(1, width);
        const h = @max(1, height);
        const size = @as(usize, w) * @as(usize, h);

        const front = try allocator.alloc(vterm_mod.Cell, size);
        @memset(front, vterm_mod.Cell.empty());

        const back = try allocator.alloc(vterm_mod.Cell, size);
        @memset(back, vterm_mod.Cell.empty());

        const out_buf = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);

        return Renderer{
            .allocator = allocator,
            .width = w,
            .height = h,
            .front = front,
            .back = back,
            .out_buf = out_buf,
            .current_cursor_shape = 0,
            .prev_cursor_x = 0xFFFF,
            .prev_cursor_y = 0xFFFF,
            .prev_cursor_visible = true,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.out_buf.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        const w = @max(1, width);
        const h = @max(1, height);
        if (w == self.width and h == self.height) return;

        const size = @as(usize, w) * @as(usize, h);
        const new_front = try self.allocator.alloc(vterm_mod.Cell, size);
        @memset(new_front, vterm_mod.Cell.empty());

        const new_back = try self.allocator.alloc(vterm_mod.Cell, size);
        @memset(new_back, vterm_mod.Cell.empty());

        self.allocator.free(self.front);
        self.allocator.free(self.back);

        self.front = new_front;
        self.back = new_back;
        self.width = w;
        self.height = h;

        self.invalidate();
    }

    pub fn invalidate(self: *Renderer) void {
        @memset(self.front, .{ .char = 0 });
        self.prev_cursor_x = 0xFFFF;
        self.prev_cursor_y = 0xFFFF;
    }

    pub fn render(
        self: *Renderer,
        tabs: []*tab_mod.Tab,
        active_tab_idx: usize,
        theme: *const config.Theme,
    ) !void {
        if (tabs.len == 0 or active_tab_idx >= tabs.len) return;

        @memset(self.back, vterm_mod.Cell.empty());

        const active_tab = tabs[active_tab_idx];
        const num_tabs = tabs.len;
        const tab_bar_h: u16 = if (num_tabs > 1) 1 else 0;

        if (num_tabs > 1) {
            self.renderTabBar(tabs, active_tab_idx, theme);
        }

        var leaves = std.ArrayList(*tree_mod.Node).empty;
        defer leaves.deinit(self.allocator);
        if (active_tab.root) |r| {
            r.collectLeaves(&leaves, self.allocator) catch {};
        }

        for (leaves.items) |leaf| {
            if (active_tab.panes.get(leaf.data.leaf.id)) |pane| {
                self.blitPane(pane, leaf.rect);
            }
        }

        if (active_tab.root) |r| {
            if (leaves.items.len > 1) {
                self.renderBorders(r, active_tab.focused_pane_id, theme);
            }
        }

        try self.flushDiff(active_tab, tab_bar_h);
    }

    fn renderTabBar(self: *Renderer, tabs: []*tab_mod.Tab, active_tab_idx: usize, theme: *const config.Theme) void {
        var x: u16 = 0;
        const max_x = self.width;

        var bx: u16 = 0;
        while (bx < max_x) : (bx += 1) {
            self.back[bx] = .{
                .char = ' ',
                .fg = theme.tab_inactive_fg,
                .bg = theme.tab_bar_bg,
            };
        }

        for (tabs, 0..) |tab, i| {
            if (x >= max_x) break;

            const is_active = (i == active_tab_idx);
            const fg = if (is_active) theme.tab_active_fg else theme.tab_inactive_fg;
            const bg = if (is_active) theme.tab_active_bg else theme.tab_inactive_bg;
            const attrs = vterm_mod.Attrs{ .bold = if (is_active) theme.tab_active_bold else theme.tab_inactive_bold };

            const fmt_pattern = if (is_active) theme.getActiveTabFormat() else theme.getInactiveTabFormat();
            var label_buf: [128]u8 = undefined;
            const title = tab.getTitle();
            const label = config.formatTabLabel(fmt_pattern, i + 1, title, is_active, &label_buf);

            if (x > 0 and x < max_x) {
                self.back[x] = .{ .char = ' ', .bg = theme.tab_bar_bg };
                x += 1;
            }

            for (label) |ch| {
                if (x >= max_x) break;
                self.back[x] = .{
                    .char = ch,
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                };
                x += 1;
            }
        }
    }

    fn blitPane(self: *Renderer, pane: *const tab_mod.Pane, rect: tree_mod.Rect) void {
        const pane_w = pane.vterm.width;
        const pane_h = pane.vterm.height;

        var py: u16 = 0;
        while (py < pane_h and rect.y + py < self.height) : (py += 1) {
            const sy = rect.y + py;
            const screen_row = @as(usize, sy) * self.width;

            var px: u16 = 0;
            while (px < pane_w and rect.x + px < self.width) : (px += 1) {
                const sx = rect.x + px;
                var cell = pane.vterm.getRenderCell(px, py);
                if (pane.selection.isSelected(px, py)) {
                    cell.attrs.reverse = !cell.attrs.reverse;
                }
                self.back[screen_row + sx] = cell;
            }
        }

        if (pane.vterm.scroll_offset > 0 and pane_w >= 14 and pane_h >= 2) {
            var badge_buf: [32]u8 = undefined;
            const badge_str = std.fmt.bufPrint(&badge_buf, " [{d}/{d}] ", .{ pane.vterm.scroll_offset, pane.vterm.scrollback.items.len }) catch "";
            if (badge_str.len < pane_w) {
                const badge_x = rect.x + pane_w - @as(u16, @intCast(badge_str.len));
                const badge_y = rect.y;
                const screen_row = @as(usize, badge_y) * self.width;
                for (badge_str, 0..) |c, i| {
                    self.back[screen_row + badge_x + i] = .{
                        .char = c,
                        .fg = vterm_mod.Color.indexed(0),
                        .bg = vterm_mod.Color.indexed(11),
                        .attrs = .{ .bold = true },
                    };
                }
            }
        }
    }

    fn renderBorders(self: *Renderer, root: *tree_mod.Node, focused_pane_id: u32, theme: *const config.Theme) void {
        self.renderBordersRecursive(root, focused_pane_id, theme);
    }

    fn renderBordersRecursive(self: *Renderer, node: *tree_mod.Node, focused_pane_id: u32, theme: *const config.Theme) void {
        const chars = theme.border_style.getChars();
        switch (node.data) {
            .leaf => {},
            .split => |*s| {
                self.renderBordersRecursive(s.first, focused_pane_id, theme);
                self.renderBordersRecursive(s.second, focused_pane_id, theme);

                const is_active = (s.first.findLeaf(focused_pane_id) != null or s.second.findLeaf(focused_pane_id) != null);
                const border_fg = if (is_active) theme.border_active_fg else theme.border_inactive_fg;

                if (s.direction == .vertical) {
                    const divider_x = s.first.rect.x + s.first.rect.width;
                    if (divider_x < self.width) {
                        var y = node.rect.y;
                        while (y < node.rect.y + node.rect.height and y < self.height) : (y += 1) {
                            const idx = @as(usize, y) * self.width + divider_x;
                            const cur_char = self.back[idx].char;
                            var border_char: u21 = chars.vert;
                            if (cur_char == chars.horiz) {
                                border_char = chars.cross;
                            }
                            self.back[idx] = .{
                                .char = border_char,
                                .fg = border_fg,
                                .bg = vterm_mod.Color.defaultColor(),
                            };
                        }
                    }
                } else {
                    const divider_y = s.first.rect.y + s.first.rect.height;
                    if (divider_y < self.height) {
                        var x = node.rect.x;
                        while (x < node.rect.x + node.rect.width and x < self.width) : (x += 1) {
                            const idx = @as(usize, divider_y) * self.width + x;
                            const cur_char = self.back[idx].char;
                            var border_char: u21 = chars.horiz;
                            if (cur_char == chars.vert) {
                                border_char = chars.cross;
                            }
                            self.back[idx] = .{
                                .char = border_char,
                                .fg = border_fg,
                                .bg = vterm_mod.Color.defaultColor(),
                            };
                        }
                    }
                }
            },
        }
    }

    fn flushDiff(self: *Renderer, active_tab: *const tab_mod.Tab, tab_bar_h: u16) !void {
        _ = tab_bar_h;
        self.out_buf.clearRetainingCapacity();

        var target_cursor_x: u16 = 1;
        var target_cursor_y: u16 = 1;
        var target_cursor_visible = true;
        var target_cursor_shape: u8 = 0;

        if (active_tab.getActivePane()) |active_pane| {
            const pane_cur_x = active_pane.rect.x + active_pane.vterm.cursor_x;
            const pane_cur_y = active_pane.rect.y + active_pane.vterm.cursor_y;
            target_cursor_x = @min(self.width, pane_cur_x + 1);
            target_cursor_y = @min(self.height, pane_cur_y + 1);
            target_cursor_visible = active_pane.vterm.cursor_visible and (active_pane.vterm.scroll_offset == 0);
            target_cursor_shape = active_pane.vterm.cursor_shape;
        }

        var cells_changed = false;
        var cur_fg = vterm_mod.Color.defaultColor();
        var cur_bg = vterm_mod.Color.defaultColor();
        var cur_attrs = vterm_mod.Attrs{};
        var cursor_x: u16 = 0xFFFF;
        var cursor_y: u16 = 0xFFFF;

        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            const row_offset = @as(usize, y) * self.width;
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const idx = row_offset + x;
                const back_cell = self.back[idx];
                const front_cell = self.front[idx];

                if (!back_cell.eql(front_cell)) {
                    if (!cells_changed) {
                        cells_changed = true;
                        try self.out_buf.appendSlice(self.allocator, "\x1b[?2026h\x1b[?25l");
                    }

                    if (cursor_y != y or cursor_x != x) {
                        try self.out_buf.print(self.allocator, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                        cursor_y = y;
                        cursor_x = x;
                    }

                    if (!back_cell.attrs.eql(cur_attrs) or !back_cell.fg.eql(cur_fg) or !back_cell.bg.eql(cur_bg)) {
                        try self.applyStyle(back_cell.attrs, back_cell.fg, back_cell.bg);
                        cur_attrs = back_cell.attrs;
                        cur_fg = back_cell.fg;
                        cur_bg = back_cell.bg;
                    }

                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(back_cell.char, &utf8_buf) catch 0;
                    if (len > 0) {
                        try self.out_buf.appendSlice(self.allocator, utf8_buf[0..len]);
                    } else {
                        try self.out_buf.append(self.allocator, ' ');
                    }

                    self.front[idx] = back_cell;
                    cursor_x += 1;
                }
            }
        }

        const cursor_moved = (target_cursor_x != self.prev_cursor_x or target_cursor_y != self.prev_cursor_y);
        const shape_changed = (target_cursor_shape != self.current_cursor_shape);
        const visibility_changed = (target_cursor_visible != self.prev_cursor_visible);

        if (cells_changed) {
            try self.out_buf.appendSlice(self.allocator, "\x1b[0m");

            try self.out_buf.print(self.allocator, "\x1b[{d};{d}H", .{ target_cursor_y, target_cursor_x });
            self.prev_cursor_x = target_cursor_x;
            self.prev_cursor_y = target_cursor_y;

            if (shape_changed) {
                self.current_cursor_shape = target_cursor_shape;
                try self.out_buf.print(self.allocator, "\x1b[{d} q", .{self.current_cursor_shape});
            }

            if (target_cursor_visible) {
                try self.out_buf.appendSlice(self.allocator, "\x1b[?25h");
            } else {
                try self.out_buf.appendSlice(self.allocator, "\x1b[?25l");
            }
            self.prev_cursor_visible = target_cursor_visible;

            try self.out_buf.appendSlice(self.allocator, "\x1b[?2026l");

            _ = posix.system.write(posix.STDOUT_FILENO, self.out_buf.items.ptr, self.out_buf.items.len);
        } else if (cursor_moved or shape_changed or visibility_changed) {
            if (cursor_moved) {
                try self.out_buf.print(self.allocator, "\x1b[{d};{d}H", .{ target_cursor_y, target_cursor_x });
                self.prev_cursor_x = target_cursor_x;
                self.prev_cursor_y = target_cursor_y;
            }

            if (shape_changed) {
                self.current_cursor_shape = target_cursor_shape;
                try self.out_buf.print(self.allocator, "\x1b[{d} q", .{self.current_cursor_shape});
            }

            if (visibility_changed) {
                if (target_cursor_visible) {
                    try self.out_buf.appendSlice(self.allocator, "\x1b[?25h");
                } else {
                    try self.out_buf.appendSlice(self.allocator, "\x1b[?25l");
                }
                self.prev_cursor_visible = target_cursor_visible;
            }

            if (self.out_buf.items.len > 0) {
                _ = posix.system.write(posix.STDOUT_FILENO, self.out_buf.items.ptr, self.out_buf.items.len);
            }
        }
    }

    fn applyStyle(
        self: *Renderer,
        attrs: vterm_mod.Attrs,
        fg: vterm_mod.Color,
        bg: vterm_mod.Color,
    ) !void {
        try self.out_buf.appendSlice(self.allocator, "\x1b[0");
        if (attrs.bold) try self.out_buf.appendSlice(self.allocator, ";1");
        if (attrs.dim) try self.out_buf.appendSlice(self.allocator, ";2");
        if (attrs.italic) try self.out_buf.appendSlice(self.allocator, ";3");
        if (attrs.underline) try self.out_buf.appendSlice(self.allocator, ";4");
        if (attrs.reverse) try self.out_buf.appendSlice(self.allocator, ";7");
        if (attrs.hidden) try self.out_buf.appendSlice(self.allocator, ";8");

        switch (fg.type) {
            .default => {},
            .indexed => {
                if (fg.r < 8) {
                    try self.out_buf.print(self.allocator, ";{d}", .{30 + fg.r});
                } else if (fg.r < 16) {
                    try self.out_buf.print(self.allocator, ";{d}", .{90 + fg.r - 8});
                } else {
                    try self.out_buf.print(self.allocator, ";38;5;{d}", .{fg.r});
                }
            },
            .rgb => {
                try self.out_buf.print(self.allocator, ";38;2;{d};{d};{d}", .{ fg.r, fg.g, fg.b });
            },
        }

        switch (bg.type) {
            .default => {},
            .indexed => {
                if (bg.r < 8) {
                    try self.out_buf.print(self.allocator, ";{d}", .{40 + bg.r});
                } else if (bg.r < 16) {
                    try self.out_buf.print(self.allocator, ";{d}", .{100 + bg.r - 8});
                } else {
                    try self.out_buf.print(self.allocator, ";48;5;{d}", .{bg.r});
                }
            },
            .rgb => {
                try self.out_buf.print(self.allocator, ";48;2;{d};{d};{d}", .{ bg.r, bg.g, bg.b });
            },
        }

        try self.out_buf.append(self.allocator, 'm');
    }
};
