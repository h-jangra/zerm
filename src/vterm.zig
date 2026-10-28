const std = @import("std");

pub const ColorType = enum(u2) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

pub const Color = packed struct {
    type: ColorType = .default,
    _pad: u6 = 0,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn defaultColor() Color {
        return .{ .type = .default, .r = 0, .g = 0, .b = 0 };
    }

    pub fn indexed(idx: u8) Color {
        return .{ .type = .indexed, .r = idx, .g = 0, .b = 0 };
    }

    pub fn rgb(r_val: u8, g_val: u8, b_val: u8) Color {
        return .{ .type = .rgb, .r = r_val, .g = g_val, .b = b_val };
    }

    pub fn eql(self: Color, other: Color) bool {
        if (self.type != other.type) return false;
        switch (self.type) {
            .default => return true,
            .indexed => return self.r == other.r,
            .rgb => return self.r == other.r and self.g == other.g and self.b == other.b,
        }
    }
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    _pad: u2 = 0,

    pub fn eql(self: Attrs, other: Attrs) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = Color.defaultColor(),
    bg: Color = Color.defaultColor(),
    attrs: Attrs = .{},

    pub fn empty() Cell {
        return .{};
    }

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.attrs.eql(other.attrs);
    }
};

pub const ParserState = enum {
    ground,
    escape,
    csi,
    csi_param,
    osc,
    osc_esc,
    dcs,
    dcs_esc,
    apc,
    apc_esc,
    pm,
    pm_esc,
    sos,
    sos_esc,
    charset,
    utf8,
};

pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: [][]Cell = &[_][]Cell{},
    head: usize = 0,
    count: usize = 0,
    capacity: usize = 10000,

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) Scrollback {
        return .{
            .allocator = allocator,
            .lines = &[_][]Cell{},
            .head = 0,
            .count = 0,
            .capacity = max_capacity,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        if (self.lines.len > 0) {
            self.allocator.free(self.lines);
        }
        self.lines = &[_][]Cell{};
        self.head = 0;
        self.count = 0;
    }

    pub fn len(self: *const Scrollback) usize {
        return self.count;
    }

    pub fn get(self: *const Scrollback, idx: usize) ?[]const Cell {
        if (idx >= self.count or self.lines.len == 0) return null;
        const real_idx = (self.head + idx) % self.lines.len;
        return self.lines[real_idx];
    }

    pub fn push(self: *Scrollback, line: []const Cell) !void {
        var empty = true;
        for (line) |c| {
            if (c.char != ' ' and c.char != 0) {
                empty = false;
                break;
            }
        }
        if (empty) return;

        if (self.lines.len < self.capacity) {
            if (self.lines.len == 0) {
                const initial_cap = @min(@as(usize, 256), self.capacity);
                self.lines = try self.allocator.alloc([]Cell, initial_cap);
                @memset(self.lines, &[_]Cell{});
            } else if (self.count == self.lines.len) {
                const new_cap = @min(self.lines.len * 2, self.capacity);
                const new_lines = try self.allocator.alloc([]Cell, new_cap);
                var i: usize = 0;
                while (i < self.count) : (i += 1) {
                    new_lines[i] = self.lines[(self.head + i) % self.lines.len];
                }
                var rem = self.count;
                while (rem < new_cap) : (rem += 1) {
                    new_lines[rem] = &[_]Cell{};
                }
                self.allocator.free(self.lines);
                self.lines = new_lines;
                self.head = 0;
            }
        }

        if (self.count < self.lines.len) {
            const slot = (self.head + self.count) % self.lines.len;
            if (self.lines[slot].len != line.len) {
                if (self.lines[slot].len > 0) self.allocator.free(self.lines[slot]);
                self.lines[slot] = try self.allocator.alloc(Cell, line.len);
            }
            @memcpy(self.lines[slot], line);
            self.count += 1;
        } else {
            const slot = self.head;
            if (self.lines[slot].len != line.len) {
                if (self.lines[slot].len > 0) self.allocator.free(self.lines[slot]);
                self.lines[slot] = try self.allocator.alloc(Cell, line.len);
            }
            @memcpy(self.lines[slot], line);
            self.head = (self.head + 1) % self.lines.len;
        }
    }

    pub fn clear(self: *Scrollback) void {
        for (self.lines) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        if (self.lines.len > 0) {
            @memset(self.lines, &[_]Cell{});
        }
        self.head = 0;
        self.count = 0;
    }
};

