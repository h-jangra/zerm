const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const vterm_mod = @import("vterm.zig");

pub const Action = enum {
    new_tab,
    close_pane,
    next_tab,
    prev_tab,
    split_vertical,
    split_horizontal,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    resize_left,
    resize_right,
    resize_up,
    resize_down,
    scroll_page_up,
    scroll_page_down,
    scroll_to_bottom,
    copy,
};

pub const KeyCode = union(enum) {
    char: u8,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
};

pub const KeyChord = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    code: KeyCode,

    pub fn eql(self: KeyChord, other: KeyChord) bool {
        if (self.ctrl != other.ctrl or self.shift != other.shift or self.alt != other.alt) return false;
        if (std.meta.activeTag(self.code) != std.meta.activeTag(other.code)) return false;
        switch (self.code) {
            .char => |c| return std.ascii.toLower(c) == std.ascii.toLower(other.code.char),
            else => return true,
        }
    }
};

pub const Binding = struct {
    chord: KeyChord,
    action: Action,
};

pub const BorderStyle = enum {
    single,
    rounded,
    double,
    ascii,

    pub fn getChars(self: BorderStyle) struct {
        vert: u21,
        horiz: u21,
        cross: u21,
    } {
        switch (self) {
            .single, .rounded => return .{ .vert = 0x2502, .horiz = 0x2500, .cross = 0x253C },
            .double => return .{ .vert = 0x2551, .horiz = 0x2550, .cross = 0x256C },
            .ascii => return .{ .vert = '|', .horiz = '-', .cross = '+' },
        }
    }
};

pub const TabBarShow = enum {
    auto,
    always,
    never,
};

