const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const gpa = @import("utils.zig").gpa;

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,
    server: *axiom_server.Server,

    scene_tree: *wlr.SceneTree,
    root_tree: *wlr.SceneTree,

    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
    reposition: wl.Listener(void) = wl.Listener(void).init(reposition),

    pub fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (popup.xdg_popup.base.initial_commit) {
            reposition(&popup.reposition);
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    pub fn destroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);

        popup.commit.link.remove();
        popup.destroy.link.remove();

        gpa.destroy(popup);
    }

    fn reposition(listener: *wl.Listener(void)) void {
        std.log.info("repositioning", .{});
        const popup: *Popup = @fieldParentPtr("reposition", listener);
        const view: *axiom_view.View = @ptrFromInt(popup.root_tree.node.data);
        const output = view.rootSurface().?.current_outputs.first().?.output;
        var box: wlr.Box = undefined;
        popup.server.output_layout.getBox(output, &box);

        var root_lx: c_int = undefined;
        var root_ly: c_int = undefined;
        _ = popup.root_tree.node.coords(&root_lx, &root_ly);

        std.log.info("{}", .{popup.scene_tree.node.x});

        box.x -= root_lx;
        box.y -= root_ly;

        std.log.info("{}", .{box.y});
    }
};