pub const VTerm = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,

    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    saved_x: u16 = 0,
    saved_y: u16 = 0,
    saved_fg: Color = Color.defaultColor(),
    saved_bg: Color = Color.defaultColor(),
    saved_attrs: Attrs = .{},
    primary_saved_x: u16 = 0,
    primary_saved_y: u16 = 0,
    cursor_visible: bool = true,

    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,

    current_fg: Color = Color.defaultColor(),
    current_bg: Color = Color.defaultColor(),
    current_attrs: Attrs = .{},

    primary_grid: []Cell,
    alt_grid: []Cell,
    is_alt_screen: bool = false,

    title: [128]u8 = @splat(0),
    title_len: usize = 0,

    cursor_shape: u8 = 0,
    mouse_reporting: bool = false,

    scrollback: Scrollback,
    scroll_offset: usize = 0,

    dirty: bool = true,
    bracketed_paste: bool = false,
    reply_buf: [2048]u8 = @splat(0),
    reply_len: usize = 0,

    state: ParserState = .ground,
    csi_params: [16]i32 = @splat(0),
    csi_param_is_sub: [16]bool = @splat(false),
    csi_param_count: usize = 0,
    csi_private: bool = false,
    csi_intermediate: u8 = 0,

    osc_buf: [256]u8 = @splat(0),
    osc_len: usize = 0,

    dcs_buf: [256]u8 = @splat(0),
    dcs_len: usize = 0,

    utf8_buf: [4]u8 = @splat(0),
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,

    pub fn appendReply(self: *VTerm, bytes: []const u8) void {
        const avail = self.reply_buf.len - self.reply_len;
        const copy_len = @min(avail, bytes.len);
        if (copy_len > 0) {
            @memcpy(self.reply_buf[self.reply_len .. self.reply_len + copy_len], bytes[0..copy_len]);
            self.reply_len += copy_len;
        }
    }

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !VTerm {
        const w = @max(1, width);
        const h = @max(1, height);
        const size = @as(usize, w) * @as(usize, h);

        const primary = try allocator.alloc(Cell, size);
        @memset(primary, Cell.empty());

        const alt = try allocator.alloc(Cell, size);
        @memset(alt, Cell.empty());

        return VTerm{
            .allocator = allocator,
            .width = w,
            .height = h,
            .scroll_top = 0,
            .scroll_bottom = h - 1,
            .primary_grid = primary,
            .alt_grid = alt,
            .scrollback = Scrollback.init(allocator, 10000),
            .scroll_offset = 0,
        };
    }

    pub fn deinit(self: *VTerm) void {
        self.scrollback.deinit();
        self.allocator.free(self.primary_grid);
        self.allocator.free(self.alt_grid);
    }

    pub fn activeGrid(self: *const VTerm) []Cell {
        return if (self.is_alt_screen) self.alt_grid else self.primary_grid;
    }

    pub fn getCell(self: *const VTerm, x: u16, y: u16) Cell {
        if (x >= self.width or y >= self.height) return Cell.empty();
        const grid = self.activeGrid();
        return grid[@as(usize, y) * self.width + x];
    }

    pub fn getRenderCell(self: *const VTerm, x: u16, y: u16) Cell {
        if (x >= self.width or y >= self.height) return Cell.empty();

        const hist_len = self.scrollback.len();
        if (self.is_alt_screen or self.scroll_offset == 0 or hist_len == 0) {
            const grid = if (self.is_alt_screen) self.alt_grid else self.primary_grid;
            const idx = @as(usize, y) * self.width + x;
            if (idx < grid.len) return grid[idx];
            return Cell.empty();
        }

        const effective_offset = @min(self.scroll_offset, hist_len);
        if (y < effective_offset) {
            const hist_idx = hist_len - effective_offset + y;
            if (self.scrollback.get(hist_idx)) |line| {
                if (x < line.len) return line[x];
            }
            return Cell.empty();
        } else {
            const live_y = y - @as(u16, @intCast(effective_offset));
            const idx = @as(usize, live_y) * self.width + x;
            if (idx < self.primary_grid.len) return self.primary_grid[idx];
            return Cell.empty();
        }
    }

    pub fn scrollUp(self: *VTerm, count: usize) void {
        const max_offset = self.scrollback.len();
        if (self.is_alt_screen or max_offset == 0) return;
        const new_offset = @min(max_offset, self.scroll_offset + count);
        if (new_offset != self.scroll_offset) {
            self.scroll_offset = new_offset;
            self.dirty = true;
        }
    }

    pub fn scrollDown(self: *VTerm, count: usize) void {
        if (self.scroll_offset == 0) return;
        const new_offset = if (self.scroll_offset >= count) self.scroll_offset - count else 0;
        if (new_offset != self.scroll_offset) {
            self.scroll_offset = new_offset;
            self.dirty = true;
        }
    }

    pub fn scrollToBottom(self: *VTerm) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset = 0;
            self.dirty = true;
        }
    }

    pub fn resize(self: *VTerm, new_w_raw: u16, new_h_raw: u16) !void {
        const new_w = @max(1, new_w_raw);
        const new_h = @max(1, new_h_raw);
        if (new_w == self.width and new_h == self.height) return;

        const new_size = @as(usize, new_w) * @as(usize, new_h);
        const new_primary = try self.allocator.alloc(Cell, new_size);
        @memset(new_primary, Cell.empty());

        const new_alt = try self.allocator.alloc(Cell, new_size);
        @memset(new_alt, Cell.empty());

        const copy_w = @min(self.width, new_w);
        const copy_h = @min(self.height, new_h);

        var y: usize = 0;
        while (y < copy_h) : (y += 1) {
            const old_row_start = y * self.width;
            const new_row_start = y * new_w;
            @memcpy(new_primary[new_row_start .. new_row_start + copy_w], self.primary_grid[old_row_start .. old_row_start + copy_w]);
            @memcpy(new_alt[new_row_start .. new_row_start + copy_w], self.alt_grid[old_row_start .. old_row_start + copy_w]);
        }

        self.allocator.free(self.primary_grid);
        self.allocator.free(self.alt_grid);

        self.primary_grid = new_primary;
        self.alt_grid = new_alt;
        self.width = new_w;
        self.height = new_h;

        self.scroll_top = 0;
        self.scroll_bottom = new_h - 1;
        self.cursor_x = @min(self.cursor_x, new_w - 1);
        self.cursor_y = @min(self.cursor_y, new_h - 1);
        self.saved_x = @min(self.saved_x, new_w - 1);
        self.saved_y = @min(self.saved_y, new_h - 1);
        self.primary_saved_x = @min(self.primary_saved_x, new_w - 1);
        self.primary_saved_y = @min(self.primary_saved_y, new_h - 1);
        self.dirty = true;
    }

    pub fn writeInput(self: *VTerm, bytes: []const u8) void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            if (self.state == .ground) {
                const b = bytes[idx];
                if (b >= 0x20 and b <= 0x7e and self.cursor_x < self.width) {
                    const max_run = @min(bytes.len - idx, self.width - self.cursor_x);
                    var run_len: usize = 0;
                    while (run_len < max_run) : (run_len += 1) {
                        const ch = bytes[idx + run_len];
                        if (ch < 0x20 or ch > 0x7e) break;
                    }

                    if (run_len > 0) {
                        const grid = self.activeGrid();
                        const row_start = @as(usize, self.cursor_y) * self.width + self.cursor_x;
                        const template = Cell{
                            .char = ' ',
                            .fg = self.current_fg,
                            .bg = self.current_bg,
                            .attrs = self.current_attrs,
                        };
                        var k: usize = 0;
                        while (k < run_len) : (k += 1) {
                            var cell = template;
                            cell.char = bytes[idx + k];
                            grid[row_start + k] = cell;
                        }
                        self.cursor_x += @intCast(run_len);
                        self.dirty = true;
                        idx += run_len;
                        continue;
                    }
                }
            }

            self.processByte(bytes[idx]);
            idx += 1;
        }
    }

    fn processByte(self: *VTerm, b: u8) void {
        switch (self.state) {
            .ground => {
                switch (b) {
                    0x1b => self.state = .escape,
                    '\r' => {
                        self.cursor_x = 0;
                        self.dirty = true;
                    },
                    '\n', 0x0b, 0x0c => {
                        self.lineFeed();
                        self.dirty = true;
                    },
                    0x08 => {
                        if (self.cursor_x > 0) self.cursor_x -= 1;
                        self.dirty = true;
                    },
                    '\t' => {
                        self.cursor_x = @min(self.width - 1, (self.cursor_x + 8) & ~@as(u16, 7));
                        self.dirty = true;
                    },
                    0x07, 0x0e, 0x0f => {},
                    0x20...0x7e => {
                        self.putChar(b);
                    },
                    0x7f => {},
                    0xc0...0xdf => {
                        self.utf8_buf[0] = b;
                        self.utf8_len = 1;
                        self.utf8_expected = 2;
                        self.state = .utf8;
                    },
                    0xe0...0xef => {
                        self.utf8_buf[0] = b;
                        self.utf8_len = 1;
                        self.utf8_expected = 3;
                        self.state = .utf8;
                    },
                    0xf0...0xf7 => {
                        self.utf8_buf[0] = b;
                        self.utf8_len = 1;
                        self.utf8_expected = 4;
                        self.state = .utf8;
                    },
                    else => {
                        if (b >= 0x80) {
                            self.putChar(b);
                        }
                    },
                }
            },
            .utf8 => {
                if ((b & 0xc0) == 0x80) {
                    self.utf8_buf[self.utf8_len] = b;
                    self.utf8_len += 1;
                    if (self.utf8_len == self.utf8_expected) {
                        const cp = std.unicode.utf8Decode(self.utf8_buf[0..self.utf8_len]) catch '?';
                        self.putChar(cp);
                        self.state = .ground;
                    }
                } else {
                    self.state = .ground;
                    self.processByte(b);
                }
            },
            .escape => {
                switch (b) {
                    '\\' => {
                        self.state = .ground;
                    },
                    '[' => {
                        self.state = .csi;
                        self.csi_param_count = 0;
                        @memset(&self.csi_params, 0);
                        @memset(&self.csi_param_is_sub, false);
                        self.csi_private = false;
                        self.csi_intermediate = 0;
                    },
                    ']' => {
                        self.state = .osc;
                        self.osc_len = 0;
                    },
                    'P' => {
                        self.state = .dcs;
                        self.dcs_len = 0;
                    },
                    '_' => {
                        self.state = .apc;
                    },
                    '^' => {
                        self.state = .pm;
                    },
                    'X' => {
                        self.state = .sos;
                    },
                    '(', ')', '*', '+' => {
                        self.state = .charset;
                    },
                    '7' => {
                        self.saved_x = self.cursor_x;
                        self.saved_y = self.cursor_y;
                        self.saved_fg = self.current_fg;
                        self.saved_bg = self.current_bg;
                        self.saved_attrs = self.current_attrs;
                        self.state = .ground;
                    },
                    '8' => {
                        self.cursor_x = @min(self.width - 1, self.saved_x);
                        self.cursor_y = @min(self.height - 1, self.saved_y);
                        self.current_fg = self.saved_fg;
                        self.current_bg = self.saved_bg;
                        self.current_attrs = self.saved_attrs;
                        self.dirty = true;
                        self.state = .ground;
                    },
                    'M' => {
                        if (self.cursor_y == self.scroll_top) {
                            self.scrollDownRegion(1);
                        } else if (self.cursor_y > 0) {
                            self.cursor_y -= 1;
                        }
                        self.dirty = true;
                        self.state = .ground;
                    },
                    'D' => {
                        self.lineFeed();
                        self.dirty = true;
                        self.state = .ground;
                    },
                    'E' => {
                        self.cursor_x = 0;
                        self.lineFeed();
                        self.dirty = true;
                        self.state = .ground;
                    },
                    'c' => {
                        self.fullReset();
                        self.state = .ground;
                    },
                    '=', '>', 'H', 'N', 'O' => {
                        self.state = .ground;
                    },
                    else => {
                        self.state = .ground;
                    },
                }
            },
            .charset => {
                self.state = .ground;
            },
            .csi, .csi_param => {
                if (b >= '0' and b <= '9') {
                    if (self.csi_param_count == 0) {
                        self.csi_param_count = 1;
                        self.csi_params[0] = b - '0';
                        self.csi_param_is_sub[0] = false;
                    } else {
                        const idx = self.csi_param_count - 1;
                        self.csi_params[idx] = self.csi_params[idx] * 10 + (b - '0');
                    }
                    self.state = .csi_param;
                } else if (b == ';') {
                    if (self.csi_param_count == 0) {
                        self.csi_params[0] = 0;
                        self.csi_param_is_sub[0] = false;
                        self.csi_param_count = 1;
                    }
                    if (self.csi_param_count < 16) {
                        self.csi_params[self.csi_param_count] = 0;
                        self.csi_param_is_sub[self.csi_param_count] = false;
                        self.csi_param_count += 1;
                    }
                    self.state = .csi_param;
                } else if (b == ':') {
                    if (self.csi_param_count == 0) {
                        self.csi_params[0] = 0;
                        self.csi_param_is_sub[0] = false;
                        self.csi_param_count = 1;
                    }
                    if (self.csi_param_count < 16) {
                        self.csi_params[self.csi_param_count] = 0;
                        self.csi_param_is_sub[self.csi_param_count] = true;
                        self.csi_param_count += 1;
                    }
                    self.state = .csi_param;
                } else if (b >= 0x3c and b <= 0x3f) {
                    self.csi_private = true;
                    self.state = .csi_param;
                } else if (b >= 0x20 and b <= 0x2f) {
                    self.csi_intermediate = b;
                    self.state = .csi_param;
                } else if (b == 0x1b) {
                    self.state = .escape;
                } else if (b >= 0x40 and b <= 0x7e) {
                    self.executeCsi(b);
                    self.state = .ground;
                } else {
                    self.state = .ground;
                }
            },
            .osc => {
                if (b == 0x07) {
                    self.finishOsc();
                    self.state = .ground;
                } else if (b == 0x1b) {
                    self.state = .osc_esc;
                } else if (b == 0x18 or b == 0x1a) {
                    self.state = .ground;
                } else {
                    if (self.osc_len < self.osc_buf.len) {
                        self.osc_buf[self.osc_len] = b;
                        self.osc_len += 1;
                    }
                }
            },
            .osc_esc => {
                if (b == '\\') {
                    self.finishOsc();
                    self.state = .ground;
                } else if (b == 0x1b) {
                    self.state = .osc_esc;
                } else {
                    self.state = .ground;
                    self.processByte(b);
                }
            },
            .dcs => {
                if (b == 0x07) {
                    self.finishDcs();
                    self.state = .ground;
                } else if (b == 0x1b) {
                    self.state = .dcs_esc;
                } else if (b == 0x18 or b == 0x1a) {
                    self.state = .ground;
                } else {
                    if (self.dcs_len < self.dcs_buf.len) {
                        self.dcs_buf[self.dcs_len] = b;
                        self.dcs_len += 1;
                    }
                }
            },
            .dcs_esc => {
                if (b == '\\') {
                    self.finishDcs();
                    self.state = .ground;
                } else if (b == 0x1b) {
                    self.state = .dcs_esc;
                } else {
                    self.state = .ground;
                    self.processByte(b);
                }
            },
            .apc, .pm, .sos => {
                if (b == 0x07 or b == 0x18 or b == 0x1a) {
                    self.state = .ground;
                } else if (b == 0x1b) {
                    self.state = switch (self.state) {
                        .apc => .apc_esc,
                        .pm => .pm_esc,
                        .sos => .sos_esc,
                        else => .ground,
                    };
                }
            },
            .apc_esc, .pm_esc, .sos_esc => {
                if (b == '\\') {
                    self.state = .ground;
                } else if (b == 0x1b) {
                    // stay in esc
                } else {
                    self.state = .ground;
                    self.processByte(b);
                }
            },
        }
    }

    fn putChar(self: *VTerm, cp: u21) void {
        if (self.cursor_x >= self.width) {
            self.cursor_x = 0;
            self.lineFeed();
        }
        const grid = self.activeGrid();
        const idx = @as(usize, self.cursor_y) * self.width + self.cursor_x;
        grid[idx] = Cell{
            .char = cp,
            .fg = self.current_fg,
            .bg = self.current_bg,
            .attrs = self.current_attrs,
        };
        self.cursor_x += 1;
        self.dirty = true;
    }

    fn lineFeed(self: *VTerm) void {
        if (self.cursor_y >= self.scroll_bottom) {
            self.scrollUpRegion(1);
        } else if (self.cursor_y < self.height - 1) {
            self.cursor_y += 1;
        }
    }

    fn pushLineToScrollback(self: *VTerm, line: []const Cell) void {
        self.scrollback.push(line) catch {};
    }

    fn saveScreenToScrollback(self: *VTerm) void {
        if (self.is_alt_screen) return;
        var last_non_empty_row: isize = -1;
        var r: usize = 0;
        while (r < self.height) : (r += 1) {
            const line_start = r * self.width;
            for (self.primary_grid[line_start .. line_start + self.width]) |c| {
                if (c.char != ' ' and c.char != 0) {
                    last_non_empty_row = @as(isize, @intCast(r));
                    break;
                }
            }
        }
        if (last_non_empty_row < 0) return;

        const end_r: usize = @intCast(last_non_empty_row);
        var y: usize = 0;
        while (y <= end_r) : (y += 1) {
            const line_start = y * self.width;
            self.pushLineToScrollback(self.primary_grid[line_start .. line_start + self.width]);
        }
    }

    pub fn clearScrollback(self: *VTerm) void {
        self.scrollback.clear();
        self.scroll_offset = 0;
        self.dirty = true;
    }

    fn scrollUpRegion(self: *VTerm, count: u16) void {
        if (count == 0) return;
        const grid = self.activeGrid();
        const top = self.scroll_top;
        const bot = self.scroll_bottom;
        if (top > bot or bot >= self.height) return;

        const effective_count = @min(count, bot - top + 1);

        if (!self.is_alt_screen and top == 0) {
            var sc: u16 = 0;
            while (sc < effective_count) : (sc += 1) {
                const line_start = @as(usize, sc) * self.width;
                self.pushLineToScrollback(self.primary_grid[line_start .. line_start + self.width]);
            }
        }

        const lines_to_move = (bot - top + 1) - effective_count;
        if (lines_to_move > 0) {
            const dst_start = @as(usize, top) * self.width;
            const src_start = @as(usize, top + effective_count) * self.width;
            const move_len = @as(usize, lines_to_move) * self.width;
            std.mem.copyForwards(Cell, grid[dst_start .. dst_start + move_len], grid[src_start .. src_start + move_len]);
        }

        const clear_start = @as(usize, bot - effective_count + 1) * self.width;
        const clear_len = @as(usize, effective_count) * self.width;
        const empty_cell = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
        @memset(grid[clear_start .. clear_start + clear_len], empty_cell);

        self.dirty = true;
    }

    fn scrollDownRegion(self: *VTerm, count: u16) void {
        if (count == 0) return;
        const grid = self.activeGrid();
        const top = self.scroll_top;
        const bot = self.scroll_bottom;
        if (top > bot or bot >= self.height) return;

        const effective_count = @min(count, bot - top + 1);
        const lines_to_move = (bot - top + 1) - effective_count;
        if (lines_to_move > 0) {
            const dst_start = @as(usize, top + effective_count) * self.width;
            const src_start = @as(usize, top) * self.width;
            const move_len = @as(usize, lines_to_move) * self.width;
            std.mem.copyBackwards(Cell, grid[dst_start .. dst_start + move_len], grid[src_start .. src_start + move_len]);
        }

        const clear_start = @as(usize, top) * self.width;
        const clear_len = @as(usize, effective_count) * self.width;
        const empty_cell = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
        @memset(grid[clear_start .. clear_start + clear_len], empty_cell);

        self.dirty = true;
    }

    fn getParam(self: *const VTerm, idx: usize, def: i32) i32 {
        if (idx < self.csi_param_count and self.csi_params[idx] > 0) {
            return self.csi_params[idx];
        }
        return def;
    }

    fn executeCsi(self: *VTerm, cmd: u8) void {
        if (self.csi_intermediate == '$' and cmd == 'p') {
            const p = if (self.csi_param_count > 0) self.csi_params[0] else 0;
            var buf: [32]u8 = undefined;
            if (self.csi_private) {
                const status: u8 = blk: {
                    if (p == 2004) break :blk if (self.bracketed_paste) '1' else '2';
                    if (p == 25) break :blk if (self.cursor_visible) '1' else '2';
                    if (p == 1049 or p == 47 or p == 1047) break :blk if (self.is_alt_screen) '1' else '2';
                    if (p == 1000 or p == 1001 or p == 1002 or p == 1003 or p == 1006 or p == 1015) break :blk if (self.mouse_reporting) '1' else '2';
                    break :blk '0';
                };
                const rep = std.fmt.bufPrint(&buf, "\x1b[?{d};{c}$y", .{ p, status }) catch "";
                self.appendReply(rep);
            } else {
                const rep = std.fmt.bufPrint(&buf, "\x1b[{d};0$y", .{p}) catch "";
                self.appendReply(rep);
            }
            return;
        }

        if (self.csi_private) {
            switch (cmd) {
                'h' => {
                    const p = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                    if (p == 25) {
                        self.cursor_visible = true;
                        self.dirty = true;
                    } else if (p == 1049) {
                        self.primary_saved_x = self.cursor_x;
                        self.primary_saved_y = self.cursor_y;
                        self.saved_x = self.cursor_x;
                        self.saved_y = self.cursor_y;
                        self.is_alt_screen = true;
                        @memset(self.alt_grid, Cell.empty());
                        self.cursor_x = 0;
                        self.cursor_y = 0;
                        self.scroll_top = 0;
                        self.scroll_bottom = self.height - 1;
                        self.scroll_offset = 0;
                        self.dirty = true;
                    } else if (p == 47 or p == 1047) {
                        self.is_alt_screen = true;
                        @memset(self.alt_grid, Cell.empty());
                        self.cursor_x = 0;
                        self.cursor_y = 0;
                        self.scroll_top = 0;
                        self.scroll_bottom = self.height - 1;
                        self.scroll_offset = 0;
                        self.dirty = true;
                    } else if (p == 1048) {
                        self.saved_x = self.cursor_x;
                        self.saved_y = self.cursor_y;
                    } else if (p == 2004) {
                        self.bracketed_paste = true;
                    } else if (p == 1000 or p == 1001 or p == 1002 or p == 1003 or p == 1006 or p == 1015) {
                        self.mouse_reporting = true;
                    }
                },
                'l' => {
                    const p = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                    if (p == 25) {
                        self.cursor_visible = false;
                        self.dirty = true;
                    } else if (p == 1049) {
                        self.is_alt_screen = false;
                        self.cursor_x = @min(self.width - 1, self.primary_saved_x);
                        self.cursor_y = @min(self.height - 1, self.primary_saved_y);
                        self.scroll_top = 0;
                        self.scroll_bottom = self.height - 1;
                        self.scroll_offset = 0;
                        self.dirty = true;
                    } else if (p == 47 or p == 1047) {
                        self.is_alt_screen = false;
                        self.scroll_top = 0;
                        self.scroll_bottom = self.height - 1;
                        self.scroll_offset = 0;
                        self.dirty = true;
                    } else if (p == 1048) {
                        self.cursor_x = @min(self.width - 1, self.saved_x);
                        self.cursor_y = @min(self.height - 1, self.saved_y);
                        self.dirty = true;
                    } else if (p == 2004) {
                        self.bracketed_paste = false;
                    } else if (p == 1000 or p == 1001 or p == 1002 or p == 1003 or p == 1006 or p == 1015) {
                        self.mouse_reporting = false;
                    }
                },
                'c', 'q' => {
                    self.appendReply("\x1b[>0;10;1c");
                },
                else => {},
            }
            return;
        }

        switch (cmd) {
            'H', 'f' => {
                const row = self.getParam(0, 1) - 1;
                const col = self.getParam(1, 1) - 1;
                self.cursor_y = @intCast(@min(self.height - 1, @max(0, row)));
                self.cursor_x = @intCast(@min(self.width - 1, @max(0, col)));
                self.dirty = true;
            },
            'A' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_y = if (self.cursor_y >= n) self.cursor_y - n else 0;
                self.dirty = true;
            },
            'B' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_y = @min(self.height - 1, self.cursor_y + n);
                self.dirty = true;
            },
            'C' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_x = @min(self.width - 1, self.cursor_x + n);
                self.dirty = true;
            },
            'D' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_x = if (self.cursor_x >= n) self.cursor_x - n else 0;
                self.dirty = true;
            },
            'E' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_x = 0;
                self.cursor_y = @min(self.height - 1, self.cursor_y + n);
                self.dirty = true;
            },
            'F' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                self.cursor_x = 0;
                self.cursor_y = if (self.cursor_y >= n) self.cursor_y - n else 0;
                self.dirty = true;
            },
            'G', '`' => {
                const col = self.getParam(0, 1) - 1;
                self.cursor_x = @intCast(@min(self.width - 1, @max(0, col)));
                self.dirty = true;
            },
            'd' => {
                const row = self.getParam(0, 1) - 1;
                self.cursor_y = @intCast(@min(self.height - 1, @max(0, row)));
                self.dirty = true;
            },
            'J' => {
                const mode = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                const grid = self.activeGrid();
                const empty_cell = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
                if (mode == 0) {
                    const cur_pos = @as(usize, self.cursor_y) * self.width + self.cursor_x;
                    @memset(grid[cur_pos..], empty_cell);
                } else if (mode == 1) {
                    const cur_pos = @as(usize, self.cursor_y) * self.width + self.cursor_x + 1;
                    @memset(grid[0..@min(grid.len, cur_pos)], empty_cell);
                } else if (mode == 2) {
                    self.saveScreenToScrollback();
                    @memset(grid, empty_cell);
                    self.scroll_offset = 0;
                } else if (mode == 3) {
                    self.clearScrollback();
                    @memset(grid, empty_cell);
                    self.scroll_offset = 0;
                }
                self.dirty = true;
            },
            'K' => {
                const mode = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                const grid = self.activeGrid();
                const row_start = @as(usize, self.cursor_y) * self.width;
                const empty_cell = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
                if (mode == 0) {
                    const start = row_start + self.cursor_x;
                    const end = row_start + self.width;
                    @memset(grid[start..end], empty_cell);
                } else if (mode == 1) {
                    const end = row_start + @min(self.cursor_x + 1, self.width);
                    @memset(grid[row_start..end], empty_cell);
                } else if (mode == 2) {
                    @memset(grid[row_start .. row_start + self.width], empty_cell);
                }
                self.dirty = true;
            },
            'L' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                const old_top = self.scroll_top;
                self.scroll_top = self.cursor_y;
                self.scrollDownRegion(n);
                self.scroll_top = old_top;
            },
            'M' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                const old_top = self.scroll_top;
                self.scroll_top = self.cursor_y;
                self.scrollUpRegion(n);
                self.scroll_top = old_top;
            },
            'P' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                const grid = self.activeGrid();
                const row_start = @as(usize, self.cursor_y) * self.width;
                const cur_x = self.cursor_x;
                if (cur_x < self.width) {
                    const shift_len = self.width - cur_x;
                    const effective_n = @min(n, shift_len);
                    var x = cur_x;
                    while (x < self.width - effective_n) : (x += 1) {
                        grid[row_start + x] = grid[row_start + x + effective_n];
                    }
                    var ex = self.width - effective_n;
                    while (ex < self.width) : (ex += 1) {
                        grid[row_start + ex] = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
                    }
                    self.dirty = true;
                }
            },
            '@' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                const grid = self.activeGrid();
                const row_start = @as(usize, self.cursor_y) * self.width;
                const cur_x = self.cursor_x;
                if (cur_x < self.width) {
                    const shift_len = self.width - cur_x;
                    const effective_n = @min(n, shift_len);
                    var x: isize = @as(isize, self.width) - 1;
                    const limit: isize = @as(isize, cur_x) + @as(isize, effective_n);
                    while (x >= limit) : (x -= 1) {
                        grid[row_start + @as(usize, @intCast(x))] = grid[row_start + @as(usize, @intCast(x - @as(isize, effective_n)))];
                    }
                    var ix = cur_x;
                    while (ix < cur_x + effective_n) : (ix += 1) {
                        grid[row_start + ix] = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
                    }
                    self.dirty = true;
                }
            },
            'X' => {
                const n: u16 = @intCast(self.getParam(0, 1));
                const grid = self.activeGrid();
                const row_start = @as(usize, self.cursor_y) * self.width;
                const end = @min(self.width, self.cursor_x + n);
                var x = self.cursor_x;
                while (x < end) : (x += 1) {
                    grid[row_start + x] = Cell{ .char = ' ', .fg = self.current_fg, .bg = self.current_bg, .attrs = self.current_attrs };
                }
                self.dirty = true;
            },
            'm' => {
                self.handleSgr();
            },
            'r' => {
                const top = self.getParam(0, 1) - 1;
                const bot = if (self.csi_param_count >= 2 and self.csi_params[1] > 0) self.csi_params[1] - 1 else self.height - 1;
                if (top >= 0 and bot < self.height and top < bot) {
                    self.scroll_top = @intCast(top);
                    self.scroll_bottom = @intCast(bot);
                } else {
                    self.scroll_top = 0;
                    self.scroll_bottom = self.height - 1;
                }
                self.cursor_x = 0;
                self.cursor_y = 0;
            },
            's' => {
                self.saved_x = self.cursor_x;
                self.saved_y = self.cursor_y;
                self.saved_fg = self.current_fg;
                self.saved_bg = self.current_bg;
                self.saved_attrs = self.current_attrs;
            },
            'u' => {
                self.cursor_x = @min(self.width - 1, self.saved_x);
                self.cursor_y = @min(self.height - 1, self.saved_y);
                self.current_fg = self.saved_fg;
                self.current_bg = self.saved_bg;
                self.current_attrs = self.saved_attrs;
                self.dirty = true;
            },
            'q' => {
                const shape = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                self.cursor_shape = @intCast(@min(6, @max(0, shape)));
                self.dirty = true;
            },
            'n' => {
                const p = if (self.csi_param_count > 0) self.csi_params[0] else 0;
                if (p == 6) {
                    var buf: [32]u8 = undefined;
                    const report = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ self.cursor_y + 1, self.cursor_x + 1 }) catch "";
                    self.appendReply(report);
                } else if (p == 5) {
                    self.appendReply("\x1b[0n");
                }
            },
            'c' => {
                self.appendReply("\x1b[?1;2c");
            },
            else => {},
        }
    }

    fn handleSgr(self: *VTerm) void {
        if (self.csi_param_count == 0) {
            self.current_fg = Color.defaultColor();
            self.current_bg = Color.defaultColor();
            self.current_attrs = .{};
            return;
        }

        var i: usize = 0;
        while (i < self.csi_param_count) : (i += 1) {
            const p = self.csi_params[i];
            switch (p) {
                0 => {
                    self.current_fg = Color.defaultColor();
                    self.current_bg = Color.defaultColor();
                    self.current_attrs = .{};
                },
                1 => self.current_attrs.bold = true,
                2 => self.current_attrs.dim = true,
                3 => self.current_attrs.italic = true,
                4 => {
                    self.current_attrs.underline = true;
                    if (i + 1 < self.csi_param_count and self.csi_param_is_sub[i + 1]) {
                        const sub = self.csi_params[i + 1];
                        if (sub == 0) {
                            self.current_attrs.underline = false;
                        } else if (sub <= 5) {
                            self.current_attrs.underline = true;
                        }
                        i += 1;
                    }
                },
                7 => self.current_attrs.reverse = true,
                8 => self.current_attrs.hidden = true,
                22 => {
                    self.current_attrs.bold = false;
                    self.current_attrs.dim = false;
                },
                23 => self.current_attrs.italic = false,
                24 => self.current_attrs.underline = false,
                27 => self.current_attrs.reverse = false,
                28 => self.current_attrs.hidden = false,
                30...37 => self.current_fg = Color.indexed(@intCast(p - 30)),
                38 => {
                    if (i + 2 < self.csi_param_count and self.csi_params[i + 1] == 5) {
                        self.current_fg = Color.indexed(@intCast(@min(255, @max(0, self.csi_params[i + 2]))));
                        i += 2;
                    } else if (i + 5 < self.csi_param_count and self.csi_params[i + 1] == 2 and self.csi_param_is_sub[i + 1] and self.csi_params[i + 2] == 0) {
                        const r: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 3])));
                        const g: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 4])));
                        const b: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 5])));
                        self.current_fg = Color.rgb(r, g, b);
                        i += 5;
                    } else if (i + 4 < self.csi_param_count and self.csi_params[i + 1] == 2) {
                        const r: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 2])));
                        const g: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 3])));
                        const b: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 4])));
                        self.current_fg = Color.rgb(r, g, b);
                        i += 4;
                    }
                },
                39 => self.current_fg = Color.defaultColor(),
                40...47 => self.current_bg = Color.indexed(@intCast(p - 40)),
                48 => {
                    if (i + 2 < self.csi_param_count and self.csi_params[i + 1] == 5) {
                        self.current_bg = Color.indexed(@intCast(@min(255, @max(0, self.csi_params[i + 2]))));
                        i += 2;
                    } else if (i + 5 < self.csi_param_count and self.csi_params[i + 1] == 2 and self.csi_param_is_sub[i + 1] and self.csi_params[i + 2] == 0) {
                        const r: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 3])));
                        const g: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 4])));
                        const b: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 5])));
                        self.current_bg = Color.rgb(r, g, b);
                        i += 5;
                    } else if (i + 4 < self.csi_param_count and self.csi_params[i + 1] == 2) {
                        const r: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 2])));
                        const g: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 3])));
                        const b: u8 = @intCast(@min(255, @max(0, self.csi_params[i + 4])));
                        self.current_bg = Color.rgb(r, g, b);
                        i += 4;
                    }
                },
                49 => self.current_bg = Color.defaultColor(),
                58 => {
                    if (i + 2 < self.csi_param_count and self.csi_params[i + 1] == 5) {
                        i += 2;
                    } else if (i + 5 < self.csi_param_count and self.csi_params[i + 1] == 2 and self.csi_param_is_sub[i + 1] and self.csi_params[i + 2] == 0) {
                        i += 5;
                    } else if (i + 4 < self.csi_param_count and self.csi_params[i + 1] == 2) {
                        i += 4;
                    }
                },
                59 => {},
                90...97 => self.current_fg = Color.indexed(@intCast(p - 90 + 8)),
                100...107 => self.current_bg = Color.indexed(@intCast(p - 100 + 8)),
                else => {},
            }
        }
    }

    fn finishOsc(self: *VTerm) void {
        const raw = self.osc_buf[0..self.osc_len];
        const semi_pos = std.mem.indexOfScalar(u8, raw, ';');
        if (semi_pos) |pos| {
            const num_str = raw[0..pos];
            const payload = raw[pos + 1 ..];
            const p = std.fmt.parseInt(u32, num_str, 10) catch 999999;

            if (p == 0 or p == 1 or p == 2 or p == 30) {
                const copy_len = @min(self.title.len, payload.len);
                @memcpy(self.title[0..copy_len], payload[0..copy_len]);
                self.title_len = copy_len;
                self.dirty = true;
                return;
            } else if (p == 7) {
                var path = payload;
                if (std.mem.startsWith(u8, path, "file://")) {
                    path = path["file://".len..];
                    if (std.mem.indexOfScalar(u8, path, '/')) |slash_pos| {
                        path = path[slash_pos..];
                    }
                }
                const copy_len = @min(self.title.len, path.len);
                @memcpy(self.title[0..copy_len], path[0..copy_len]);
                self.title_len = copy_len;
                self.dirty = true;
                return;
            } else if (p == 10 and std.mem.eql(u8, payload, "?")) {
                self.appendReply("\x1b]10;rgb:ffff/ffff/ffff\x1b\\");
                return;
            } else if (p == 11 and std.mem.eql(u8, payload, "?")) {
                self.appendReply("\x1b]11;rgb:0000/0000/0000\x1b\\");
                return;
            } else if (p == 12 and std.mem.eql(u8, payload, "?")) {
                self.appendReply("\x1b]12;rgb:ffff/ffff/ffff\x1b\\");
                return;
            }
        }
    }

    fn finishDcs(self: *VTerm) void {
        const raw = self.dcs_buf[0..self.dcs_len];
        if (raw.len >= 2 and std.mem.startsWith(u8, raw, "+q")) {
            const payload = raw[2..];
            var out_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&out_buf, "\x1bP0+r{s}\x1b\\", .{payload}) catch "";
            self.appendReply(resp);
        } else if (raw.len >= 2 and std.mem.startsWith(u8, raw, "$q")) {
            const payload = raw[2..];
            var out_buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&out_buf, "\x1bP0$r{s}\x1b\\", .{payload}) catch "";
            self.appendReply(resp);
        }
    }

    fn fullReset(self: *VTerm) void {
        @memset(self.primary_grid, Cell.empty());
        @memset(self.alt_grid, Cell.empty());
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.saved_x = 0;
        self.saved_y = 0;
        self.saved_fg = Color.defaultColor();
        self.saved_bg = Color.defaultColor();
        self.saved_attrs = .{};
        self.primary_saved_x = 0;
        self.primary_saved_y = 0;
        self.cursor_visible = true;
        self.scroll_top = 0;
        self.scroll_bottom = self.height - 1;
        self.current_fg = Color.defaultColor();
        self.current_bg = Color.defaultColor();
        self.current_attrs = .{};
        self.is_alt_screen = false;
        self.scroll_offset = 0;
        self.dirty = true;
    }
};