pub const Theme = struct {
    tab_bar_show: TabBarShow = .auto,
    tab_format: [64]u8 = [_]u8{0} ** 64,
    tab_format_len: usize = 0,

    tab_active_format: [64]u8 = [_]u8{0} ** 64,
    tab_active_format_len: usize = 0,

    tab_inactive_format: [64]u8 = [_]u8{0} ** 64,
    tab_inactive_format_len: usize = 0,

    tab_bar_bg: vterm_mod.Color = vterm_mod.Color.indexed(235),
    tab_active_bg: vterm_mod.Color = vterm_mod.Color.indexed(33),
    tab_active_fg: vterm_mod.Color = vterm_mod.Color.indexed(255),
    tab_active_bold: bool = true,

    tab_inactive_bg: vterm_mod.Color = vterm_mod.Color.indexed(238),
    tab_inactive_fg: vterm_mod.Color = vterm_mod.Color.indexed(250),
    tab_inactive_bold: bool = false,

    border_active_fg: vterm_mod.Color = vterm_mod.Color.indexed(33),
    border_inactive_fg: vterm_mod.Color = vterm_mod.Color.indexed(240),
    border_style: BorderStyle = .single,

    resize_delta: f32 = 0.05,
    custom_shell: ?[256:0]u8 = null,

    pub fn initDefault() Theme {
        var t = Theme{};
        const def_fmt = " [{index} {title}] ";
        @memcpy(t.tab_format[0..def_fmt.len], def_fmt);
        t.tab_format_len = def_fmt.len;
        return t;
    }

    pub fn setTabFormat(self: *Theme, fmt: []const u8) void {
        const copy_len = @min(self.tab_format.len, fmt.len);
        @memcpy(self.tab_format[0..copy_len], fmt[0..copy_len]);
        self.tab_format_len = copy_len;
    }

    pub fn setActiveTabFormat(self: *Theme, fmt: []const u8) void {
        const copy_len = @min(self.tab_active_format.len, fmt.len);
        @memcpy(self.tab_active_format[0..copy_len], fmt[0..copy_len]);
        self.tab_active_format_len = copy_len;
    }

    pub fn setInactiveTabFormat(self: *Theme, fmt: []const u8) void {
        const copy_len = @min(self.tab_inactive_format.len, fmt.len);
        @memcpy(self.tab_inactive_format[0..copy_len], fmt[0..copy_len]);
        self.tab_inactive_format_len = copy_len;
    }

    pub fn getActiveTabFormat(self: *const Theme) []const u8 {
        if (self.tab_active_format_len > 0) return self.tab_active_format[0..self.tab_active_format_len];
        if (self.tab_format_len > 0) return self.tab_format[0..self.tab_format_len];
        return " [{index} {title}] ";
    }

    pub fn getInactiveTabFormat(self: *const Theme) []const u8 {
        if (self.tab_inactive_format_len > 0) return self.tab_inactive_format[0..self.tab_inactive_format_len];
        if (self.tab_format_len > 0) return self.tab_format[0..self.tab_format_len];
        return " [{index} {title}] ";
    }

    pub fn getTabFormat(self: *const Theme) []const u8 {
        if (self.tab_format_len > 0) return self.tab_format[0..self.tab_format_len];
        return " [{index} {title}] ";
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    theme: Theme,
    bindings: std.ArrayList(Binding),

    pub fn init(allocator: std.mem.Allocator) Config {
        var cfg = Config{
            .allocator = allocator,
            .theme = Theme.initDefault(),
            .bindings = std.ArrayList(Binding).empty,
        };
        cfg.addDefaultBindings() catch {};
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn addBinding(self: *Config, chord: KeyChord, action: Action) !void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (self.bindings.items[i].chord.eql(chord)) {
                _ = self.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        try self.bindings.append(self.allocator, .{ .chord = chord, .action = action });
    }

    pub fn getAction(self: *const Config, chord: KeyChord) ?Action {
        for (self.bindings.items) |b| {
            if (b.chord.eql(chord)) return b.action;
        }
        return null;
    }

    pub fn addDefaultBindings(self: *Config) !void {
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 't' } }, .new_tab);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 't' } }, .new_tab);

        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'w' } }, .close_pane);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'w' } }, .close_pane);

        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'n' } }, .next_tab);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'n' } }, .next_tab);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'p' } }, .prev_tab);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'p' } }, .prev_tab);

        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .enter }, .split_vertical);
        try self.addBinding(.{ .alt = true, .code = .enter }, .split_vertical);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'v' } }, .split_vertical);

        try self.addBinding(.{ .alt = true, .shift = true, .code = .enter }, .split_horizontal);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'd' } }, .split_horizontal);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'd' } }, .split_horizontal);

        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .left }, .focus_left);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .right }, .focus_right);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .up }, .focus_up);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .down }, .focus_down);

        try self.addBinding(.{ .alt = true, .code = .left }, .focus_left);
        try self.addBinding(.{ .alt = true, .code = .right }, .focus_right);
        try self.addBinding(.{ .alt = true, .code = .up }, .focus_up);
        try self.addBinding(.{ .alt = true, .code = .down }, .focus_down);

        try self.addBinding(.{ .alt = true, .code = .{ .char = 'h' } }, .focus_left);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'l' } }, .focus_right);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'k' } }, .focus_up);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'j' } }, .focus_down);

        try self.addBinding(.{ .alt = true, .shift = true, .code = .left }, .resize_left);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .right }, .resize_right);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .up }, .resize_up);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .down }, .resize_down);

        try self.addBinding(.{ .alt = true, .shift = true, .code = .{ .char = 'h' } }, .resize_left);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .{ .char = 'l' } }, .resize_right);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .{ .char = 'k' } }, .resize_up);
        try self.addBinding(.{ .alt = true, .shift = true, .code = .{ .char = 'j' } }, .resize_down);

        try self.addBinding(.{ .shift = true, .code = .page_up }, .scroll_page_up);
        try self.addBinding(.{ .shift = true, .code = .page_down }, .scroll_page_down);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'u' } }, .scroll_page_up);
        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'd' } }, .scroll_page_down);
        try self.addBinding(.{ .alt = true, .code = .page_up }, .scroll_page_up);
        try self.addBinding(.{ .alt = true, .code = .page_down }, .scroll_page_down);

        try self.addBinding(.{ .ctrl = true, .shift = true, .code = .{ .char = 'c' } }, .copy);
        try self.addBinding(.{ .alt = true, .code = .{ .char = 'c' } }, .copy);
    }
};

