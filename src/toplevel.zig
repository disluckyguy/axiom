const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_popup = @import("popup.zig");

const gpa = @import("utils.zig").gpa;

pub const Toplevel = struct {
    view: *axiom_view.View,
    xdg_toplevel: *wlr.XdgToplevel,

    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(commit),
    map: wl.Listener(void) = wl.Listener(void).init(map),
    unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
    new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(newXdgPopup),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = wl.Listener(*wlr.XdgToplevel.event.Move).init(requestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = wl.Listener(*wlr.XdgToplevel.event.Resize).init(requestResize),

    pub fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);

        if (toplevel.xdg_toplevel.base.initial_commit) {
            _ = toplevel.xdg_toplevel.setSize(0, 0);
        }
    }

    pub fn newXdgPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const toplevel: *Toplevel = @fieldParentPtr("new_popup", listener);
        // These asserts are fine since tinywl.zig doesn't support anything else that can
        // make xdg popups (e.g. layer shell).
        const xdg_surface = xdg_popup.base;

        const scene_tree = toplevel.view.popup_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };

        toplevel.view.popup_tree.node.raiseToTop();
        xdg_surface.data = @intFromPtr(scene_tree);

        scene_tree.node.data = @intFromPtr(toplevel.view.server.output_layout.outputs.first().?);

        const popup = gpa.create(axiom_popup.Popup) catch {
            std.log.err("failed to allocate new popup", .{});
            return;
        };

        popup.* = .{
            .xdg_popup = xdg_popup,
            .server = toplevel.view.server,
            .scene_tree = scene_tree,
            .root_tree = toplevel.view.scene_tree,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    pub fn map(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        toplevel.view.server.seat.focusView(toplevel.view, toplevel.xdg_toplevel.base.surface);
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        _ = toplevel;
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();

        toplevel.view.destroy();
    }

    pub fn destroyPopups(toplevel: *Toplevel) void {
        var iter = toplevel.xdg_toplevel.base.popups.safeIterator(wl.list.Direction.forward);

        while (iter.next()) |popup| {
            popup.destroy();
        }
    }

    pub fn requestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);

        const seat = toplevel.view.server.seat;
        seat.grabbed_view = toplevel.view;
        seat.cursor.cursor_mode = .move;
        seat.grab_x = seat.cursor.cursor.x - @as(f64, @floatFromInt(toplevel.view.box.x));
        seat.grab_y = seat.cursor.cursor.y - @as(f64, @floatFromInt(toplevel.view.box.y));
        toplevel.destroyPopups();
    }

    pub fn requestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        const seat = toplevel.view.server.seat;

        seat.grabbed_view = toplevel.view;
        seat.cursor.cursor_mode = .resize;
        seat.resize_edges = event.edges;

        var box: wlr.Box = undefined;
        toplevel.xdg_toplevel.base.getGeometry(&box);

        const border_x = toplevel.view.box.x + box.x + if (event.edges.right) box.width else 0;
        const border_y = toplevel.view.box.y + box.y + if (event.edges.bottom) box.height else 0;
        seat.grab_x = seat.cursor.cursor.x - @as(f64, @floatFromInt(border_x));
        seat.grab_y = seat.cursor.cursor.y - @as(f64, @floatFromInt(border_y));

        seat.grab_box = box;
        seat.grab_box.x += toplevel.view.box.x;
        seat.grab_box.y += toplevel.view.box.y;
    }
};
