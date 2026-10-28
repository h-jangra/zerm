const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub var global_envp: ?[*:null]const ?[*:0]const u8 = null;
pub var default_shell: ?[]const u8 = null;

pub const Pty = struct {
    master: posix.fd_t,
    pid: posix.pid_t,
    is_alive: bool,

    pub fn spawn(cols: u16, rows: u16, custom_shell: ?[]const u8, cwd: ?[]const u8) !Pty {
        const master = try posix.openatZ(posix.AT.FDCWD, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        errdefer _ = posix.system.close(master);

        var unlock: c_int = 0;
        _ = posix.system.ioctl(master, posix.T.IOCSPTLCK, @intFromPtr(&unlock));

        const flags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
        const slave_res = posix.system.ioctl(master, posix.T.IOCGPTPEER, flags);
        var slave: posix.fd_t = undefined;
        if (@as(isize, @bitCast(slave_res)) >= 0) {
            slave = @intCast(slave_res);
        } else {
            var ptn: c_int = 0;
            const gptn_res = posix.system.ioctl(master, posix.T.IOCGPTN, @intFromPtr(&ptn));
            if (@as(isize, @bitCast(gptn_res)) != 0) return error.PtyError;

            var pts_path: [64:0]u8 = undefined;
            const path = try std.mem.printSentinel(&pts_path, "/dev/pts/{d}", .{ptn}, 0);
            slave = try posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        }
        defer _ = posix.system.close(slave);

        var ws = posix.winsize{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = posix.system.ioctl(slave, posix.T.IOCSWINSZ, @intFromPtr(&ws));

        var shell_buf: [256:0]u8 = undefined;
        var shell_path: [:0]const u8 = "/bin/sh";
        if (custom_shell) |sh| {
            if (sh.len < shell_buf.len) {
                @memcpy(shell_buf[0..sh.len], sh);
                shell_buf[sh.len] = 0;
                shell_path = shell_buf[0..sh.len :0];
            }
        } else if (default_shell) |sh| {
            if (sh.len < shell_buf.len) {
                @memcpy(shell_buf[0..sh.len], sh);
                shell_buf[sh.len] = 0;
                shell_path = shell_buf[0..sh.len :0];
            }
        }

        var cwd_buf: [4096:0]u8 = undefined;
        var cwd_path: ?[:0]const u8 = null;
        if (cwd) |dir| {
            if (dir.len > 0 and dir.len < cwd_buf.len) {
                @memcpy(cwd_buf[0..dir.len], dir);
                cwd_buf[dir.len] = 0;
                cwd_path = cwd_buf[0..dir.len :0];
            }
        }

        const pid_res = linux.fork();
        const pid_val: isize = @bitCast(pid_res);
        if (pid_val < 0) {
            return error.ForkFailed;
        } else if (pid_val == 0) {
            _ = linux.setsid();
            _ = posix.system.ioctl(slave, posix.T.IOCSCTTY, 0);

            if (cwd_path) |dir| {
                _ = linux.chdir(dir.ptr);
            }

            _ = posix.system.dup2(slave, 0);
            _ = posix.system.dup2(slave, 1);
            _ = posix.system.dup2(slave, 2);

            _ = posix.system.close(slave);
            _ = posix.system.close(master);

            var fd_i: c_int = 3;
            while (fd_i < 256) : (fd_i += 1) {
                _ = posix.system.close(fd_i);
            }

            var env_storage: [512:null]?[*:0]const u8 = undefined;
            var env_count: usize = 0;
            env_storage[env_count] = "TERM=xterm-256color";
            env_count += 1;
            env_storage[env_count] = "COLORTERM=truecolor";
            env_count += 1;
            env_storage[env_count] = "ZERM=1";
            env_count += 1;

            if (global_envp) |ge| {
                var i: usize = 0;
                while (ge[i]) |entry| : (i += 1) {
                    const entry_slice = std.mem.span(entry);
                    if (!std.mem.startsWith(u8, entry_slice, "TERM=") and
                        !std.mem.startsWith(u8, entry_slice, "COLORTERM=") and
                        !std.mem.startsWith(u8, entry_slice, "ZERM="))
                    {
                        if (env_count + 1 < env_storage.len) {
                            env_storage[env_count] = entry;
                            env_count += 1;
                        }
                    }
                }
            }
            env_storage[env_count] = null;

            const base_name = std.fs.path.basename(shell_path);
            var arg0_buf: [128:0]u8 = undefined;
            arg0_buf[0] = '-';
            const copy_len = @min(126, base_name.len);
            @memcpy(arg0_buf[1 .. 1 + copy_len], base_name[0..copy_len]);
            arg0_buf[1 + copy_len] = 0;

            const argv = [_:null]?[*:0]const u8{ &arg0_buf, null };
            _ = linux.execve(shell_path.ptr, &argv, @ptrCast(&env_storage));
            linux.exit(1);
        }

        const child_pid: posix.pid_t = @intCast(pid_val);

        const cur_flags = posix.system.fcntl(master, posix.F.GETFL, 0);
        if (@as(isize, @bitCast(cur_flags)) >= 0) {
            const nb_u32: u32 = @bitCast(linux.O{ .NONBLOCK = true });
            const nb_flag: usize = nb_u32;
            _ = posix.system.fcntl(master, posix.F.SETFL, cur_flags | nb_flag);
        }

        return Pty{
            .master = master,
            .pid = child_pid,
            .is_alive = true,
        };
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        var ws = posix.winsize{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = posix.system.ioctl(self.master, posix.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Current working directory of the shell running in this pane. Used so
    /// new tabs/panes inherit the directory they are opened from.
    pub fn getCwd(self: *Pty, buf: []u8) ?[]const u8 {
        if (readProcCwd(self.pid, buf)) |cwd| return cwd;

        var fg_pgrp: posix.pid_t = 0;
        if (posix.system.tcgetpgrp(self.master, &fg_pgrp) == 0 and fg_pgrp > 0) {
            if (readProcCwd(fg_pgrp, buf)) |cwd| return cwd;
        }
        return null;
    }

    fn readProcCwd(pid: posix.pid_t, buf: []u8) ?[]const u8 {
        var path_buf: [64]u8 = undefined;
        const path = std.mem.printSentinel(&path_buf, "/proc/{d}/cwd", .{pid}, 0) catch return null;
        const rc = posix.system.readlink(path, buf.ptr, buf.len);
        const n: isize = @bitCast(rc);
        if (n <= 0 or n > buf.len) return null;
        return buf[0..@intCast(n)];
    }

    pub fn write(self: *Pty, bytes: []const u8) isize {
        if (bytes.len == 0) return 0;
        const res = posix.system.write(self.master, bytes.ptr, bytes.len);
        return @bitCast(res);
    }

    pub fn read(self: *Pty, buf: []u8) isize {
        if (buf.len == 0) return 0;
        const res = posix.system.read(self.master, buf.ptr, buf.len);
        return @bitCast(res);
    }

    pub fn checkAlive(self: *Pty) bool {
        if (!self.is_alive) return false;
        var status: i32 = 0;
        const res = linux.waitpid(self.pid, &status, posix.W.NOHANG);
        const res_val: isize = @bitCast(res);
        if (res_val > 0 or res_val == -@as(isize, @backingInt(linux.E.CHILD))) {
            self.is_alive = false;
            return false;
        }
        return true;
    }

    pub fn deinit(self: *Pty) void {
        if (self.is_alive) {
            _ = linux.kill(self.pid, linux.SIG.TERM);
            var status: i32 = 0;
            _ = linux.waitpid(self.pid, &status, posix.W.NOHANG);
            self.is_alive = false;
        }
        _ = posix.system.close(self.master);
    }
};