pub const default_ini_content =
    \\# zerm configuration file
    \\
    \\[keybindings]
    \\# Action = list of comma-separated key chords
    \\# Modifiers: ctrl, alt, shift
    \\# Special keys: enter, tab, backspace, esc, up, down, left, right, page_up, page_down
    \\new_tab = ctrl+shift+t, alt+t
    \\close_pane = ctrl+shift+w, alt+w
    \\next_tab = ctrl+shift+n, alt+n
    \\prev_tab = ctrl+shift+p, alt+p
    \\split_vertical = ctrl+shift+enter, alt+enter, alt+v
    \\split_horizontal = alt+shift+enter, ctrl+shift+d, alt+d
    \\focus_left = ctrl+shift+left, alt+left, alt+h
    \\focus_right = ctrl+shift+right, alt+right, alt+l
    \\focus_up = ctrl+shift+up, alt+up, alt+k
    \\focus_down = ctrl+shift+down, alt+down, alt+j
    \\resize_left = alt+shift+left, alt+H
    \\resize_right = alt+shift+right, alt+L
    \\resize_up = alt+shift+up, alt+K
    \\resize_down = alt+shift+down, alt+J
    \\scroll_page_up = shift+page_up, ctrl+shift+u, alt+page_up
    \\scroll_page_down = shift+page_down, ctrl+shift+d, alt+page_down
    \\copy = ctrl+shift+c, alt+c
    \\
    \\[tabs]
    \\# Tab bar visibility: auto (show when >1 tab), always (show even with 1 tab), never
    \\# show = auto
    \\# Tab title format: use {index}, {title}, {flags} or tmux-style #I, #W, #F
    \\# Enclose in quotes (single '...' or double "...") to preserve exact spacing and padding
    \\format = " [{index} {title}] "
    \\# Optional: separate format for active and inactive tabs (tmux-style)
    \\# active_format = " [{index} {title}] "
    \\# inactive_format = "  {index} {title}  "
    \\# Colors: default / transparent / none, 0-255 (256-color index), #RRGGBB (hex), or standard color name
    \\tab_bar_bg = 235
    \\active_bg = 33
    \\active_fg = 255
    \\active_bold = true
    \\inactive_bg = 238
    \\inactive_fg = 250
    \\inactive_bold = false
    \\
    \\[borders]
    \\active_fg = 33
    \\inactive_fg = 240
    \\# Border style: single, rounded, double, ascii
    \\style = single
    \\
    \\[general]
    \\# Default shell (leave empty to use $SHELL)
    \\shell =
    \\resize_delta = 0.05
    \\
;

pub fn unquote(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len >= 2) {
        if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

pub fn parseChord(str_raw: []const u8) ?KeyChord {
    var chord = KeyChord{ .code = .{ .char = 0 } };
    var it = std.mem.splitScalar(u8, str_raw, '+');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            chord.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "opt") or std.ascii.eqlIgnoreCase(part, "option")) {
            chord.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            chord.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "enter") or std.ascii.eqlIgnoreCase(part, "return")) {
            chord.code = .enter;
        } else if (std.ascii.eqlIgnoreCase(part, "tab")) {
            chord.code = .tab;
        } else if (std.ascii.eqlIgnoreCase(part, "backspace")) {
            chord.code = .backspace;
        } else if (std.ascii.eqlIgnoreCase(part, "esc") or std.ascii.eqlIgnoreCase(part, "escape")) {
            chord.code = .escape;
        } else if (std.ascii.eqlIgnoreCase(part, "space")) {
            chord.code = .{ .char = ' ' };
        } else if (std.ascii.eqlIgnoreCase(part, "up")) {
            chord.code = .up;
        } else if (std.ascii.eqlIgnoreCase(part, "down")) {
            chord.code = .down;
        } else if (std.ascii.eqlIgnoreCase(part, "left")) {
            chord.code = .left;
        } else if (std.ascii.eqlIgnoreCase(part, "right")) {
            chord.code = .right;
        } else if (std.ascii.eqlIgnoreCase(part, "page_up") or std.ascii.eqlIgnoreCase(part, "pageup") or std.ascii.eqlIgnoreCase(part, "pgup")) {
            chord.code = .page_up;
        } else if (std.ascii.eqlIgnoreCase(part, "page_down") or std.ascii.eqlIgnoreCase(part, "pagedown") or std.ascii.eqlIgnoreCase(part, "pgdn")) {
            chord.code = .page_down;
        } else if (part.len == 1) {
            chord.code = .{ .char = std.ascii.toLower(part[0]) };
            if (std.ascii.isUpper(part[0])) {
                chord.shift = true;
            }
        }
    }
    if (std.meta.activeTag(chord.code) == .char and chord.code.char == 0) return null;
    return chord;
}

