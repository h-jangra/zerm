const std = @import("std");
const posix = std.posix;
const app_mod = @import("app.zig");
const pty_mod = @import("pty.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    pty_mod.global_envp = init.environ.block.slice.ptr;
    pty_mod.default_shell = init.environ.getPosix("SHELL");

    const allocator = std.heap.smp_allocator;
    var custom_shell: ?[]const u8 = null;

    var it = init.args.iterate();
    _ = it.next();

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const h = "zerm - minimal terminal multiplexer\n";
            _ = posix.system.write(posix.STDOUT_FILENO, h.ptr, h.len);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            const ver = "zerm 0.1.0\n";
            _ = posix.system.write(posix.STDOUT_FILENO, ver.ptr, ver.len);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--shell")) {
            if (it.next()) |sh| {
                custom_shell = sh;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            custom_shell = arg;
        }
    }

    const app = app_mod.App.init(allocator, custom_shell) catch |err| {
        std.debug.print("Failed to initialize zerm: {s}\n", .{@errorName(err)});
        return err;
    };
    defer app.deinit();

    app.run() catch |err| {
        std.debug.print("Error during execution: {s}\n", .{@errorName(err)});
    };
}
