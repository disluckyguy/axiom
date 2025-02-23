const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");

const Server = @import("server.zig").Server;
const gpa = @import("utils.zig").gpa;

pub var server: Server = undefined;

pub fn main() anyerror!void {
    wlr.log.init(.debug, null);

    try server.init();
    defer server.deinit();

    try server.start();

    if (std.os.argv.len >= 2) {
        const cmd = std.mem.span(std.os.argv[1]);
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, gpa);
        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        child.env_map = &env_map;
        try child.spawn();
    }

    //std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{server.socket});
    server.wl_server.run();
}
