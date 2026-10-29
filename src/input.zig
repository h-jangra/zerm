const std = @import("std");
const config = @import("config.zig");

pub const MouseEvent = struct {
    btn: u32,
    x: u16,
    y: u16,
    release: bool,
};

pub const KeyProtocol = enum {
    legacy,
    modify_other_keys,
    kitty,
};

pub const EscapeSequence = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const EscapeSequence) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const InputResult = union(enum) {
    action: config.Action,
    mouse: MouseEvent,
    raw: []const u8,
    single_byte: u8,
    sequence: EscapeSequence,
};

pub fn translatePasteToLegacy(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (b == '\r') {
            try out.append(allocator, '\r');
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else if (b == '\n') {
            try out.append(allocator, '\r');
        } else {
            try out.append(allocator, b);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "translatePasteToLegacy converts line breaks to CR" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // LF becomes CR
    {
        const out = try translatePasteToLegacy(allocator, "line1\nline2\nline3");
        defer allocator.free(out);
        try testing.expectEqualStrings("line1\rline2\rline3", out);
    }
    // CRLF collapses to a single CR
    {
        const out = try translatePasteToLegacy(allocator, "a\r\nb");
        defer allocator.free(out);
        try testing.expectEqualStrings("a\rb", out);
    }
    // Plain text passes through untouched
    {
        const out = try translatePasteToLegacy(allocator, "no newlines here");
        defer allocator.free(out);
        try testing.expectEqualStrings("no newlines here", out);
    }
    // Empty input
    {
        const out = try translatePasteToLegacy(allocator, "");
        defer allocator.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

pub fn parseInput(bytes: []const u8, cfg: *const config.Config, protocol: KeyProtocol) InputResult {
    if (bytes.len == 0) return .{ .raw = bytes };

    if (parseSgrMouse(bytes)) |mouse_ev| {
        return .{ .mouse = mouse_ev };
    }

    if (extractChord(bytes)) |chord| {
        if (cfg.getAction(chord)) |act| {
            return .{ .action = act };
        }
        if (encodeExtendedKey(chord, protocol)) |seq| {
            return .{ .sequence = seq };
        }
        if (chordToLegacy(chord)) |legacy_byte| {
            return .{ .single_byte = legacy_byte };
        }
    }

    if (normalizeFunctionKey(bytes)) |seq| {
        return .{ .sequence = seq };
    }

    return .{ .raw = bytes };
}

const Param = struct {
    value: u32,
    event: u32 = 1,
};

fn parseParam(tok: []const u8) ?Param {
    var it = std.mem.splitScalar(u8, tok, ':');
    const head = it.next() orelse return null;
    if (head.len == 0) return null;
    const value = std.fmt.parseInt(u32, head, 10) catch return null;
    var event: u32 = 1;
    if (it.next()) |ev| {
        event = std.fmt.parseInt(u32, ev, 10) catch 1;
    }
    return .{ .value = value, .event = event };
}

fn chordFromMods(mod: u32, code: config.KeyCode) config.KeyChord {
    const bits: u32 = if (mod > 0) (mod - 1) & 0x7 else 0;
    return .{
        .shift = (bits & 1) != 0,
        .alt = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
        .code = code,
    };
}

fn codepointToKeyCode(code: u32) ?config.KeyCode {
    return switch (code) {
        13 => .enter,
        9 => .tab,
        27 => .escape,
        127, 8 => .backspace,
        // Kitty functional key codes for the cursor blocks.
        57350 => .left,
        57351 => .right,
        57352 => .up,
        57353 => .down,
        57354 => .page_up,
        57355 => .page_down,
        else => blk: {
            if (code >= 'a' and code <= 'z') break :blk .{ .char = @intCast(code) };
            if (code >= 'A' and code <= 'Z') break :blk .{ .char = std.ascii.toLower(@intCast(code)) };
            if (code >= '0' and code <= '9') break :blk .{ .char = @intCast(code) };
            if (code == 32) break :blk .{ .char = ' ' };
            break :blk null;
        },
    };
}

const FuncKey = enum { home, end, insert, delete };

fn normalizeFunctionKey(bytes: []const u8) ?EscapeSequence {
    if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != '[') return null;

    const final = bytes[bytes.len - 1];
    const inner = bytes[2 .. bytes.len - 1];
    if (final != 'H' and final != 'F' and final != '~' and final != 'u') return null;

    var it = std.mem.splitScalar(u8, inner, ';');
    var key: FuncKey = undefined;
    var mod: Param = .{ .value = 1 };

    switch (final) {
        'H', 'F' => {
            const first = it.next() orelse "";
            if (first.len != 0 and !std.mem.eql(u8, first, "1")) return null;
            if (it.next()) |m| mod = parseParam(m) orelse return null;
            key = if (final == 'H') .home else .end;
        },
        '~' => {
            const code = parseParam(it.next() orelse "") orelse return null;
            if (it.next()) |m| mod = parseParam(m) orelse return null;
            key = switch (code.value) {
                1, 7 => .home,
                4, 8 => .end,
                2 => .insert,
                3 => .delete,
                else => return null,
            };
        },
        'u' => {
            const code = parseParam(it.next() orelse "") orelse return null;
            if (it.next()) |m| mod = parseParam(m) orelse return null;
            key = switch (code.value) {
                57348 => .insert,
                57349 => .delete,
                57356 => .home,
                57357 => .end,
                else => return null,
            };
        },
        else => return null,
    }

    if (mod.event == 3) return null;

    const bits: u32 = if (mod.value > 0) (mod.value - 1) & 0x7 else 0;
    var seq = EscapeSequence{};
    if (bits == 0) {
        const base = switch (key) {
            .home => "\x1b[H",
            .end => "\x1b[F",
            .insert => "\x1b[2~",
            .delete => "\x1b[3~",
        };
        @memcpy(seq.buf[0..base.len], base);
        seq.len = base.len;
        return seq;
    }

    const m = bits + 1;
    seq.len = switch (key) {
        .home => (std.fmt.bufPrint(&seq.buf, "\x1b[1;{d}H", .{m}) catch return null).len,
        .end => (std.fmt.bufPrint(&seq.buf, "\x1b[1;{d}F", .{m}) catch return null).len,
        .insert => (std.fmt.bufPrint(&seq.buf, "\x1b[2;{d}~", .{m}) catch return null).len,
        .delete => (std.fmt.bufPrint(&seq.buf, "\x1b[3;{d}~", .{m}) catch return null).len,
    };
    return seq;
}

fn encodeExtendedKey(chord: config.KeyChord, protocol: KeyProtocol) ?EscapeSequence {
    const mod: u8 = 1 +
        @as(u8, @intFromBool(chord.shift)) +
        @as(u8, @intFromBool(chord.alt)) * 2 +
        @as(u8, @intFromBool(chord.ctrl)) * 4;

    switch (chord.code) {
        .enter => {
            // Plain Enter is always a carriage return.
            if (!chord.shift and !chord.ctrl and !chord.alt) return null;
            if (protocol == .legacy) return null;
            var seq = EscapeSequence{};
            if (protocol == .kitty) {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[13;{d}u", .{mod}) catch return null).len;
            } else {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[27;{d};13~", .{mod}) catch return null).len;
            }
            return seq;
        },
        .tab => {
            // Shift+Tab has a universal legacy encoding (backtab).
            if (chord.shift and !chord.ctrl and !chord.alt) {
                var seq = EscapeSequence{};
                @memcpy(seq.buf[0..3], "\x1b[Z");
                seq.len = 3;
                return seq;
            }
            if (protocol == .legacy or !chord.ctrl) return null;
            var seq = EscapeSequence{};
            if (protocol == .kitty) {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[9;{d}u", .{mod}) catch return null).len;
            } else {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[27;{d};9~", .{mod}) catch return null).len;
            }
            return seq;
        },
        .up, .down, .left, .right => {
            const final: u8 = switch (chord.code) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                else => unreachable,
            };
            var seq = EscapeSequence{};
            if (!chord.shift and !chord.alt and !chord.ctrl) {
                seq.buf[0] = 0x1b;
                seq.buf[1] = '[';
                seq.buf[2] = final;
                seq.len = 3;
            } else {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[1;{d}{c}", .{ mod, final }) catch return null).len;
            }
            return seq;
        },
        .page_up, .page_down => {
            const code: u8 = switch (chord.code) {
                .page_up => 5,
                .page_down => 6,
                else => unreachable,
            };
            var seq = EscapeSequence{};
            if (!chord.shift and !chord.alt and !chord.ctrl) {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[{d}~", .{code}) catch return null).len;
            } else {
                seq.len = (std.fmt.bufPrint(&seq.buf, "\x1b[{d};{d}~", .{ code, mod }) catch return null).len;
            }
            return seq;
        },
        .char => |c| {
            // print verbatim.
            if (chord.alt and !chord.ctrl and c >= 0x20 and c <= 0x7e) {
                var seq = EscapeSequence{};
                seq.buf[0] = 0x1b;
                seq.buf[1] = if (chord.shift) std.ascii.toUpper(c) else c;
                seq.len = 2;
                return seq;
            }
            return null;
        },
        else => return null,
    }
}

pub fn chordToLegacy(chord: config.KeyChord) ?u8 {
    if (!chord.alt) {
        if (!chord.ctrl and !chord.shift) {
            switch (chord.code) {
                .char => |c| return c,
                .enter => return '\r',
                .tab => return '\t',
                .backspace => return 0x7f,
                .escape => return 0x1b,
                else => {},
            }
        } else if (chord.ctrl and !chord.shift) {
            switch (chord.code) {
                .char => |c| {
                    if (c >= 'a' and c <= 'z') return c - 'a' + 1;
                    if (c >= 'A' and c <= 'Z') return c - 'A' + 1;
                    if (c == ' ' or c == '@') return 0;
                    if (c == '[') return 27;
                    if (c == '\\') return 28;
                    if (c == ']') return 29;
                    if (c == '^') return 30;
                    if (c == '_') return 31;
                },
                .enter => return '\r',
                .tab => return '\t',
                .backspace => return 0x08,
                .escape => return 0x1b,
                else => {},
            }
        } else if (!chord.ctrl and chord.shift) {
            switch (chord.code) {
                .char => |c| {
                    if (c >= 'a' and c <= 'z') return c - 'a' + 'A';
                    return c;
                },
                .enter => return '\r',
                else => {},
            }
        }
    }
    return null;
}

pub fn parseSgrMouse(bytes: []const u8) ?MouseEvent {
    if (bytes.len < 6 or !std.mem.startsWith(u8, bytes, "\x1b[<")) return null;
    const last_char = bytes[bytes.len - 1];
    if (last_char != 'M' and last_char != 'm') return null;

    const inner = bytes[3 .. bytes.len - 1];
    var it = std.mem.splitScalar(u8, inner, ';');
    const btn_str = it.next() orelse return null;
    const x_str = it.next() orelse return null;
    const y_str = it.next() orelse return null;

    const btn = std.fmt.parseInt(u32, btn_str, 10) catch return null;
    const x = std.fmt.parseInt(u16, x_str, 10) catch return null;
    const y = std.fmt.parseInt(u16, y_str, 10) catch return null;

    return MouseEvent{
        .btn = btn,
        .x = x,
        .y = y,
        .release = (last_char == 'm'),
    };
}

pub fn extractChord(bytes: []const u8) ?config.KeyChord {
    if (bytes.len == 0) return null;

    if (bytes.len >= 4 and bytes[0] == 0x1b and bytes[1] == 0x1b and bytes[2] == '[') {
        if (extractChord(bytes[1..])) |inner| {
            var chord = inner;
            chord.alt = true;
            return chord;
        }
    }

    if (bytes.len >= 7 and std.mem.startsWith(u8, bytes, "\x1b[27;") and bytes[bytes.len - 1] == '~') {
        const inner = bytes[5 .. bytes.len - 1];
        var it = std.mem.splitScalar(u8, inner, ';');
        const mod = parseParam(it.next() orelse "") orelse return null;
        const code = parseParam(it.next() orelse "") orelse return null;
        if (mod.event == 3) return null;
        if (codepointToKeyCode(code.value)) |kc| {
            return chordFromMods(mod.value, kc);
        }
    }

    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
        const final = bytes[bytes.len - 1];
        const inner = bytes[2 .. bytes.len - 1];

        switch (final) {
            'u' => {
                var it = std.mem.splitScalar(u8, inner, ';');
                const code = parseParam(it.next() orelse "") orelse return null;
                const mod = if (it.next()) |m| (parseParam(m) orelse return null) else Param{ .value = 1 };
                if (mod.event == 3) return null;
                if (codepointToKeyCode(code.value)) |kc| {
                    return chordFromMods(mod.value, kc);
                }
            },
            'A', 'B', 'C', 'D' => {
                var it = std.mem.splitScalar(u8, inner, ';');
                const first = it.next() orelse "";
                if (first.len != 0 and !std.mem.eql(u8, first, "1")) return null;
                const mod = if (it.next()) |m| (parseParam(m) orelse return null) else Param{ .value = 1 };
                if (mod.event == 3) return null;
                const kc: config.KeyCode = switch (final) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    else => unreachable,
                };
                return chordFromMods(mod.value, kc);
            },
            '~' => {
                var it = std.mem.splitScalar(u8, inner, ';');
                const code = parseParam(it.next() orelse "") orelse return null;
                const mod = if (it.next()) |m| (parseParam(m) orelse return null) else Param{ .value = 1 };
                if (mod.event == 3) return null;
                const kc: ?config.KeyCode = switch (code.value) {
                    5 => .page_up,
                    6 => .page_down,
                    else => codepointToKeyCode(code.value),
                };
                if (kc) |k| return chordFromMods(mod.value, k);
            },
            else => {},
        }
    }

    if (bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == 0x1b and (bytes[2] == '\r' or bytes[2] == '\n')) {
        return config.KeyChord{
            .ctrl = false,
            .shift = true,
            .alt = true,
            .code = .enter,
        };
    }

    if (bytes.len == 2 and bytes[0] == 0x1b and (bytes[1] == '\r' or bytes[1] == '\n')) {
        return config.KeyChord{
            .ctrl = false,
            .shift = false,
            .alt = true,
            .code = .enter,
        };
    }

    if (bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == 'Z') {
        return config.KeyChord{
            .shift = true,
            .code = .tab,
        };
    }

    if (bytes.len == 2 and bytes[0] == 0x1b) {
        const ch = bytes[1];
        if (std.ascii.isUpper(ch)) {
            return config.KeyChord{
                .ctrl = false,
                .shift = true,
                .alt = true,
                .code = .{ .char = std.ascii.toLower(ch) },
            };
        } else if (std.ascii.isLower(ch) or std.ascii.isDigit(ch)) {
            return config.KeyChord{
                .ctrl = false,
                .shift = false,
                .alt = true,
                .code = .{ .char = ch },
            };
        }
    }

    return null;
}

test "input parse chord and actions" {
    const testing = std.testing;
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit();

    const res_cst = parseInput("\x1b[116;6u", &cfg, .legacy);
    try testing.expectEqual(config.Action.new_tab, res_cst.action);

    const res_aw = parseInput("\x1bw", &cfg, .legacy);
    try testing.expectEqual(config.Action.close_pane, res_aw.action);

    const res_hsplit = parseInput("\x1b[13;4u", &cfg, .legacy);
    try testing.expectEqual(config.Action.split_horizontal, res_hsplit.action);

    const res_hsplit2 = parseInput("\x1b\x1b\r", &cfg, .legacy);
    try testing.expectEqual(config.Action.split_horizontal, res_hsplit2.action);

    const res_vsplit = parseInput("\x1b[13;6u", &cfg, .legacy);
    try testing.expectEqual(config.Action.split_vertical, res_vsplit.action);

    const res_eof = parseInput("\x04", &cfg, .legacy);
    try testing.expect(res_eof == .raw);
    try testing.expectEqualStrings("\x04", res_eof.raw);

    const res_cw = parseInput("\x17", &cfg, .legacy);
    try testing.expect(res_cw == .raw);
    try testing.expectEqualStrings("\x17", res_cw.raw);

    // Kitty protocol with subparameters: 116:84;6:1u (Ctrl+Shift+t press event)
    const res_cst_sub = parseInput("\x1b[116:84;6:1u", &cfg, .legacy);
    try testing.expectEqual(config.Action.new_tab, res_cst_sub.action);

    // Key release event (event type 3) should not trigger action
    const res_cst_release = parseInput("\x1b[116;6:3u", &cfg, .legacy);
    try testing.expect(res_cst_release == .raw);

    // xterm modifyOtherKeys with subparameters
    const res_csw_xterm = parseInput("\x1b[27;6;119~", &cfg, .legacy);
    try testing.expectEqual(config.Action.close_pane, res_csw_xterm.action);

    // Ctrl+A in Kitty protocol (\x1b[97;5u) converts to \x01 for shell passthrough
    const res_ctrla = parseInput("\x1b[97;5u", &cfg, .legacy);
    try testing.expect(res_ctrla == .single_byte);
    try testing.expectEqual(@as(u8, 0x01), res_ctrla.single_byte);

    // Ctrl+L in Kitty protocol (\x1b[108;5u) converts to \x0c (clear screen) for shell passthrough
    const res_ctrll = parseInput("\x1b[108;5u", &cfg, .legacy);
    try testing.expect(res_ctrll == .single_byte);
    try testing.expectEqual(@as(u8, 0x0c), res_ctrll.single_byte);

    // Ctrl+Shift+C copy action tests across formats
    const res_csc_kitty = parseInput("\x1b[99;6u", &cfg, .legacy);
    try testing.expectEqual(config.Action.copy, res_csc_kitty.action);

    const res_csc_xterm1 = parseInput("\x1b[27;6;99~", &cfg, .legacy);
    try testing.expectEqual(config.Action.copy, res_csc_xterm1.action);

    const res_csc_xterm2 = parseInput("\x1b[99;6~", &cfg, .legacy);
    try testing.expectEqual(config.Action.copy, res_csc_xterm2.action);

    // Ctrl+Tab / Ctrl+Shift+Tab switch tabs
    const res_ctab = parseInput("\x1b[9;5u", &cfg, .legacy);
    try testing.expectEqual(config.Action.next_tab, res_ctab.action);

    const res_cstab = parseInput("\x1b[9;6u", &cfg, .legacy);
    try testing.expectEqual(config.Action.prev_tab, res_cstab.action);

    // Shift+Tab keeps its universal backtab encoding
    const res_stab = parseInput("\x1b[9;2u", &cfg, .legacy);
    try testing.expect(res_stab == .sequence);
    try testing.expectEqualStrings("\x1b[Z", res_stab.sequence.slice());

    const res_stab_legacy = parseInput("\x1b[Z", &cfg, .legacy);
    try testing.expect(res_stab_legacy == .sequence);
    try testing.expectEqualStrings("\x1b[Z", res_stab_legacy.sequence.slice());

    // Shift+Enter: plain Enter for legacy apps, extended encoding otherwise
    const res_senter_legacy = parseInput("\x1b[13;2u", &cfg, .legacy);
    try testing.expect(res_senter_legacy == .single_byte);
    try testing.expectEqual(@as(u8, '\r'), res_senter_legacy.single_byte);

    const res_senter_kitty = parseInput("\x1b[13;2u", &cfg, .kitty);
    try testing.expect(res_senter_kitty == .sequence);
    try testing.expectEqualStrings("\x1b[13;2u", res_senter_kitty.sequence.slice());

    const res_senter_mok = parseInput("\x1b[13;2u", &cfg, .modify_other_keys);
    try testing.expect(res_senter_mok == .sequence);
    try testing.expectEqualStrings("\x1b[27;2;13~", res_senter_mok.sequence.slice());

    // Plain Enter/Tab must never be re-encoded as extended keys
    const res_plain_enter = parseInput("\x1b[13u", &cfg, .modify_other_keys);
    try testing.expect(res_plain_enter == .single_byte);
    try testing.expectEqual(@as(u8, '\r'), res_plain_enter.single_byte);

    const res_plain_tab = parseInput("\x1b[9u", &cfg, .kitty);
    try testing.expect(res_plain_tab == .single_byte);
    try testing.expectEqual(@as(u8, '\t'), res_plain_tab.single_byte);

    // Alt+Arrow also works when the terminal prefixes Alt with an extra ESC
    const res_alt_left = parseInput("\x1b\x1b[D", &cfg, .legacy);
    try testing.expectEqual(config.Action.focus_left, res_alt_left.action);

    // normalized to the legacy form (readline expects ESC [ A, not ESC [ 1;1A).
    const res_up = parseInput("\x1b[1;1A", &cfg, .legacy);
    try testing.expect(res_up == .sequence);
    try testing.expectEqualStrings("\x1b[A", res_up.sequence.slice());

    const res_down = parseInput("\x1b[1;1B", &cfg, .modify_other_keys);
    try testing.expect(res_down == .sequence);
    try testing.expectEqualStrings("\x1b[B", res_down.sequence.slice());

    const res_right = parseInput("\x1b[1;1C", &cfg, .kitty);
    try testing.expect(res_right == .sequence);
    try testing.expectEqualStrings("\x1b[C", res_right.sequence.slice());

    const res_legacy_left = parseInput("\x1b[D", &cfg, .legacy);
    try testing.expect(res_legacy_left == .sequence);
    try testing.expectEqualStrings("\x1b[D", res_legacy_left.sequence.slice());

    // Modified cursor keys keep their modifier information
    const res_ctrl_right = parseInput("\x1b[1;5C", &cfg, .legacy);
    try testing.expect(res_ctrl_right == .sequence);
    try testing.expectEqualStrings("\x1b[1;5C", res_ctrl_right.sequence.slice());

    // Page keys likewise
    const res_pgup = parseInput("\x1b[5;1~", &cfg, .legacy);
    try testing.expect(res_pgup == .sequence);
    try testing.expectEqualStrings("\x1b[5~", res_pgup.sequence.slice());

    // Home/End/Insert/Delete with an explicit "no modifier" are normalized too
    const res_home = parseInput("\x1b[1;1H", &cfg, .legacy);
    try testing.expect(res_home == .sequence);
    try testing.expectEqualStrings("\x1b[H", res_home.sequence.slice());

    const res_end = parseInput("\x1b[1;1F", &cfg, .legacy);
    try testing.expect(res_end == .sequence);
    try testing.expectEqualStrings("\x1b[F", res_end.sequence.slice());

    const res_del = parseInput("\x1b[3;1~", &cfg, .legacy);
    try testing.expect(res_del == .sequence);
    try testing.expectEqualStrings("\x1b[3~", res_del.sequence.slice());

    const res_ins = parseInput("\x1b[2;1~", &cfg, .legacy);
    try testing.expect(res_ins == .sequence);
    try testing.expectEqualStrings("\x1b[2~", res_ins.sequence.slice());

    // Legacy forms pass through untouched
    const res_del_legacy = parseInput("\x1b[3~", &cfg, .legacy);
    try testing.expect(res_del_legacy == .sequence);
    try testing.expectEqualStrings("\x1b[3~", res_del_legacy.sequence.slice());

    const default_ctab = cfg.getAction(.{ .ctrl = true, .code = .tab });
    try testing.expectEqual(@as(?config.Action, .next_tab), default_ctab);
    const default_cstab = cfg.getAction(.{ .ctrl = true, .shift = true, .code = .tab });
    try testing.expectEqual(@as(?config.Action, .prev_tab), default_cstab);
}

test "lock bits in modifier parameters do not become modifiers" {
    const testing = std.testing;
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit();

    // must still be an unmodified arrow, not Alt+Arrow.
    const up_num = parseInput("\x1b[1;129A", &cfg, .legacy);
    try testing.expect(up_num == .sequence);
    try testing.expectEqualStrings("\x1b[A", up_num.sequence.slice());

    const up_caps = parseInput("\x1b[1;65A", &cfg, .legacy);
    try testing.expect(up_caps == .sequence);
    try testing.expectEqualStrings("\x1b[A", up_caps.sequence.slice());

    // Kitty functional key codes for the cursor block.
    const kitty_up = parseInput("\x1b[57352;129u", &cfg, .kitty);
    try testing.expect(kitty_up == .sequence);
    try testing.expectEqualStrings("\x1b[A", kitty_up.sequence.slice());

    const kitty_down = parseInput("\x1b[57353;1u", &cfg, .legacy);
    try testing.expect(kitty_down == .sequence);
    try testing.expectEqualStrings("\x1b[B", kitty_down.sequence.slice());

    const kitty_left = parseInput("\x1b[57350;1u", &cfg, .legacy);
    try testing.expect(kitty_left == .sequence);
    try testing.expectEqualStrings("\x1b[D", kitty_left.sequence.slice());

    const kitty_right = parseInput("\x1b[57351;1u", &cfg, .legacy);
    try testing.expect(kitty_right == .sequence);
    try testing.expectEqualStrings("\x1b[C", kitty_right.sequence.slice());

    // Real modifiers survive; lock bits do not leak into them.
    const ctrl_down = parseInput("\x1b[57353;133u", &cfg, .legacy);
    try testing.expect(ctrl_down == .sequence);
    try testing.expectEqualStrings("\x1b[1;5B", ctrl_down.sequence.slice());

    // Enter/Tab with lock bits still map to their control bytes.
    const enter_num = parseInput("\x1b[13;129u", &cfg, .legacy);
    try testing.expect(enter_num == .single_byte);
    try testing.expectEqual(@as(u8, '\r'), enter_num.single_byte);

    const tab_caps = parseInput("\x1b[9;65u", &cfg, .legacy);
    try testing.expect(tab_caps == .single_byte);
    try testing.expectEqual(@as(u8, '\t'), tab_caps.single_byte);

    // Page keys keep the legacy form without the lock bits.
    const pgup_num = parseInput("\x1b[57354;129u", &cfg, .legacy);
    try testing.expect(pgup_num == .sequence);
    try testing.expectEqualStrings("\x1b[5~", pgup_num.sequence.slice());

    // Home/End/Insert/Delete normalization also strips lock bits.
    const home_num = parseInput("\x1b[1;129H", &cfg, .legacy);
    try testing.expect(home_num == .sequence);
    try testing.expectEqualStrings("\x1b[H", home_num.sequence.slice());

    const end_caps = parseInput("\x1b[57357;65u", &cfg, .legacy);
    try testing.expect(end_caps == .sequence);
    try testing.expectEqualStrings("\x1b[F", end_caps.sequence.slice());

    const del_num = parseInput("\x1b[3;129~", &cfg, .legacy);
    try testing.expect(del_num == .sequence);
    try testing.expectEqualStrings("\x1b[3~", del_num.sequence.slice());

    const ins_caps = parseInput("\x1b[57348;65u", &cfg, .legacy);
    try testing.expect(ins_caps == .sequence);
    try testing.expectEqualStrings("\x1b[2~", ins_caps.sequence.slice());

    // print the escape sequence verbatim.
    const alt_b = parseInput("\x1b[98;3u", &cfg, .legacy);
    try testing.expect(alt_b == .sequence);
    try testing.expectEqualStrings("\x1bb", alt_b.sequence.slice());

    // Shift+letter from an extended encoding keeps its case.
    const shift_a = parseInput("\x1b[97;2u", &cfg, .legacy);
    try testing.expect(shift_a == .single_byte);
    try testing.expectEqual(@as(u8, 'A'), shift_a.single_byte);
}
