const std = @import("std");
const vterm_mod = @import("vterm.zig");
const pty_mod = @import("pty.zig");
const tree_mod = @import("tree.zig");
const config = @import("config.zig");
const input_mod = @import("input.zig");

pub const Selection = struct {
    start_x: u16 = 0,
    start_y: u16 = 0,
    end_x: u16 = 0,
    end_y: u16 = 0,
    active: bool = false,
    selecting: bool = false,

    pub fn getNormalized(self: Selection) struct { s_x: u16, s_y: u16, e_x: u16, e_y: u16 } {
        if (self.start_y < self.end_y or (self.start_y == self.end_y and self.start_x <= self.end_x)) {
            return .{ .s_x = self.start_x, .s_y = self.start_y, .e_x = self.end_x, .e_y = self.end_y };
        } else {
            return .{ .s_x = self.end_x, .s_y = self.end_y, .e_x = self.start_x, .e_y = self.start_y };
        }
    }

    pub fn isSelected(self: Selection, x: u16, y: u16) bool {
        if (!self.active) return false;
        const norm = self.getNormalized();
        if (y < norm.s_y or y > norm.e_y) return false;
        if (norm.s_y == norm.e_y) {
            return x >= norm.s_x and x <= norm.e_x;
        }
        if (y == norm.s_y) {
            return x >= norm.s_x;
        }
        if (y == norm.e_y) {
            return x <= norm.e_x;
        }
        return true;
    }
};

pub const Pane = struct {
    id: u32,
    pty: pty_mod.Pty,
    vterm: vterm_mod.VTerm,
    rect: tree_mod.Rect,
    allocator: std.mem.Allocator,
    selection: Selection = .{},
    key_protocol: input_mod.KeyProtocol = .legacy,

    pub fn init(allocator: std.mem.Allocator, id: u32, cols: u16, rows: u16, shell: ?[]const u8, cwd: ?[]const u8) !*Pane {
        const pane = try allocator.create(Pane);
        errdefer allocator.destroy(pane);

        const safe_cols = @max(1, cols);
        const safe_rows = @max(1, rows);

        var vt = try vterm_mod.VTerm.init(allocator, safe_cols, safe_rows);
        errdefer vt.deinit();

        const pty_inst = try pty_mod.Pty.spawn(safe_cols, safe_rows, shell, cwd);

        pane.* = .{
            .id = id,
            .pty = pty_inst,
            .vterm = vt,
            .rect = .{ .x = 0, .y = 0, .width = safe_cols, .height = safe_rows },
            .allocator = allocator,
            .selection = .{},
            .key_protocol = .legacy,
        };
        return pane;
    }

    pub fn deinit(self: *Pane) void {
        self.pty.deinit();
        self.vterm.deinit();
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Pane, new_rect: tree_mod.Rect) void {
        self.rect = new_rect;
        const w = @max(1, new_rect.width);
        const h = @max(1, new_rect.height);
        self.vterm.resize(w, h) catch {};
        self.pty.resize(w, h);
    }

    pub fn writeToPty(self: *Pane, bytes: []const u8) void {
        _ = self.pty.write(bytes);
    }

    pub fn readPtyOutput(self: *Pane, buf: []u8) bool {
        var had_read = false;
        while (true) {
            const n = self.pty.read(buf);
            if (n > 0) {
                had_read = true;
                const chunk = buf[0..@intCast(n)];
                self.scanKeyProtocol(chunk);
                self.vterm.writeInput(chunk);
                self.flushReply();
            } else if (n == 0) {
                return false;
            } else {
                break;
            }
        }
        return if (had_read) true else self.pty.checkAlive();
    }

    fn scanKeyProtocol(self: *Pane, chunk: []const u8) void {
        var i: usize = 0;
        while (i < chunk.len) : (i += 1) {
            if (chunk[i] != 0x1b) continue;
            const rest = chunk[i..];
            if (std.mem.startsWith(u8, rest, "\x1b[>1u") or std.mem.startsWith(u8, rest, "\x1b[=1u") or std.mem.startsWith(u8, rest, "\x1b[>1;") or std.mem.startsWith(u8, rest, "\x1b[=1;")) {
                self.key_protocol = .kitty;
            } else if (std.mem.startsWith(u8, rest, "\x1b[<u") or std.mem.startsWith(u8, rest, "\x1b[=0u")) {
                if (self.key_protocol == .kitty) self.key_protocol = .legacy;
            } else if (std.mem.startsWith(u8, rest, "\x1b[>4;2m") or std.mem.startsWith(u8, rest, "\x1b[>4;1m") or std.mem.startsWith(u8, rest, "\x1b[>4m")) {
                if (self.key_protocol == .legacy) self.key_protocol = .modify_other_keys;
            } else if (std.mem.startsWith(u8, rest, "\x1b[>4;0m")) {
                if (self.key_protocol == .modify_other_keys) self.key_protocol = .legacy;
            }
        }
    }

    pub fn getCwd(self: *Pane, buf: []u8) ?[]const u8 {
        return self.pty.getCwd(buf);
    }

    pub fn isAppRunning(self: *Pane) bool {
        return self.vterm.is_alt_screen;
    }

    pub fn flushReply(self: *Pane) void {
        if (self.vterm.reply_len > 0) {
            _ = self.pty.write(self.vterm.reply_buf[0..self.vterm.reply_len]);
            self.vterm.reply_len = 0;
        }
    }

    pub fn clearSelection(self: *Pane) void {
        self.selection = .{};
    }

    pub fn getSelectedText(self: *Pane, allocator: std.mem.Allocator) !?[]u8 {
        if (!self.selection.active) return null;
        const norm = self.selection.getNormalized();

        var text_list = std.ArrayList(u8).empty;
        errdefer text_list.deinit(allocator);

        var y = norm.s_y;
        while (y <= norm.e_y) : (y += 1) {
            const start_col: u16 = if (y == norm.s_y) norm.s_x else 0;
            const end_col: u16 = if (y == norm.e_y) norm.e_x else (if (self.vterm.width > 0) self.vterm.width - 1 else 0);

            var line_buf: [1024]u8 = undefined;
            var line_len: usize = 0;

            var x = start_col;
            while (x <= end_col and x < self.vterm.width) : (x += 1) {
                const cell = self.vterm.getRenderCell(x, y);
                if (cell.char < 128) {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = if (cell.char == 0) ' ' else @intCast(cell.char);
                        line_len += 1;
                    }
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch 0;
                    if (len > 0 and line_len + len <= line_buf.len) {
                        @memcpy(line_buf[line_len .. line_len + len], utf8_buf[0..len]);
                        line_len += len;
                    }
                }
            }

            const line_slice = std.mem.trimEnd(u8, line_buf[0..line_len], " ");
            try text_list.appendSlice(allocator, line_slice);

            if (y < norm.e_y) {
                try text_list.append(allocator, '\n');
            }
        }

        if (text_list.items.len == 0) {
            text_list.deinit(allocator);
            return null;
        }
        return try text_list.toOwnedSlice(allocator);
    }

    pub fn copySelectionToClipboard(self: *Pane, allocator: std.mem.Allocator) void {
        const text_opt = self.getSelectedText(allocator) catch return;
        if (text_opt) |text| {
            defer allocator.free(text);
            if (text.len == 0) return;
            const b64_len = std.base64.standard.Encoder.calcSize(text.len);
            const b64_buf = allocator.alloc(u8, b64_len) catch return;
            defer allocator.free(b64_buf);
            _ = std.base64.standard.Encoder.encode(b64_buf, text);

            _ = std.posix.system.write(std.posix.STDOUT_FILENO, "\x1b]52;c;", 7);
            _ = std.posix.system.write(std.posix.STDOUT_FILENO, b64_buf.ptr, b64_buf.len);
            _ = std.posix.system.write(std.posix.STDOUT_FILENO, "\x1b\\", 2);
        }
    }
};