pub fn parseColor(str_raw: []const u8) ?vterm_mod.Color {
    const s = std.mem.trim(u8, str_raw, " \t\"'");
    if (s.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(s, "default") or
        std.ascii.eqlIgnoreCase(s, "transparent") or
        std.ascii.eqlIgnoreCase(s, "none") or
        std.ascii.eqlIgnoreCase(s, "bg") or
        std.ascii.eqlIgnoreCase(s, "background")) return vterm_mod.Color.defaultColor();
    if (std.ascii.eqlIgnoreCase(s, "black")) return vterm_mod.Color.indexed(0);
    if (std.ascii.eqlIgnoreCase(s, "red")) return vterm_mod.Color.indexed(1);
    if (std.ascii.eqlIgnoreCase(s, "green")) return vterm_mod.Color.indexed(2);
    if (std.ascii.eqlIgnoreCase(s, "yellow")) return vterm_mod.Color.indexed(3);
    if (std.ascii.eqlIgnoreCase(s, "blue")) return vterm_mod.Color.indexed(4);
    if (std.ascii.eqlIgnoreCase(s, "magenta")) return vterm_mod.Color.indexed(5);
    if (std.ascii.eqlIgnoreCase(s, "cyan")) return vterm_mod.Color.indexed(6);
    if (std.ascii.eqlIgnoreCase(s, "white")) return vterm_mod.Color.indexed(7);
    if (std.ascii.eqlIgnoreCase(s, "gray") or std.ascii.eqlIgnoreCase(s, "grey")) return vterm_mod.Color.indexed(8);

    if (s[0] == '#' and s.len == 7) {
        const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
        return vterm_mod.Color.rgb(r, g, b);
    }

    if (std.fmt.parseInt(u8, s, 10)) |idx| {
        return vterm_mod.Color.indexed(idx);
    } else |_| {}

    return null;
}

pub fn parseBool(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\"'");
    return std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