test "vterm basic text output and linefeed" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 10, 5);
    defer vt.deinit();

    vt.writeInput("hello\r\nworld");
    try testing.expectEqual(@as(u21, 'h'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), vt.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'o'), vt.getCell(4, 0).char);
    try testing.expectEqual(@as(u21, 'w'), vt.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, 'd'), vt.getCell(4, 1).char);
}

test "vterm cursor positioning and erase" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 10, 5);
    defer vt.deinit();

    vt.writeInput("\x1b[3;4Habc");
    try testing.expectEqual(@as(u21, 'a'), vt.getCell(3, 2).char);
    try testing.expectEqual(@as(u21, 'b'), vt.getCell(4, 2).char);
    try testing.expectEqual(@as(u21, 'c'), vt.getCell(5, 2).char);

    vt.writeInput("\x1b[2J");
    try testing.expectEqual(@as(u21, ' '), vt.getCell(3, 2).char);
}

test "vterm alternate screen buffer and osc title" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 10, 5);
    defer vt.deinit();

    vt.writeInput("\x1b]0;nvim myfile.zig\x07");
    try testing.expectEqualStrings("nvim myfile.zig", vt.title[0..vt.title_len]);

    vt.writeInput("\x1b[?1049hfoo");
    try testing.expect(vt.is_alt_screen);
    try testing.expectEqual(@as(u21, 'f'), vt.getCell(0, 0).char);

    vt.writeInput("\x1b[?1049l");
    try testing.expect(!vt.is_alt_screen);
}

