const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");

const gpa = @import("utils.zig").gpa;

pub const Cursor = struct {
    server: *axiom_server.Server,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = wl.Listener(*wlr.Pointer.event.Motion).init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = wl.Listener(*wlr.Pointer.event.Button).init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(cursorFrame),

    cursor_mode: enum { passthrough, move, resize } = .passthrough,

    pub fn create(server: *axiom_server.Server) !*Cursor {
        const cursor = try gpa.create(Cursor);
        errdefer gpa.destroy(cursor);
        cursor.* = .{
            .server = server,
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        };

        const wlr_cursor = cursor.cursor;

        wlr_cursor.attachOutputLayout(server.output_layout);
        try cursor.cursor_mgr.load(1);
        wlr_cursor.events.motion.add(&cursor.cursor_motion);
        wlr_cursor.events.motion_absolute.add(&cursor.cursor_motion_absolute);
        wlr_cursor.events.button.add(&cursor.cursor_button);
        wlr_cursor.events.axis.add(&cursor.cursor_axis);
        wlr_cursor.events.frame.add(&cursor.cursor_frame);

        return cursor;
    }

    pub fn destroy(cursor: *Cursor) void {
        cursor.cursor_motion.link.remove();
        cursor.cursor_motion_absolute.link.remove();
        cursor.cursor_button.link.remove();
        cursor.cursor_axis.link.remove();
        cursor.cursor_frame.link.remove();

        gpa.destroy(cursor);
    }

    pub fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion", listener);
        cursor.cursor.move(event.device, event.delta_x, event.delta_y);
        cursor.processCursorMotion(event.time_msec);
    }

    pub fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion_absolute", listener);
        cursor.cursor.warpAbsolute(event.device, event.x, event.y);
        cursor.processCursorMotion(event.time_msec);
    }

    pub fn processCursorMotion(cursor: *Cursor, time_msec: u32) void {
        const server = cursor.server;
        switch (cursor.cursor_mode) {
            .passthrough => if (server.viewAt(cursor.cursor.x, cursor.cursor.y)) |res| {
                server.seat.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else if (server.overrideRedirectAt(cursor.cursor.x, cursor.cursor.y)) |res| {
                server.seat.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else {
                cursor.cursor.setXcursor(cursor.cursor_mgr, "default");
                server.seat.seat.pointerClearFocus();
            },
            .move => {
                const view = server.seat.grabbed_view.?;
                view.box.x = @as(i32, @intFromFloat(cursor.cursor.x - server.seat.grab_x));
                view.box.y = @as(i32, @intFromFloat(cursor.cursor.y - server.seat.grab_y));
                view.scene_tree.node.setPosition(view.box.x, view.box.y);
            },
            .resize => {
                const view = server.seat.grabbed_view.?;
                const border_x = @as(i32, @intFromFloat(cursor.cursor.x - server.seat.grab_x));
                const border_y = @as(i32, @intFromFloat(cursor.cursor.y - server.seat.grab_y));

                var new_left = server.seat.grab_box.x;
                var new_right = server.seat.grab_box.x + server.seat.grab_box.width;
                var new_top = server.seat.grab_box.y;
                var new_bottom = server.seat.grab_box.y + server.seat.grab_box.height;

                if (server.seat.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom)
                        new_top = new_bottom - 1;
                } else if (server.seat.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top)
                        new_bottom = new_top + 1;
                }

                if (server.seat.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right)
                        new_left = new_right - 1;
                } else if (server.seat.resize_edges.right) {
                    new_right = border_x;
                    if (new_right <= new_left)
                        new_right = new_left + 1;
                }

                const new_width = new_right - new_left;
                const new_height = new_bottom - new_top;

                switch (view.impl) {
                    .xwayland_surface => |xwayland_view| {
                        const xwayland_surface = xwayland_view.surface;
                        xwayland_view.view.box.x = new_left - xwayland_surface.x;
                        xwayland_view.view.box.y = new_top - xwayland_surface.y;
                        xwayland_view.view.scene_tree.node.setPosition(xwayland_surface.x, xwayland_surface.y);

                        _ = xwayland_surface.configure(
                            xwayland_surface.x,
                            xwayland_surface.y,
                            @intCast(new_width),
                            @intCast(new_height),
                        );
                    },
                    .toplevel => |toplevel| {
                        var geo_box: wlr.Box = undefined;
                        _ = toplevel.xdg_toplevel.base.getGeometry(&geo_box);
                        toplevel.view.box.x = new_left - geo_box.x;
                        toplevel.view.box.y = new_top - geo_box.y;
                        toplevel.view.scene_tree.node.setPosition(toplevel.view.box.x, toplevel.view.box.y);
                        _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
                    },
                    .none => {},
                }
            },
        }
    }

    pub fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_button", listener);
        const server = cursor.server;
        const seat = server.seat;
        _ = seat.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            cursor.cursor_mode = .passthrough;
        } else if (server.viewAt(cursor.cursor.x, cursor.cursor.y)) |res| {
            seat.focusView(res.view, res.surface);
        } else if (server.overrideRedirectAt(cursor.cursor.x, cursor.cursor.y)) |res| {
            seat.focusOverrideRedirect(res.override_redirect);
        }
    }

    pub fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_axis", listener);
        const server = cursor.server;
        server.seat.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    pub fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_frame", listener);
        const server = cursor.server;
        server.seat.seat.pointerNotifyFrame();
    }
};