pub fn parseIniIntoConfig(content: []const u8, cfg: *Config) void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var section: []const u8 = "";

    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
            const key = std.mem.trim(u8, line[0..eq_pos], " \t");
            const val = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(section, "keybindings")) {
                parseBindingKey(cfg, key, val);
            } else if (std.ascii.eqlIgnoreCase(section, "tabs")) {
                if (std.ascii.eqlIgnoreCase(key, "format")) {
                    cfg.theme.setTabFormat(unquote(val));
                } else if (std.ascii.eqlIgnoreCase(key, "active_format") or std.ascii.eqlIgnoreCase(key, "current_format") or std.ascii.eqlIgnoreCase(key, "window_status_current_format")) {
                    cfg.theme.setActiveTabFormat(unquote(val));
                } else if (std.ascii.eqlIgnoreCase(key, "inactive_format") or std.ascii.eqlIgnoreCase(key, "window_status_format")) {
                    cfg.theme.setInactiveTabFormat(unquote(val));
                } else if (std.ascii.eqlIgnoreCase(key, "show") or std.ascii.eqlIgnoreCase(key, "tab_bar") or std.ascii.eqlIgnoreCase(key, "show_tab_bar") or std.ascii.eqlIgnoreCase(key, "tab_bar_show")) {
                    const st = std.mem.trim(u8, val, " \t\"'");
                    if (std.ascii.eqlIgnoreCase(st, "always") or std.ascii.eqlIgnoreCase(st, "true") or std.ascii.eqlIgnoreCase(st, "yes") or std.ascii.eqlIgnoreCase(st, "1") or std.ascii.eqlIgnoreCase(st, "on")) {
                        cfg.theme.tab_bar_show = .always;
                    } else if (std.ascii.eqlIgnoreCase(st, "never") or std.ascii.eqlIgnoreCase(st, "false") or std.ascii.eqlIgnoreCase(st, "no") or std.ascii.eqlIgnoreCase(st, "0") or std.ascii.eqlIgnoreCase(st, "off")) {
                        cfg.theme.tab_bar_show = .never;
                    } else {
                        cfg.theme.tab_bar_show = .auto;
                    }
                } else if (std.ascii.eqlIgnoreCase(key, "tab_bar_bg")) {
                    if (parseColor(val)) |c| cfg.theme.tab_bar_bg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "active_bg")) {
                    if (parseColor(val)) |c| cfg.theme.tab_active_bg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "active_fg")) {
                    if (parseColor(val)) |c| cfg.theme.tab_active_fg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "active_bold")) {
                    cfg.theme.tab_active_bold = parseBool(val);
                } else if (std.ascii.eqlIgnoreCase(key, "inactive_bg")) {
                    if (parseColor(val)) |c| cfg.theme.tab_inactive_bg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "inactive_fg")) {
                    if (parseColor(val)) |c| cfg.theme.tab_inactive_fg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "inactive_bold")) {
                    cfg.theme.tab_inactive_bold = parseBool(val);
                }
            } else if (std.ascii.eqlIgnoreCase(section, "borders")) {
                if (std.ascii.eqlIgnoreCase(key, "active_fg")) {
                    if (parseColor(val)) |c| cfg.theme.border_active_fg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "inactive_fg")) {
                    if (parseColor(val)) |c| cfg.theme.border_inactive_fg = c;
                } else if (std.ascii.eqlIgnoreCase(key, "style")) {
                    const st = std.mem.trim(u8, val, " \t\"'");
                    if (std.ascii.eqlIgnoreCase(st, "single")) cfg.theme.border_style = .single;
                    if (std.ascii.eqlIgnoreCase(st, "rounded")) cfg.theme.border_style = .rounded;
                    if (std.ascii.eqlIgnoreCase(st, "double")) cfg.theme.border_style = .double;
                    if (std.ascii.eqlIgnoreCase(st, "ascii")) cfg.theme.border_style = .ascii;
                }
            } else if (std.ascii.eqlIgnoreCase(section, "general")) {
                if (std.ascii.eqlIgnoreCase(key, "shell")) {
                    const sh = std.mem.trim(u8, val, " \t\"'");
                    if (sh.len > 0) {
                        var buf: [256:0]u8 = undefined;
                        const copy_len = @min(255, sh.len);
                        @memcpy(buf[0..copy_len], sh[0..copy_len]);
                        buf[copy_len] = 0;
                        cfg.theme.custom_shell = buf;
                    }
                } else if (std.ascii.eqlIgnoreCase(key, "resize_delta")) {
                    if (std.fmt.parseFloat(f32, std.mem.trim(u8, val, " \t\"'"))) |d| {
                        cfg.theme.resize_delta = @max(0.01, @min(0.2, d));
                    } else |_| {}
                }
            }
        }
    }
}