test "vterm osc string terminator and colon sgr" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();

    vt.writeInput("\x1b]133;A\x1b\\prompt> ");
    try testing.expectEqual(@as(u21, 'p'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'r'), vt.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'o'), vt.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'm'), vt.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'p'), vt.getCell(4, 0).char);
    try testing.expectEqual(@as(u21, 't'), vt.getCell(5, 0).char);

    vt.writeInput("\x1b[4:1mtext\x1b[4:0m");
    try testing.expect(vt.getCell(8, 0).attrs.underline);
    try testing.expect(!vt.current_attrs.underline);
}

test "vterm fish modifyOtherKeys sequence does not trigger underline" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();

    // Fish shell sends \x1b[>4;1m for modifyOtherKeys. It must NOT turn on underline!
    vt.writeInput("\x1b[>4;1mprompt> ");
    try testing.expect(!vt.current_attrs.underline);
    try testing.expect(!vt.getCell(0, 0).attrs.underline);
    try testing.expectEqual(@as(u21, 'p'), vt.getCell(0, 0).char);
}

test "vterm DCS XTGETTCAP sequence does not leak text to screen and sends response" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();

    // Neovim/Vim sends XTGETTCAP query for Ms (clipboard): \x1bP+q4D73\x1b\\
    vt.writeInput("\x1bP+q4D73\x1b\\hello");
    // '+', 'q', '4', 'D', '7', '3' must NOT be in the cell grid!
    try testing.expectEqual(@as(u21, 'h'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'e'), vt.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'l'), vt.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, 'l'), vt.getCell(3, 0).char);
    try testing.expectEqual(@as(u21, 'o'), vt.getCell(4, 0).char);

    // reply_buf should have invalid capability reply \x1bP0+r4D73\x1b\\
    try testing.expectEqualStrings("\x1bP0+r4D73\x1b\\", vt.reply_buf[0..vt.reply_len]);
}

