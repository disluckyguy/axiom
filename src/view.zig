const std = @import("std");
const posix = std.posix;
const math = std.math;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const c = @import("c.zig");
const pixman = @import("pixman");

const wlr = @import("wlroots");

const axiom_server = @import("server.zig");
const axiom_toplevel = @import("toplevel.zig");
const axiom_xwayland = @import("xwayland.zig");
const gpa = @import("utils.zig").gpa;

pub const Constraints = struct {
    min_width: u31 = 1,
    max_width: u31 = math.maxInt(u31),
    min_height: u31 = 1,
    max_height: u31 = math.maxInt(u31),
};

pub const Impl = union(enum) {
    xwayland_surface: axiom_xwayland.XwaylandView,
    toplevel: axiom_toplevel.Toplevel,
    none,
};
pub const View = struct {
    server: *axiom_server.Server,
    impl: Impl,
    link: wl.list.Link,

    scene_tree: *wlr.SceneTree,
    surface_tree: *wlr.SceneTree,
    popup_tree: *wlr.SceneTree,

    output: ?*wlr.Output = null,

    constraints: Constraints = .{},
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    focus: u32 = 0,

    fullscreen: bool = false,
    resizing: bool = false,

    pub fn move(view: *View, delta_x: i32, delta_y: i32) void {
        view.box.x += delta_x;
        view.box.x = @max(view.box.x, 0);

        view.box.y += delta_y;
        view.box.y = @max(view.box.y, 0);
    }

    pub fn create(impl: Impl, server: *axiom_server.Server) error{OutOfMemory}!*View {
        std.debug.assert(impl != .none);
        const view = try gpa.create(View);
        errdefer gpa.destroy(view);

        const tree = try server.scene.tree.createSceneTree();
        errdefer tree.node.destroy();

        const popup_tree = try server.scene.tree.createSceneTree();
        errdefer popup_tree.node.destroy();

        view.* = .{
            .server = server,
            .impl = impl,
            .link = undefined,
            .scene_tree = tree,
            .surface_tree = try tree.createSceneTree(),
            .popup_tree = popup_tree,
        };

        server.views.prepend(view);

        view.scene_tree.node.setEnabled(true);
        view.scene_tree.node.data = @intFromPtr(view);

        view.popup_tree.node.setEnabled(true);
        view.popup_tree.node.data = @intFromPtr(view);

        return view;
    }

    pub fn destroy(view: *View) void {
        std.debug.assert(view.impl != .none);

        view.surface_tree.node.destroy();
        view.popup_tree.node.destroy();

        view.link.remove();

        gpa.destroy(view);
    }

    pub fn rootSurface(view: View) ?*wlr.Surface {
        return switch (view.impl) {
            .toplevel => |toplevel| toplevel.xdg_toplevel.base.surface,
            .xwayland_surface => |xwayland_view| xwayland_view.surface.surface,
            .none => null,
        };
    }

    pub fn close(view: View) void {
        switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.close(),
            .none => {},
        }
    }
    pub fn destroyPopups(view: View) void {
        switch (view.impl) {
            .toplevel => |toplevel| toplevel.destroyPopups(),
            .xwayland_view, .none => {},
        }
    }

    pub fn getTitle(view: View) ?[*:0]const u8 {
        return switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.title,
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.title,
            .none => unreachable,
        };
    }
};