fn parseBindingKey(cfg: *Config, key: []const u8, val: []const u8) void {
    const action: ?Action = blk: {
        if (std.ascii.eqlIgnoreCase(key, "new_tab")) break :blk .new_tab;
        if (std.ascii.eqlIgnoreCase(key, "close_pane") or std.ascii.eqlIgnoreCase(key, "close_tab")) break :blk .close_pane;
        if (std.ascii.eqlIgnoreCase(key, "next_tab")) break :blk .next_tab;
        if (std.ascii.eqlIgnoreCase(key, "prev_tab") or std.ascii.eqlIgnoreCase(key, "previous_tab")) break :blk .prev_tab;
        if (std.ascii.eqlIgnoreCase(key, "split_vertical") or std.ascii.eqlIgnoreCase(key, "vsplit")) break :blk .split_vertical;
        if (std.ascii.eqlIgnoreCase(key, "split_horizontal") or std.ascii.eqlIgnoreCase(key, "hsplit")) break :blk .split_horizontal;
        if (std.ascii.eqlIgnoreCase(key, "focus_left")) break :blk .focus_left;
        if (std.ascii.eqlIgnoreCase(key, "focus_right")) break :blk .focus_right;
        if (std.ascii.eqlIgnoreCase(key, "focus_up")) break :blk .focus_up;
        if (std.ascii.eqlIgnoreCase(key, "focus_down")) break :blk .focus_down;
        if (std.ascii.eqlIgnoreCase(key, "resize_left")) break :blk .resize_left;
        if (std.ascii.eqlIgnoreCase(key, "resize_right")) break :blk .resize_right;
        if (std.ascii.eqlIgnoreCase(key, "resize_up")) break :blk .resize_up;
        if (std.ascii.eqlIgnoreCase(key, "resize_down")) break :blk .resize_down;
        if (std.ascii.eqlIgnoreCase(key, "scroll_page_up") or std.ascii.eqlIgnoreCase(key, "scroll_up") or std.ascii.eqlIgnoreCase(key, "page_up")) break :blk .scroll_page_up;
        if (std.ascii.eqlIgnoreCase(key, "scroll_page_down") or std.ascii.eqlIgnoreCase(key, "scroll_down") or std.ascii.eqlIgnoreCase(key, "page_down")) break :blk .scroll_page_down;
        if (std.ascii.eqlIgnoreCase(key, "scroll_to_bottom")) break :blk .scroll_to_bottom;
        if (std.ascii.eqlIgnoreCase(key, "copy") or std.ascii.eqlIgnoreCase(key, "copy_selection")) break :blk .copy;
        break :blk null;
    };

    if (action) |act| {
        // Remove old default bindings for this action so user config replaces them
        var i: usize = 0;
        while (i < cfg.bindings.items.len) {
            if (cfg.bindings.items[i].action == act) {
                _ = cfg.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        const trimmed_val = std.mem.trim(u8, val, " \t\"'");
        if (trimmed_val.len == 0 or
            std.ascii.eqlIgnoreCase(trimmed_val, "none") or
            std.ascii.eqlIgnoreCase(trimmed_val, "disabled") or
            std.ascii.eqlIgnoreCase(trimmed_val, "unbind"))
        {
            return;
        }

        var it = std.mem.splitScalar(u8, trimmed_val, ',');
        while (it.next()) |part| {
            const chord_str = std.mem.trim(u8, part, " \t\"'");
            if (parseChord(chord_str)) |chord| {
                cfg.addBinding(chord, act) catch {};
            }
        }
    }
}

pub fn makePath(path: [:0]const u8) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            var sub_buf: [512:0]u8 = undefined;
            @memcpy(sub_buf[0..i], path[0..i]);
            sub_buf[i] = 0;
            _ = linux.mkdir(&sub_buf, 0o755);
        }
    }
    _ = linux.mkdir(path.ptr, 0o755);
}