pub const Tab = struct {
    id: u32,
    allocator: std.mem.Allocator,
    root: ?*tree_mod.Node,
    panes: std.AutoHashMap(u32, *Pane),
    focused_pane_id: u32,
    next_pane_id: u32 = 1,
    shell: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, id: u32, cols: u16, rows: u16, shell: ?[]const u8, cwd: ?[]const u8) !*Tab {
        const tab = try allocator.create(Tab);
        errdefer allocator.destroy(tab);

        const pane_id: u32 = 1;
        const first_pane = try Pane.init(allocator, pane_id, cols, rows, shell, cwd);
        errdefer first_pane.deinit();

        const root_node = try tree_mod.Node.createLeaf(allocator, pane_id);
        errdefer root_node.destroy(allocator);

        var panes_map = std.AutoHashMap(u32, *Pane).init(allocator);
        try panes_map.put(pane_id, first_pane);

        tab.* = .{
            .id = id,
            .allocator = allocator,
            .root = root_node,
            .panes = panes_map,
            .focused_pane_id = pane_id,
            .next_pane_id = pane_id + 1,
            .shell = shell,
        };
        return tab;
    }

    pub fn deinit(self: *Tab) void {
        var it = self.panes.valueIterator();
        while (it.next()) |pane_ptr| {
            pane_ptr.*.deinit();
        }
        self.panes.deinit();
        if (self.root) |r| {
            r.destroy(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn getActivePane(self: *const Tab) ?*Pane {
        return self.panes.get(self.focused_pane_id);
    }

    pub fn computeLayout(self: *Tab, area: tree_mod.Rect) void {
        const root = self.root orelse return;
        root.computeLayout(area);

        var leaf_buf: [64]*tree_mod.Node = undefined;
        var leaf_count: usize = 0;
        root.collectLeavesSlice(&leaf_buf, &leaf_count);

        for (leaf_buf[0..leaf_count]) |leaf| {
            if (self.panes.get(leaf.data.leaf.id)) |pane| {
                pane.resize(leaf.rect);
            }
        }
    }

    pub fn splitActivePane(self: *Tab, direction: tree_mod.SplitDirection, current_area: tree_mod.Rect) !void {
        const active = self.getActivePane() orelse return;
        const new_id = self.next_pane_id;
        self.next_pane_id += 1;

        var cwd_buf: [4096]u8 = undefined;
        const cwd = active.getCwd(&cwd_buf);

        const new_pane = try Pane.init(self.allocator, new_id, active.rect.width, active.rect.height, self.shell, cwd);
        errdefer new_pane.deinit();

        try self.panes.put(new_id, new_pane);

        _ = try tree_mod.Node.splitLeaf(self.allocator, &self.root.?, active.id, new_id, direction);
        self.focused_pane_id = new_id;
        self.computeLayout(current_area);
    }

    pub fn closeActivePane(self: *Tab, current_area: tree_mod.Rect) bool {
        return self.closePaneById(self.focused_pane_id, current_area);
    }

    pub fn closePaneById(self: *Tab, target_id: u32, current_area: tree_mod.Rect) bool {
        const pane = self.panes.get(target_id) orelse return false;

        var candidate_id: ?u32 = null;
        if (self.root) |r| {
            candidate_id = r.findAdjacentLeaf(target_id, .left) orelse
                r.findAdjacentLeaf(target_id, .right) orelse
                r.findAdjacentLeaf(target_id, .up) orelse
                r.findAdjacentLeaf(target_id, .down);
        }

        if (self.root) |*r_ptr| {
            const is_last = (r_ptr.*.data == .leaf and r_ptr.*.data.leaf.id == target_id);
            _ = tree_mod.Node.closeLeaf(self.allocator, r_ptr, target_id);
            if (is_last) {
                self.root = null;
            }
        }

        _ = self.panes.remove(target_id);
        pane.deinit();

        if (self.root == null or self.panes.count() == 0) {
            return true;
        }

        if (candidate_id) |cid| {
            if (self.panes.contains(cid)) {
                self.focused_pane_id = cid;
            } else {
                var it = self.panes.keyIterator();
                if (it.next()) |k| self.focused_pane_id = k.*;
            }
        } else {
            var it = self.panes.keyIterator();
            if (it.next()) |k| self.focused_pane_id = k.*;
        }

        self.computeLayout(current_area);
        return false;
    }

    pub fn navigateFocus(self: *Tab, dir: tree_mod.Direction) void {
        const root = self.root orelse return;
        if (root.findAdjacentLeaf(self.focused_pane_id, dir)) |adj_id| {
            if (self.panes.contains(adj_id)) {
                self.focused_pane_id = adj_id;
            }
        }
    }

    pub fn resizeActivePane(self: *Tab, dir: tree_mod.Direction, delta: f32, current_area: tree_mod.Rect) void {
        const root = self.root orelse return;
        if (root.resizePane(self.focused_pane_id, dir, delta)) {
            self.computeLayout(current_area);
        }
    }

    pub fn getTitle(self: *const Tab) []const u8 {
        if (self.getActivePane()) |p| {
            if (p.vterm.title_len > 0) {
                return p.vterm.title[0..p.vterm.title_len];
            }
        }
        if (pty_mod.default_shell) |sh| {
            return std.fs.path.basename(sh);
        }
        return "zsh";
    }
};

test "pane selection and text extraction" {
    const testing = std.testing;
    var pane = try Pane.init(testing.allocator, 1, 20, 5, null, null);
    defer pane.deinit();

    pane.vterm.writeInput("hello world\r\nsecond line here");

    pane.selection = .{ .start_x = 0, .start_y = 0, .end_x = 4, .end_y = 0, .active = true };
    try testing.expect(pane.selection.isSelected(0, 0));
    try testing.expect(pane.selection.isSelected(4, 0));
    try testing.expect(!pane.selection.isSelected(5, 0));

    pane.selection = .{ .start_x = 4, .start_y = 0, .end_x = 0, .end_y = 0, .active = true };
    try testing.expect(pane.selection.isSelected(0, 0));
    try testing.expect(pane.selection.isSelected(4, 0));
    try testing.expect(!pane.selection.isSelected(5, 0));

    const text_opt = try pane.getSelectedText(testing.allocator);
    try testing.expect(text_opt != null);
    if (text_opt) |txt| {
        defer testing.allocator.free(txt);
        try testing.expectEqualStrings("hello", txt);
    }

    pane.selection = .{ .start_x = 6, .start_y = 0, .end_x = 5, .end_y = 1, .active = true };
    const multi_opt = try pane.getSelectedText(testing.allocator);
    try testing.expect(multi_opt != null);
    if (multi_opt) |txt| {
        defer testing.allocator.free(txt);
        try testing.expectEqualStrings("world\nsecond", txt);
    }

    pane.clearSelection();
    try testing.expect(!pane.selection.active);
    try testing.expect(!pane.selection.isSelected(0, 0));
}