test "vterm alternate screen preserves and restores cursor position across app exit" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 80, 24);
    defer vt.deinit();

    // User is on line 2 (e.g. after typing "vim file.txt")
    vt.cursor_x = 14;
    vt.cursor_y = 2;

    // Vim enters alternate screen
    vt.writeInput("\x1b[?1049h");
    try testing.expect(vt.is_alt_screen);
    try testing.expectEqual(@as(u16, 0), vt.cursor_x);
    try testing.expectEqual(@as(u16, 0), vt.cursor_y);

    // Vim positions cursor at row 24 on exit: \x1b[24;1H
    vt.writeInput("\x1b[24;1H");
    try testing.expectEqual(@as(u16, 23), vt.cursor_y);

    // Vim exits alternate screen: \x1b[?1049l
    vt.writeInput("\x1b[?1049l");
    try testing.expect(!vt.is_alt_screen);

    // Cursor position should be restored back to (14, 2), NOT left at 23!
    try testing.expectEqual(@as(u16, 14), vt.cursor_x);
    try testing.expectEqual(@as(u16, 2), vt.cursor_y);
}

test "vterm ctrl l clear screen saves scrollback and resets scroll_offset" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();

    vt.writeInput("line1\r\nline2\r\nline3");
    try testing.expectEqual(@as(u21, 'l'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, '1'), vt.getCell(4, 0).char);
    try testing.expectEqual(@as(u21, '2'), vt.getCell(4, 1).char);
    try testing.expectEqual(@as(u21, '3'), vt.getCell(4, 2).char);

    vt.scrollUp(2);

    vt.writeInput("\x1b[H\x1b[2Jprompt$ ");

    try testing.expectEqual(@as(usize, 0), vt.scroll_offset);
    try testing.expectEqual(@as(u21, 'p'), vt.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'r'), vt.getCell(1, 0).char);
    try testing.expectEqual(@as(u21, 'o'), vt.getCell(2, 0).char);
    try testing.expectEqual(@as(u21, ' '), vt.getCell(0, 1).char);

    try testing.expectEqual(@as(usize, 3), vt.scrollback.len());
    try testing.expectEqual(@as(u21, 'l'), vt.scrollback.get(0).?[0].char);
    try testing.expectEqual(@as(u21, '1'), vt.scrollback.get(0).?[4].char);
    try testing.expectEqual(@as(u21, '2'), vt.scrollback.get(1).?[4].char);
    try testing.expectEqual(@as(u21, '3'), vt.scrollback.get(2).?[4].char);

    vt.writeInput("\x1b[3J");
    try testing.expectEqual(@as(usize, 0), vt.scrollback.len());
}