pub fn formatTabLabel(fmt_str: []const u8, index: usize, title: []const u8, is_active: bool, out_buf: []u8) []const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt_str.len and out_idx < out_buf.len) {
        if (std.mem.startsWith(u8, fmt_str[i..], "{index}") or std.mem.startsWith(u8, fmt_str[i..], "#I")) {
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{index}) catch "";
            for (num_str) |c| {
                if (out_idx < out_buf.len) {
                    out_buf[out_idx] = c;
                    out_idx += 1;
                }
            }
            i += if (std.mem.startsWith(u8, fmt_str[i..], "{index}")) "{index}".len else "#I".len;
        } else if (std.mem.startsWith(u8, fmt_str[i..], "{title}") or std.mem.startsWith(u8, fmt_str[i..], "#W") or std.mem.startsWith(u8, fmt_str[i..], "#T")) {
            for (title) |c| {
                if (out_idx < out_buf.len) {
                    out_buf[out_idx] = c;
                    out_idx += 1;
                }
            }
            if (std.mem.startsWith(u8, fmt_str[i..], "{title}")) {
                i += "{title}".len;
            } else if (std.mem.startsWith(u8, fmt_str[i..], "#W")) {
                i += "#W".len;
            } else {
                i += "#T".len;
            }
        } else if (std.mem.startsWith(u8, fmt_str[i..], "{flags}") or std.mem.startsWith(u8, fmt_str[i..], "#F")) {
            if (is_active and out_idx < out_buf.len) {
                out_buf[out_idx] = '*';
                out_idx += 1;
            }
            i += if (std.mem.startsWith(u8, fmt_str[i..], "{flags}")) "{flags}".len else "#F".len;
        } else if (std.mem.startsWith(u8, fmt_str[i..], "{active}")) {
            if (is_active and out_idx < out_buf.len) {
                out_buf[out_idx] = '*';
                out_idx += 1;
            }
            i += "{active}".len;
        } else {
            out_buf[out_idx] = fmt_str[i];
            out_idx += 1;
            i += 1;
        }
    }
    return out_buf[0..out_idx];
}

pub fn getEnv(key: []const u8) ?[]const u8 {
    const pty_mod = @import("pty.zig");
    if (pty_mod.global_envp) |ge| {
        var i: usize = 0;
        while (ge[i]) |entry| : (i += 1) {
            const entry_slice = std.mem.span(entry);
            if (std.mem.startsWith(u8, entry_slice, key) and entry_slice.len > key.len and entry_slice[key.len] == '=') {
                return entry_slice[key.len + 1 ..];
            }
        }
    }
    return null;
}

pub fn loadConfigFile(allocator: std.mem.Allocator) Config {
    var cfg = Config.init(allocator);

    var path_buf: [512:0]u8 = undefined;
    var path_slice: ?[:0]const u8 = null;

    if (getEnv("XDG_CONFIG_HOME")) |xdg| {
        const p = std.fmt.bufPrintZ(&path_buf, "{s}/zerm/zerm.ini", .{xdg}) catch null;
        if (p) |res| path_slice = res;
    } else if (getEnv("HOME")) |home| {
        const p = std.fmt.bufPrintZ(&path_buf, "{s}/.config/zerm/zerm.ini", .{home}) catch null;
        if (p) |res| path_slice = res;
    }

    const cfg_path = path_slice orelse return cfg;

    const dir_len = std.mem.lastIndexOfScalar(u8, cfg_path, '/') orelse 0;
    if (dir_len > 0) {
        var dir_buf: [512:0]u8 = undefined;
        @memcpy(dir_buf[0..dir_len], cfg_path[0..dir_len]);
        dir_buf[dir_len] = 0;
        makePath(&dir_buf);
    }

    const fd_res = posix.openatZ(posix.AT.FDCWD, cfg_path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd_res) |fd| {
        defer _ = posix.system.close(fd);
        var read_buf: [16384]u8 = undefined;
        const n = posix.system.read(fd, &read_buf, read_buf.len);
        if (@as(isize, @bitCast(n)) > 0) {
            parseIniIntoConfig(read_buf[0..@intCast(n)], &cfg);
        }
    } else |_| {
        const create_res = posix.openatZ(posix.AT.FDCWD, cfg_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644);
        if (create_res) |wfd| {
            defer _ = posix.system.close(wfd);
            _ = posix.system.write(wfd, default_ini_content.ptr, default_ini_content.len);
        } else |_| {}
    }

    return cfg;
}

