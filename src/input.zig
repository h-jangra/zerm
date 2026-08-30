const std = @import("std");
const config = @import("config.zig");

pub const MouseEvent = struct {
    btn: u32,
    x: u16,
    y: u16,
    release: bool,
};

pub const InputResult = union(enum) {
    action: config.Action,
    mouse: MouseEvent,
    raw: []const u8,
    single_byte: u8,
};

pub fn parseInput(bytes: []const u8, cfg: *const config.Config) InputResult {
    if (bytes.len == 0) return .{ .raw = bytes };

    if (parseSgrMouse(bytes)) |mouse_ev| {
        return .{ .mouse = mouse_ev };
    }

    if (extractChord(bytes)) |chord| {
        if (cfg.getAction(chord)) |act| {
            return .{ .action = act };
        }
        if (chordToLegacy(chord)) |legacy_byte| {
            return .{ .single_byte = legacy_byte };
        }
    }

    return .{ .raw = bytes };
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
                .char => |c| return c,
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

    if (bytes.len >= 5 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[bytes.len - 1] == 'u') {
        const inner = bytes[2 .. bytes.len - 1];
        var it = std.mem.splitScalar(u8, inner, ';');
        const code_part = it.next() orelse "";
        const mod_part = it.next() orelse "1";

        var code_tok_it = std.mem.splitScalar(u8, code_part, ':');
        const code_str = code_tok_it.next() orelse "";
        const code = std.fmt.parseInt(u32, code_str, 10) catch return null;

        var mod_tok_it = std.mem.splitScalar(u8, mod_part, ':');
        const mod_str = mod_tok_it.next() orelse "1";
        const event_str = mod_tok_it.next();
        // If event type is 3 (key release), ignore it so actions only trigger once on key press
        if (event_str) |ev| {
            if (std.mem.eql(u8, ev, "3")) return null;
        }

        const mod = std.fmt.parseInt(u32, mod_str, 10) catch 1;
        const effective_mod = if (mod > 0) mod - 1 else 0;
        const shift = (effective_mod & 1) != 0;
        const alt = (effective_mod & 2) != 0;
        const ctrl = (effective_mod & 4) != 0;

        const kcode: ?config.KeyCode = blk: {
            if (code == 13) break :blk .enter;
            if (code == 9) break :blk .tab;
            if (code == 27) break :blk .escape;
            if (code == 127 or code == 8) break :blk .backspace;
            if (code == 57358) break :blk .up;
            if (code == 57359) break :blk .down;
            if (code == 57360) break :blk .left;
            if (code == 57361) break :blk .right;
            if (code == 57362) break :blk .page_up;
            if (code == 57363) break :blk .page_down;
            if (code >= 'a' and code <= 'z') break :blk .{ .char = @intCast(code) };
            if (code >= 'A' and code <= 'Z') break :blk .{ .char = std.ascii.toLower(@intCast(code)) };
            if (code >= '0' and code <= '9') break :blk .{ .char = @intCast(code) };
            if (code == 32) break :blk .{ .char = ' ' };
            break :blk null;
        };

        if (kcode) |kc| {
            return config.KeyChord{
                .ctrl = ctrl,
                .shift = shift,
                .alt = alt,
                .code = kc,
            };
        }
    }

    if (bytes.len >= 7 and std.mem.startsWith(u8, bytes, "\x1b[27;") and bytes[bytes.len - 1] == '~') {
        const inner = bytes[5 .. bytes.len - 1];
        var it = std.mem.splitScalar(u8, inner, ';');
        const mod_part = it.next() orelse "";
        const code_part = it.next() orelse "";

        var mod_tok_it = std.mem.splitScalar(u8, mod_part, ':');
        const mod_str = mod_tok_it.next() orelse "1";
        const mod = std.fmt.parseInt(u32, mod_str, 10) catch 1;

        var code_tok_it = std.mem.splitScalar(u8, code_part, ':');
        const code_str = code_tok_it.next() orelse "";
        const code = std.fmt.parseInt(u32, code_str, 10) catch return null;

        const effective_mod = if (mod > 0) mod - 1 else 0;
        const shift = (effective_mod & 1) != 0;
        const alt = (effective_mod & 2) != 0;
        const ctrl = (effective_mod & 4) != 0;

        const kcode: ?config.KeyCode = blk: {
            if (code == 13) break :blk .enter;
            if (code == 9) break :blk .tab;
            if (code == 27) break :blk .escape;
            if (code == 127 or code == 8) break :blk .backspace;
            if (code >= 'a' and code <= 'z') break :blk .{ .char = @intCast(code) };
            if (code >= 'A' and code <= 'Z') break :blk .{ .char = std.ascii.toLower(@intCast(code)) };
            if (code >= '0' and code <= '9') break :blk .{ .char = @intCast(code) };
            if (code == 32) break :blk .{ .char = ' ' };
            break :blk null;
        };

        if (kcode) |kc| {
            return config.KeyChord{
                .ctrl = ctrl,
                .shift = shift,
                .alt = alt,
                .code = kc,
            };
        }
    }

    if (bytes.len == 6 and std.mem.startsWith(u8, bytes, "\x1b[1;")) {
        const mod_char = bytes[4];
        const dir_char = bytes[5];
        const mod = mod_char - '0';
        const effective_mod = if (mod > 0) mod - 1 else 0;

        const shift = (effective_mod & 1) != 0;
        const alt = (effective_mod & 2) != 0;
        const ctrl = (effective_mod & 4) != 0;

        const kcode: ?config.KeyCode = switch (dir_char) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => null,
        };

        if (kcode) |kc| {
            return config.KeyChord{
                .ctrl = ctrl,
                .shift = shift,
                .alt = alt,
                .code = kc,
            };
        }
    }

    if (bytes.len >= 5 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[bytes.len - 1] == '~' and std.mem.indexOfScalar(u8, bytes, ';') != null) {
        const inner = bytes[2 .. bytes.len - 1];
        var it = std.mem.splitScalar(u8, inner, ';');
        const code_part = it.next() orelse "";
        const mod_part = it.next() orelse "1";

        var code_tok_it = std.mem.splitScalar(u8, code_part, ':');
        const code_str = code_tok_it.next() orelse "";
        const code = std.fmt.parseInt(u32, code_str, 10) catch return null;

        var mod_tok_it = std.mem.splitScalar(u8, mod_part, ':');
        const mod_str = mod_tok_it.next() orelse "1";
        const mod = std.fmt.parseInt(u32, mod_str, 10) catch 1;

        const effective_mod = if (mod > 0) mod - 1 else 0;
        const shift = (effective_mod & 1) != 0;
        const alt = (effective_mod & 2) != 0;
        const ctrl = (effective_mod & 4) != 0;

        const kcode: ?config.KeyCode = blk: {
            if (code == 13) break :blk .enter;
            if (code == 9) break :blk .tab;
            if (code == 27) break :blk .escape;
            if (code == 127 or code == 8) break :blk .backspace;
            if (code == 5) break :blk .page_up;
            if (code == 6) break :blk .page_down;
            if (code >= 'a' and code <= 'z') break :blk .{ .char = @intCast(code) };
            if (code >= 'A' and code <= 'Z') break :blk .{ .char = std.ascii.toLower(@intCast(code)) };
            if (code >= '0' and code <= '9') break :blk .{ .char = @intCast(code) };
            if (code == 32) break :blk .{ .char = ' ' };
            break :blk null;
        };

        if (kcode) |kc| {
            return config.KeyChord{
                .ctrl = ctrl,
                .shift = shift,
                .alt = alt,
                .code = kc,
            };
        }
    }

    if (bytes.len >= 4 and bytes[0] == 0x1b and bytes[1] == '[' and (bytes[2] == '5' or bytes[2] == '6') and bytes[3] == '~') {
        const is_pgup = (bytes[2] == '5');
        return config.KeyChord{
            .ctrl = false,
            .shift = false,
            .alt = false,
            .code = if (is_pgup) .page_up else .page_down,
        };
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

    const res_cst = parseInput("\x1b[116;6u", &cfg);
    try testing.expectEqual(config.Action.new_tab, res_cst.action);

    const res_aw = parseInput("\x1bw", &cfg);
    try testing.expectEqual(config.Action.close_pane, res_aw.action);

    const res_hsplit = parseInput("\x1b[13;4u", &cfg);
    try testing.expectEqual(config.Action.split_horizontal, res_hsplit.action);

    const res_hsplit2 = parseInput("\x1b\x1b\r", &cfg);
    try testing.expectEqual(config.Action.split_horizontal, res_hsplit2.action);

    const res_vsplit = parseInput("\x1b[13;6u", &cfg);
    try testing.expectEqual(config.Action.split_vertical, res_vsplit.action);

    const res_eof = parseInput("\x04", &cfg);
    try testing.expect(res_eof == .raw);
    try testing.expectEqualStrings("\x04", res_eof.raw);

    const res_cw = parseInput("\x17", &cfg);
    try testing.expect(res_cw == .raw);
    try testing.expectEqualStrings("\x17", res_cw.raw);

    // Kitty protocol with subparameters: 116:84;6:1u (Ctrl+Shift+t press event)
    const res_cst_sub = parseInput("\x1b[116:84;6:1u", &cfg);
    try testing.expectEqual(config.Action.new_tab, res_cst_sub.action);

    // Key release event (event type 3) should not trigger action
    const res_cst_release = parseInput("\x1b[116;6:3u", &cfg);
    try testing.expect(res_cst_release == .raw);

    // xterm modifyOtherKeys with subparameters
    const res_csw_xterm = parseInput("\x1b[27;6;119~", &cfg);
    try testing.expectEqual(config.Action.close_pane, res_csw_xterm.action);

    // Ctrl+A in Kitty protocol (\x1b[97;5u) converts to \x01 for shell passthrough
    const res_ctrla = parseInput("\x1b[97;5u", &cfg);
    try testing.expect(res_ctrla == .single_byte);
    try testing.expectEqual(@as(u8, 0x01), res_ctrla.single_byte);

    // Ctrl+L in Kitty protocol (\x1b[108;5u) converts to \x0c (clear screen) for shell passthrough
    const res_ctrll = parseInput("\x1b[108;5u", &cfg);
    try testing.expect(res_ctrll == .single_byte);
    try testing.expectEqual(@as(u8, 0x0c), res_ctrll.single_byte);

    // Ctrl+Shift+C copy action tests across formats
    const res_csc_kitty = parseInput("\x1b[99;6u", &cfg);
    try testing.expectEqual(config.Action.copy, res_csc_kitty.action);

    const res_csc_xterm1 = parseInput("\x1b[27;6;99~", &cfg);
    try testing.expectEqual(config.Action.copy, res_csc_xterm1.action);

    const res_csc_xterm2 = parseInput("\x1b[99;6~", &cfg);
    try testing.expectEqual(config.Action.copy, res_csc_xterm2.action);
}