test "vterm DECRQM mode query reports bracketed paste status" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 20, 5);
    defer vt.deinit();

    // Query bracketed paste when disabled (default)
    vt.writeInput("\x1b[?2004$p");
    try testing.expectEqualStrings("\x1b[?2004;2$y", vt.reply_buf[0..vt.reply_len]);

    // Enable bracketed paste and query again
    vt.reply_len = 0;
    vt.writeInput("\x1b[?2004h\x1b[?2004$p");
    try testing.expectEqualStrings("\x1b[?2004;1$y", vt.reply_buf[0..vt.reply_len]);

    // Disable bracketed paste and query again
    vt.reply_len = 0;
    vt.writeInput("\x1b[?2004l\x1b[?2004$p");
    try testing.expectEqualStrings("\x1b[?2004;2$y", vt.reply_buf[0..vt.reply_len]);
}

test "vterm batched CPR and DECRQM queries respond completely without dropping" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 80, 24);
    defer vt.deinit();

    // fzf / tcell sends: \x1b[6n\x1b[?2004$p\x1b[6n
    vt.writeInput("\x1b[6n\x1b[?2004$p\x1b[6n");
    // All 3 responses must be present in reply_buf in sequence!
    try testing.expectEqualStrings("\x1b[1;1R\x1b[?2004;2$y\x1b[1;1R", vt.reply_buf[0..vt.reply_len]);
}