test "config parse chords and ini" {
    const testing = std.testing;
    var cfg = Config.init(testing.allocator);
    defer cfg.deinit();

    const sample =
        \\[keybindings]
        \\new_tab = ctrl+shift+t, alt+t
        \\split_horizontal = alt+shift+enter, ctrl+shift+d
        \\
        \\[tabs]
        \\format = ' {title} '
        \\active_format = " [{index}: {title}] "
        \\inactive_format = '  #I: #W#F  '
        \\active_bg = #ff5500
        \\
        \\[borders]
        \\style = double
    ;

    parseIniIntoConfig(sample, &cfg);

    const act_hsplit = cfg.getAction(.{ .alt = true, .shift = true, .code = .enter });
    try testing.expectEqual(@as(?Action, .split_horizontal), act_hsplit);

    try testing.expectEqualStrings(" {title} ", cfg.theme.getTabFormat());
    try testing.expectEqualStrings(" [{index}: {title}] ", cfg.theme.getActiveTabFormat());
    try testing.expectEqualStrings("  #I: #W#F  ", cfg.theme.getInactiveTabFormat());

    try testing.expect(cfg.theme.tab_active_bg.type == .rgb);
    try testing.expectEqual(@as(u8, 0xff), cfg.theme.tab_active_bg.r);
    try testing.expectEqual(BorderStyle.double, cfg.theme.border_style);

    // Test formatTabLabel with spaces, quotes, and tmux placeholders
    var buf: [128]u8 = undefined;
    const res_active = formatTabLabel(cfg.theme.getActiveTabFormat(), 1, "zsh", true, &buf);
    try testing.expectEqualStrings(" [1: zsh] ", res_active);

    const res_inactive = formatTabLabel(cfg.theme.getInactiveTabFormat(), 2, "nvim", false, &buf);
    try testing.expectEqualStrings("  2: nvim  ", res_inactive);

    const res_tmux_flag = formatTabLabel(" #I: #W#F ", 1, "bash", true, &buf);
    try testing.expectEqualStrings(" 1: bash* ", res_tmux_flag);

    const res_single_quote_spaces = formatTabLabel(" {title} ", 1, "fish", false, &buf);
    try testing.expectEqualStrings(" fish ", res_single_quote_spaces);

    try testing.expectEqual(vterm_mod.ColorType.default, (parseColor("default") orelse unreachable).type);
    try testing.expectEqual(vterm_mod.ColorType.default, (parseColor("transparent") orelse unreachable).type);
    try testing.expectEqual(vterm_mod.ColorType.default, (parseColor("none") orelse unreachable).type);

    // Test keybinding override
    const override_sample =
        \\[keybindings]
        \\new_tab = alt+a
        \\close_pane = none
    ;
    parseIniIntoConfig(override_sample, &cfg);

    // alt+a should now trigger new_tab
    try testing.expectEqual(@as(?Action, .new_tab), cfg.getAction(.{ .alt = true, .code = .{ .char = 'a' } }));
    // alt+t should NO LONGER trigger new_tab
    try testing.expectEqual(@as(?Action, null), cfg.getAction(.{ .alt = true, .code = .{ .char = 't' } }));
    // ctrl+shift+t should NO LONGER trigger new_tab
    try testing.expectEqual(@as(?Action, null), cfg.getAction(.{ .ctrl = true, .shift = true, .code = .{ .char = 't' } }));
    // close_pane was set to none, so neither alt+w nor ctrl+shift+w should trigger close_pane
    try testing.expectEqual(@as(?Action, null), cfg.getAction(.{ .alt = true, .code = .{ .char = 'w' } }));
    try testing.expectEqual(@as(?Action, null), cfg.getAction(.{ .ctrl = true, .shift = true, .code = .{ .char = 'w' } }));
}
