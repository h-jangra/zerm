const std = @import("std");
const posix = std.posix;

pub const TerminalState = struct {
    orig_termios: posix.termios,
    raw_enabled: bool = false,

    pub fn init() !TerminalState {
        const orig = try posix.tcgetattr(posix.STDIN_FILENO);
        return TerminalState{
            .orig_termios = orig,
            .raw_enabled = false,
        };
    }

    pub fn enableRawMode(self: *TerminalState) !void {
        var raw = self.orig_termios;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        self.raw_enabled = true;

        const enter_seq = "\x1b[?1049h\x1b[?25h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[>1u\x1b[>4;2m";
        _ = posix.system.write(posix.STDOUT_FILENO, enter_seq.ptr, enter_seq.len);
    }

    pub fn restore(self: *TerminalState) void {
        const leave_seq = "\x1b[0m\x1b[0 q\x1b[?25h\x1b[>4;0m\x1b[<u\x1b[?1000l\x1b[?1002l\x1b[?1006l\x1b[?1049l";
        _ = posix.system.write(posix.STDOUT_FILENO, leave_seq.ptr, leave_seq.len);

        if (self.raw_enabled) {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig_termios) catch {};
            self.raw_enabled = false;
        }
    }

    pub fn getSize() struct { cols: u16, rows: u16 } {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(posix.STDIN_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(rc)) == 0 and ws.col > 0 and ws.row > 0) {
            return .{ .cols = ws.col, .rows = ws.row };
        }
        return .{ .cols = 80, .rows = 24 };
    }
};