test "scrollback ring buffer wrapping and capacity retention" {
    const testing = std.testing;
    var sb = Scrollback.init(testing.allocator, 5);
    defer sb.deinit();

    var line1 = [_]Cell{.{ .char = 'A' }};
    var line2 = [_]Cell{.{ .char = 'B' }};
    var line3 = [_]Cell{.{ .char = 'C' }};
    var line4 = [_]Cell{.{ .char = 'D' }};
    var line5 = [_]Cell{.{ .char = 'E' }};
    var line6 = [_]Cell{.{ .char = 'F' }};

    try sb.push(&line1);
    try sb.push(&line2);
    try sb.push(&line3);
    try testing.expectEqual(@as(usize, 3), sb.len());
    try testing.expectEqual(@as(u21, 'A'), sb.get(0).?[0].char);
    try testing.expectEqual(@as(u21, 'C'), sb.get(2).?[0].char);

    try sb.push(&line4);
    try sb.push(&line5);
    try testing.expectEqual(@as(usize, 5), sb.len());
    try testing.expectEqual(@as(u21, 'A'), sb.get(0).?[0].char);
    try testing.expectEqual(@as(u21, 'E'), sb.get(4).?[0].char);

    // Push 6th line: should evict line1 ('A') and keep lines B, C, D, E, F
    try sb.push(&line6);
    try testing.expectEqual(@as(usize, 5), sb.len());
    try testing.expectEqual(@as(u21, 'B'), sb.get(0).?[0].char);
    try testing.expectEqual(@as(u21, 'C'), sb.get(1).?[0].char);
    try testing.expectEqual(@as(u21, 'D'), sb.get(2).?[0].char);
    try testing.expectEqual(@as(u21, 'E'), sb.get(3).?[0].char);
    try testing.expectEqual(@as(u21, 'F'), sb.get(4).?[0].char);
}

test "vterm OSC 0, 1, 2, 7, 30 title handling" {
    const testing = std.testing;
    var vt = try VTerm.init(testing.allocator, 80, 24);
    defer vt.deinit();

    // Bash PROMPT_COMMAND / echo -ne "\033]0;${PWD}\007"
    vt.writeInput("\x1b]0;/home/hj/Projects/zerm\x07");
    try testing.expectEqualStrings("/home/hj/Projects/zerm", vt.title[0..vt.title_len]);

    // OSC 2 (window title)
    vt.writeInput("\x1b]2;my-window-title\x07");
    try testing.expectEqualStrings("my-window-title", vt.title[0..vt.title_len]);

    // OSC 1 (icon title)
    vt.writeInput("\x1b]1;icon-name\x07");
    try testing.expectEqualStrings("icon-name", vt.title[0..vt.title_len]);

    // OSC 30 (tab title)
    vt.writeInput("\x1b]30;tab-name\x07");
    try testing.expectEqualStrings("tab-name", vt.title[0..vt.title_len]);

    // OSC 7 with file://localhost/...
    vt.writeInput("\x1b]7;file://localhost/home/hj/docs\x07");
    try testing.expectEqualStrings("/home/hj/docs", vt.title[0..vt.title_len]);
}
