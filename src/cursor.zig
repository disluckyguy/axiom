const std = @import("std");
const posix = std.posix;

const c = @import("c.zig");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_seat = @import("seat.zig");
const axiom_root = @import("root.zig");
const axiom_output = @import("output.zig");

const gpa = @import("utils.zig").gpa;
const server = &@import("main.zig").server;

pub const CursorMode = union(enum) {
    passthrough: void,
    move: struct {
        view: *axiom_view.View,

        delta_x: f64 = 0,
        delta_y: f64 = 0,

        offset_x: i32,

        offset_y: i32,
    },
    resize: struct {
        view: *axiom_view.View,

        initial_width: u31,
        initial_height: u31,

        delta_x: f64 = 0,
        delta_y: f64 = 0,

        x: i32 = 0,
        y: i32 = 0,

        edges: wlr.Edges,
        offset_x: i32,
        offset_y: i32,
    },
};

const LayoutPoint = struct {
    lx: f64,
    ly: f64,
};

pub const Cursor = struct {
    wlr_cursor: *wlr.Cursor,
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = wl.Listener(*wlr.Seat.event.RequestSetCursor).init(handleRequestSetCursor),
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = wl.Listener(*wlr.Pointer.event.Motion).init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = wl.Listener(*wlr.Pointer.event.Button).init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(cursorFrame),

    cursor_mode: CursorMode = .passthrough,

    inflight_mode: CursorMode = .passthrough,
    default_size: u32 = 24,

    seat: *axiom_seat.Seat,
    xcursor_manager: *wlr.XcursorManager,

    xcursor_name: ?[*:0]const u8 = null,

    pressed_count: u32 = 0,

    // hide_cursor_timer: *wl.EventSource,

    // hidden: bool = false,
    // may_need_warp: bool = false,

    focus_follows_cursor_target: ?*axiom_view.View = null,

    pub fn init(cursor: *Cursor, seat: *axiom_seat.Seat) !void {
        const wlr_cursor = try wlr.Cursor.create();

        errdefer wlr_cursor.destroy();
        wlr_cursor.attachOutputLayout(server.root.output_layout);

        // This is here so that cursor.xcursor_manager doesn't need to be an
        // optional pointer. This isn't optimal as it does a needless allocation,
        // but this is not a hot path.
        const xcursor_manager = try wlr.XcursorManager.create(null, cursor.default_size);

        try xcursor_manager.load(1);
        errdefer xcursor_manager.destroy();

        //const event_loop = server.wl_server.getEventLoop();
        cursor.* = .{
            .seat = seat,
            .wlr_cursor = wlr_cursor,
            .xcursor_manager = xcursor_manager,
            //.hide_cursor_timer = try event_loop.addTimer(*Cursor, handleHideCursorTimeout, cursor),
        };
        //errdefer cursor.hide_cursor_timer.remove();
        //try cursor.hide_cursor_timer.timerUpdate(server.config.cursor_hide_timeout);
        try cursor.setTheme(null, null);

        // wlr_cursor *only* displays an image on screen. It does not move around
        // when the pointer moves. However, we can attach input devices to it, and
        // it will generate aggregate events for all of them. In these events, we
        // can choose how we want to process them, forwarding them to clients and
        // moving the cursor around.

        wlr_cursor.events.axis.add(&cursor.cursor_axis);
        wlr_cursor.events.button.add(&cursor.cursor_button);
        wlr_cursor.events.frame.add(&cursor.cursor_frame);
        wlr_cursor.events.motion_absolute.add(&cursor.cursor_motion_absolute);
        wlr_cursor.events.motion.add(&cursor.cursor_motion);
        // wlr_cursor.events.swipe_begin.add(&cursor.swipe_begin);
        // wlr_cursor.events.swipe_update.add(&cursor.swipe_update);
        // wlr_cursor.events.swipe_end.add(&cursor.swipe_end);
        // wlr_cursor.events.pinch_begin.add(&cursor.pinch_begin);
        // wlr_cursor.events.pinch_update.add(&cursor.pinch_update);
        // wlr_cursor.events.pinch_end.add(&cursor.pinch_end);
        seat.seat.events.request_set_cursor.add(&cursor.request_set_cursor);

        // wlr_cursor.events.touch_down.add(&cursor.touch_down);
        // wlr_cursor.events.touch_motion.add(&cursor.touch_motion);
        // wlr_cursor.events.touch_up.add(&cursor.touch_up);
        // wlr_cursor.events.touch_cancel.add(&cursor.touch_cancel);
        // wlr_cursor.events.touch_frame.add(&cursor.touch_frame);

        // wlr_cursor.events.tablet_tool_axis.add(&cursor.tablet_tool_axis);
        // wlr_cursor.events.tablet_tool_proximity.add(&cursor.tablet_tool_proximity);
        // wlr_cursor.events.tablet_tool_tip.add(&cursor.tablet_tool_tip);
        // wlr_cursor.events.tablet_tool_button.add(&cursor.tablet_tool_button);
    }

    pub fn deinit(cursor: *Cursor) void {
        cursor.hide_cursor_timer.remove();
        cursor.xcursor_manager.destroy();
        cursor.wlr_cursor.destroy();
    }

    pub fn setTheme(cursor: *Cursor, theme: ?[*:0]const u8, _size: ?u32) !void {
        const size = _size orelse 24;

        const xcursor_manager = try wlr.XcursorManager.create(theme, size);
        errdefer xcursor_manager.destroy();

        // If this cursor belongs to the default seat, set the xcursor environment
        // variables as well as the xwayland cursor theme.
        //if (cursor.seat == server.input_manager.defaultSeat()) {
        const size_str = try std.fmt.allocPrintZ(gpa, "{}", .{size});
        defer gpa.free(size_str);
        if (c.setenv("XCURSOR_SIZE", size_str.ptr, 1) < 0) return error.OutOfMemory;
        if (theme) |t| if (c.setenv("XCURSOR_THEME", t, 1) < 0) return error.OutOfMemory;
        try xcursor_manager.load(1);
        const wlr_xcursor = xcursor_manager.getXcursor("default", 1).?;
        const image = wlr_xcursor.images[0];
        server.xwayland.setCursor(
            image.buffer,
            image.width * 4,
            image.width,
            image.height,
            @intCast(image.hotspot_x),
            @intCast(image.hotspot_y),
        );
        //}

        // Everything fallible is now done so the the old xcursor_manager can be destroyed.
        cursor.xcursor_manager.destroy();
        cursor.xcursor_manager = xcursor_manager;

        if (cursor.xcursor_name) |name| {
            cursor.setXcursor(name);
        }
    }

    pub fn setXcursor(cursor: *Cursor, name: [*:0]const u8) void {
        cursor.wlr_cursor.setXcursor(cursor.xcursor_manager, name);
        cursor.xcursor_name = name;
    }

    fn clearFocus(cursor: *Cursor) void {
        cursor.setXcursor("default");
        cursor.seat.seat.pointerNotifyClearFocus();
    }

    pub fn handleRequestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("request_set_cursor", listener);
        const seat = cursor.seat;
        if (event.seat_client == seat.seat.pointer_state.focused_client)
            seat.cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    pub fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion", listener);
        cursor.processMotion(
            event.device,
            event.time_msec,
            event.delta_x,
            event.delta_y,
            event.unaccel_dx,
            event.unaccel_dy,
        );
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion_absolute", listener);

        //cursor.seat.handleActivity();

        var lx: f64 = undefined;
        var ly: f64 = undefined;
        cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

        cursor.wlr_cursor.warpAbsolute(event.device, event.x, event.y);

        const dx = lx - cursor.wlr_cursor.x;
        const dy = ly - cursor.wlr_cursor.y;

        cursor.processMotion(event.device, event.time_msec, dx, dy, dx, dy);
    }

    // pub fn processMotion(cursor: *Cursor, device: *wlr.InputDevice, time_msec: u32, dx: i32, dy: i32) void {
    //     const server = cursor.server;
    //     switch (cursor.cursor_mode) {
    //         .passthrough => if (server.viewAt(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |res| {
    //             server.seat.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
    //             server.seat.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
    //         } else if (server.overrideRedirectAt(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |res| {
    //             server.seat.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
    //             server.seat.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
    //         } else {
    //             cursor.wlr_cursor.setXcursor(cursor.cursor_mgr, "default");
    //             server.seat.seat.pointerClearFocus();
    //         },
    //         .move => {
    //             const view = server.seat.grabbed_view.?;
    //             view.box.x = @as(i32, @intFromFloat(cursor.wlr_cursor.x - server.seat.grab_x));
    //             view.box.y = @as(i32, @intFromFloat(cursor.wlr_cursor.y - server.seat.grab_y));
    //             view.scene_tree.node.setPosition(view.box.x, view.box.y);
    //         },
    //         .resize => {
    //             const view = server.seat.grabbed_view.?;
    //             const border_x = @as(i32, @intFromFloat(cursor.wlr_cursor.x - server.seat.grab_x));
    //             const border_y = @as(i32, @intFromFloat(cursor.wlr_cursor.y - server.seat.grab_y));

    //             var new_left = server.seat.grab_box.x;
    //             var new_right = server.seat.grab_box.x + server.seat.grab_box.width;
    //             var new_top = server.seat.grab_box.y;
    //             var new_bottom = server.seat.grab_box.y + server.seat.grab_box.height;

    //             if (server.seat.resize_edges.top) {
    //                 new_top = border_y;
    //                 if (new_top >= new_bottom)
    //                     new_top = new_bottom - 1;
    //             } else if (server.seat.resize_edges.bottom) {
    //                 new_bottom = border_y;
    //                 if (new_bottom <= new_top)
    //                     new_bottom = new_top + 1;
    //             }

    //             if (server.seat.resize_edges.left) {
    //                 new_left = border_x;
    //                 if (new_left >= new_right)
    //                     new_left = new_right - 1;
    //             } else if (server.seat.resize_edges.right) {
    //                 new_right = border_x;
    //                 if (new_right <= new_left)
    //                     new_right = new_left + 1;
    //             }

    //             const new_width = new_right - new_left;
    //             const new_height = new_bottom - new_top;

    //             switch (view.impl) {
    //                 .xwayland_view => |xwayland_view| {
    //                     const xwayland_surface = xwayland_view.surface;
    //                     xwayland_view.view.box.x = new_left - xwayland_surface.x;
    //                     xwayland_view.view.box.y = new_top - xwayland_surface.y;
    //                     xwayland_view.view.scene_tree.node.setPosition(view.box.x, view.box.y);

    //                     _ = xwayland_surface.configure(
    //                         xwayland_surface.x,
    //                         xwayland_surface.y,
    //                         @intCast(new_width),
    //                         @intCast(new_height),
    //                     );
    //                 },
    //                 .toplevel => |toplevel| {
    //                     var geo_box: wlr.Box = undefined;
    //                     _ = toplevel.xdg_toplevel.base.getGeometry(&geo_box);
    //                     toplevel.view.box.x = new_left - geo_box.x;
    //                     toplevel.view.box.y = new_top - geo_box.y;
    //                     toplevel.view.scene_tree.node.setPosition(toplevel.view.box.x, toplevel.view.box.y);
    //                     _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
    //                 },
    //                 .none => {},
    //             }
    //         },
    //     }
    // }

    pub fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_button", listener);

        // cursor.seat.handleActivity();
        // cursor.unhide();

        if (event.state == .released) {
            std.debug.assert(cursor.pressed_count > 0);
            cursor.pressed_count -= 1;
            if (cursor.pressed_count == 0 and cursor.cursor_mode != .passthrough) {
                std.log.debug("leaving {s} mode", .{@tagName(cursor.cursor_mode)});

                switch (cursor.cursor_mode) {
                    .passthrough => unreachable,
                    // .down => {
                    //     // If we were in down mode, we need pass along the release event
                    //     _ = cursor.seat.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                    // },
                    .move => {},
                    .resize => |data| data.view.pending.resizing = false,
                }

                cursor.cursor_mode = .passthrough;
                cursor.passthrough(event.time_msec);

                server.root.transaction.applyPending();
            } else {
                _ = cursor.seat.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            }
            return;
        }

        std.debug.assert(event.state == .pressed);
        cursor.pressed_count += 1;

        if (cursor.pressed_count > 1) {
            _ = cursor.seat.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }

        if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
            cursor.updateKeyboardFocus(result);

            _ = cursor.seat.seat.pointerNotifyButton(event.time_msec, event.button, event.state);

            if (result.surface != null) {
                // cursor.cursor_mode = .{
                //     .down = .{
                //         .lx = cursor.wlr_cursor.x,
                //         .ly = cursor.wlr_cursor.y,
                //         .sx = result.sx,
                //         .sy = result.sy,
                //     },
                // };
            }
        } else {
            cursor.updateOutputFocus(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
        }

        server.root.transaction.applyPending();
    }

    pub fn startMove(cursor: *Cursor, view: *axiom_view.View) void {
        // Guard against assertion in enterMode()
        if (view.current.output == null) return;

        if (view.current.maximized) view.maximize();

        // if (cursor.constraint) |constraint| {
        //     if (constraint.state == .active) constraint.deactivate();
        // }

        const new_mode: CursorMode = .{ .move = .{
            .view = view,
            .offset_x = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - view.current.box.x,
            .offset_y = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - view.current.box.y,
        } };
        cursor.enterMode(new_mode, view, "move");
    }

    pub fn startResize(cursor: *Cursor, view: *axiom_view.View, proposed_edges: ?wlr.Edges) void {
        // Guard against assertions in computeEdges() and enterMode()
        if (view.current.output == null) return;

        // if (cursor.constraint) |constraint| {
        //     if (constraint.state == .active) constraint.deactivate();
        // }

        const edges = blk: {
            if (proposed_edges) |edges| {
                if (edges.top or edges.bottom or edges.left or edges.right) {
                    break :blk edges;
                }
            }
            break :blk cursor.computeEdges(view);
        };

        const box = &view.current.box;
        const lx: i32 = @intFromFloat(cursor.wlr_cursor.x);
        const ly: i32 = @intFromFloat(cursor.wlr_cursor.y);
        const offset_x = if (edges.left) lx - box.x else box.x + box.width - lx;
        const offset_y = if (edges.top) ly - box.y else box.y + box.height - ly;

        view.pending.resizing = true;

        const new_mode: CursorMode = .{ .resize = .{
            .view = view,
            .edges = edges,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .initial_width = @intCast(box.width),
            .initial_height = @intCast(box.height),
        } };
        cursor.enterMode(new_mode, view, wlr.Xcursor.getResizeName(edges));
    }

    fn computeEdges(cursor: *const Cursor, view: *const axiom_view.View) wlr.Edges {
        const min_handle_size = 20;
        const box = &view.current.box;
        //const server = cursor.server;

        var output_box: wlr.Box = undefined;
        server.root.output_layout.getBox(view.current.output.?.wlr_output, &output_box);

        const sx = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - output_box.x - box.x;
        const sy = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - output_box.y - box.y;

        var edges: wlr.Edges = .{};

        if (box.width > min_handle_size * 2) {
            const handle = @max(min_handle_size, @divFloor(box.width, 5));
            if (sx < handle) {
                edges.left = true;
            } else if (sx > box.width - handle) {
                edges.right = true;
            }
        }

        if (box.height > min_handle_size * 2) {
            const handle = @max(min_handle_size, @divFloor(box.height, 5));
            if (sy < handle) {
                edges.top = true;
            } else if (sy > box.height - handle) {
                edges.bottom = true;
            }
        }

        if (!edges.top and !edges.bottom and !edges.left and !edges.right) {
            std.log.err("all edges are false", .{});
            return .{ .bottom = true, .right = true };
        } else {
            return edges;
        }
    }

    fn enterMode(cursor: *Cursor, mode: CursorMode, view: *axiom_view.View, xcursor_name: [*:0]const u8) void {
        //std.debug.assert(cursor.cursor_mode == .passthrough or cursor.cursor_mode == .down);
        std.debug.assert(mode == .move or mode == .resize);

        std.log.debug("enter {s} cursor mode", .{@tagName(mode)});

        cursor.cursor_mode = mode;

        cursor.seat.focus(view);

        // if (view.current.output.?.layout != null) {
        //     view.float_box = view.current.box;
        //     view.pending.float = true;
        // }

        cursor.seat.seat.pointerNotifyClearFocus();
        cursor.setXcursor(xcursor_name);

        server.root.transaction.applyPending();
    }

    fn processMotion(cursor: *Cursor, device: *wlr.InputDevice, time: u32, delta_x: f64, delta_y: f64, unaccel_dx: f64, unaccel_dy: f64) void {
        //const server = cursor.server;

        _ = unaccel_dx;
        _ = unaccel_dy;

        // server.input_manager.relative_pointer_manager.sendRelativeMotion(
        //     cursor.seat.wlr_seat,
        //     @as(u64, time) * 1000,
        //     delta_x,
        //     delta_y,
        //     unaccel_dx,
        //     unaccel_dy,
        // );

        var dx: f64 = delta_x;
        var dy: f64 = delta_y;

        // if (cursor.constraint) |constraint| {
        //     if (constraint.state == .active) {
        //         switch (constraint.wlr_constraint.type) {
        //             .locked => return,
        //             .confined => constraint.confine(&dx, &dy),
        //         }
        //     }
        // }

        //std.log.info("Cursor Mode: {s}", .{@tagName(cursor.cursor_mode)});

        switch (cursor.cursor_mode) {
            // TODO: add down
            .passthrough => {
                cursor.wlr_cursor.move(device, dx, dy);

                switch (cursor.cursor_mode) {
                    .passthrough => {
                        //cursor.checkFocusFollowsCursor();
                        cursor.passthrough(time);
                    },
                    // .down => |data| {
                    //     cursor.seat.seat.pointerNotifyMotion(
                    //         time,
                    //         data.sx + (cursor.wlr_cursor.x - data.lx),
                    //         data.sy + (cursor.wlr_cursor.y - data.ly),
                    //     );
                    // },
                    else => unreachable,
                }

                // cursor.updateDragIcons();

                // if (cursor.constraint) |constraint| {
                //     constraint.maybeActivate();
                // }
            },
            .move => |*data| {
                dx += data.delta_x;
                dy += data.delta_y;
                data.delta_x = dx - @trunc(dx);
                data.delta_y = dy - @trunc(dy);

                data.view.pending.move(@intFromFloat(dx), @intFromFloat(dy));

                server.root.transaction.applyPending();
            },
            .resize => |*data| {
                dx += data.delta_x;
                dy += data.delta_y;
                data.delta_x = dx - @trunc(dx);
                data.delta_y = dy - @trunc(dy);

                data.x += @intFromFloat(dx);
                data.y += @intFromFloat(dy);

                // Modify width/height of the pending box, taking constraints into account
                // The x/y coordinates of the view will be adjusted as needed in View.resizeCommit()
                // based on the dimensions actually committed by the client.
                //const border_width = if (data.view.pending.ssd) server.config.border_width else 0;

                const border_width = 5;
                const output = data.view.current.output orelse {
                    data.view.pending.resizing = false;

                    cursor.cursor_mode = .passthrough;
                    cursor.passthrough(time);

                    server.root.transaction.applyPending();
                    return;
                };

                var output_width: i32 = undefined;
                var output_height: i32 = undefined;
                output.wlr_output.effectiveResolution(&output_width, &output_height);

                const constraints = &data.view.constraints;
                const box = &data.view.pending.box;

                if (data.edges.left) {
                    const x2 = box.x + box.width;
                    box.width = data.initial_width - data.x;
                    box.width = @max(box.width, constraints.min_width);
                    box.width = @min(box.width, constraints.max_width);
                    box.width = @min(box.width, x2 - border_width);
                    data.x = data.initial_width - box.width;
                } else if (data.edges.right) {
                    box.width = data.initial_width + data.x;
                    box.width = @max(box.width, constraints.min_width);
                    box.width = @min(box.width, constraints.max_width);
                    box.width = @min(box.width, output_width - border_width - box.x);
                    data.x = box.width - data.initial_width;
                }

                if (data.edges.top) {
                    const y2 = box.y + box.height;
                    box.height = data.initial_height - data.y;
                    box.height = @max(box.height, constraints.min_height);
                    box.height = @min(box.height, constraints.max_height);
                    box.height = @min(box.height, y2 - border_width);
                    data.y = data.initial_height - box.height;
                } else if (data.edges.bottom) {
                    box.height = data.initial_height + data.y;
                    box.height = @max(box.height, constraints.min_height);
                    box.height = @min(box.height, constraints.max_height);
                    box.height = @min(box.height, output_height - border_width - box.y);
                    data.y = box.height - data.initial_height;
                }

                server.root.transaction.applyPending();
            },
        }
    }
    pub fn checkFocusFollowsCursor(cursor: *Cursor) void {
        // Don't do focus-follows-cursor if a pointer drag is in progress as focus
        // change can't occur.

        //const server = cursor.server;
        //if (cursor.seat.drag == .pointer) return;
        //if (server.config.focus_follows_cursor == .disabled) return;

        // const last_target = cursor.focus_follows_cursor_target;
        cursor.updateFocusFollowsCursorTarget();
        if (cursor.focus_follows_cursor_target) |view| {
            // In .normal mode, only entering a view changes focus
            // if (server.config.focus_follows_cursor == .normal and
            //     last_target == view) return;
            if (cursor.seat.focused != .view or cursor.seat.focused.view != view) {
                if (view.current.output) |output| {
                    cursor.seat.focusOutput(output);
                    cursor.seat.focus(view);
                    server.root.transaction.applyPending();
                }
            }
        } else {
            // The output doesn't contain any views, just focus the output.
            cursor.updateOutputFocus(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
        }
    }

    fn updateFocusFollowsCursorTarget(cursor: *Cursor) void {
        //const server = cursor.server;
        if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
            switch (result.data) {
                .view => |view| {
                    // Some windows have an input region bigger than their window
                    // geometry, we only want to update this when the cursor
                    // properly enters the window (the box that we draw borders around)
                    // in order to avoid clashes with cursor warping on focus change.
                    if (view.current.output) |output| {
                        var output_layout_box: wlr.Box = undefined;
                        server.root.output_layout.getBox(output.wlr_output, &output_layout_box);

                        const cursor_ox = cursor.wlr_cursor.x - @as(f64, @floatFromInt(output_layout_box.x));
                        const cursor_oy = cursor.wlr_cursor.y - @as(f64, @floatFromInt(output_layout_box.y));
                        if (view.current.box.containsPoint(cursor_ox, cursor_oy)) {
                            cursor.focus_follows_cursor_target = view;
                        }
                    }
                },
                // .layer_surface, .lock_surface => {
                //     cursor.focus_follows_cursor_target = null;
                // },
                .override_redirect => {
                    cursor.focus_follows_cursor_target = null;
                },
            }
        } else {
            // The cursor is not above any view
            cursor.focus_follows_cursor_target = null;
        }
    }

    /// Handle potential change in location of views on the output, as well as
    /// the target view of a cursor operation potentially being moved to a non-visible tag,
    /// becoming fullscreen, etc.
    // pub fn updateState(cursor: *Cursor) void {
    //     if (cursor.may_need_warp) {
    //         cursor.warp();
    //     }

    //     if (cursor.constraint) |constraint| {
    //         constraint.updateState();
    //     }

    //     switch (cursor.cursor_mode) {
    //         .passthrough => {
    //             cursor.updateFocusFollowsCursorTarget();
    //             if (!cursor.hidden) {
    //                 var now: posix.timespec = undefined;
    //                 posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
    //                 // 2^32-1 milliseconds is ~50 days, which is a realistic uptime.
    //                 // This means that we must wrap if the monotonic time is greater than
    //                 // 2^32-1 milliseconds and hope that clients don't get too confused.
    //                 const msec: u32 = @intCast(@rem(
    //                     now.tv_sec *% std.time.ms_per_s +% @divTrunc(now.tv_nsec, std.time.ns_per_ms),
    //                     std.math.maxInt(u32),
    //                 ));
    //                 cursor.passthrough(msec);
    //             }
    //         },
    //         // TODO: Leave down mode if the target surface is no longer visible.
    //         .down => std.debug.assert(!cursor.hidden),
    //         .move, .resize => {
    //             // Moving and resizing of views is handled through the transaction system. Therefore,
    //             // we must inspect the inflight_mode instead if a move or a resize is in progress.
    //             //
    //             // The cases when a move/resize is being started or ended and e.g. mode is resize
    //             // while inflight_mode is passthrough or mode is passthrough while inflight_mode
    //             // is resize shouldn't need any special handling.
    //             //
    //             // In the first case, a move/resize has been started along with a transaction but the
    //             // transaction hasn't been committed yet so there is nothing to do.
    //             //
    //             // In the second case, a move/resize has been terminated by the user but the
    //             // transaction carrying out the final size/position change is still inflight.
    //             // Therefore, the user already expects the cursor to be free from the view and
    //             // we should not warp it back to the fixed offset of the move/resize.
    //             switch (cursor.inflight_mode) {
    //                 .passthrough, .down => {},
    //                 inline .move, .resize => |data, mode| {
    //                     std.debug.assert(!cursor.hidden);

    //                     // These conditions are checked in Root.transaction.applyPending()
    //                     const output = data.view.current.output orelse return;
    //                     std.debug.assert(data.view.current.tags & output.current.tags != 0);
    //                     std.debug.assert(data.view.current.float or output.layout == null);
    //                     std.debug.assert(!data.view.current.fullscreen);

    //                     // Keep the cursor locked to the original offset from the edges of the view.
    //                     const box = &data.view.current.box;
    //                     const new_x: f64 = blk: {
    //                         if (mode == .move or data.edges.left) {
    //                             break :blk @floatFromInt(data.offset_x + box.x);
    //                         } else if (data.edges.right) {
    //                             break :blk @floatFromInt(box.x + box.width - data.offset_x);
    //                         } else {
    //                             break :blk cursor.wlr_cursor.x;
    //                         }
    //                     };
    //                     const new_y: f64 = blk: {
    //                         if (mode == .move or data.edges.top) {
    //                             break :blk @floatFromInt(data.offset_y + box.y);
    //                         } else if (data.edges.bottom) {
    //                             break :blk @floatFromInt(box.y + box.height - data.offset_y);
    //                         } else {
    //                             break :blk cursor.wlr_cursor.y;
    //                         }
    //                     };

    //                     cursor.wlr_cursor.warpClosest(null, new_x, new_y);
    //                 },
    //             }
    //         },
    //     }
    // }

    /// Pass an event on to the surface under the cursor, if any.
    fn passthrough(cursor: *Cursor, time: u32) void {
        std.debug.assert(cursor.cursor_mode == .passthrough);
        //const server = cursor.server;
        if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
            // if (result.data == .lock_surface) {
            //     std.debug.assert(server.lock_manager.state != .unlocked);
            // } else {
            //     std.debug.assert(server.lock_manager.state != .locked);
            // }

            if (result.surface) |surface| {
                cursor.seat.seat.pointerNotifyEnter(surface, result.sx, result.sy);
                cursor.seat.seat.pointerNotifyMotion(time, result.sx, result.sy);
                return;
            }
        }

        cursor.clearFocus();
    }

    fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("request_set_cursor", listener);
        const focused_client = cursor.seat.seat.pointer_state.focused_client;

        if (focused_client == event.seat_client) {
            std.log.debug("focused client set cursor", .{});
            cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
            cursor.xcursor_name = null;
        }
    }

    pub fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_axis", listener);

        _ = cursor;
        //const server = cursor.server;
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
        _ = cursor;
        // const server = cursor.server;
        server.seat.seat.pointerNotifyFrame();
    }

    fn updateKeyboardFocus(cursor: Cursor, result: axiom_root.Root.AtResult) void {
        switch (result.data) {
            .view => |view| {
                //std.debug.print("view type: {} \n", .{view.impl.toplevel.wlr_toplevel.base});
                cursor.seat.focus(view);
            },

            //TODO: implement layer surface
            // .layer_surface => |layer_surface| {
            //     cursor.seat.focusOutput(layer_surface.output);
            //     // If a keyboard inteactive layer surface has been clicked on,
            //     // give it keyboard focus.
            //     if (layer_surface.wlr_layer_surface.current.keyboard_interactive != .none) {
            //         cursor.seat.setFocusRaw(.{ .layer = layer_surface });
            //     }
            // },

            //TODO: implement lock surface
            // .lock_surface => |lock_surface| {
            //     std.debug.assert(server.lock_manager.state != .unlocked);
            //     cursor.seat.setFocusRaw(.{ .lock_surface = lock_surface });
            // },
            .override_redirect => |override_redirect| {
                //std.debug.assert(server.lock_manager.state != .locked);
                override_redirect.focusIfDesired();
            },
        }
    }

    /// Focus the output at the given layout coordinates, if any
    /// Requires a call to Root.transaction.applyPending()
    fn updateOutputFocus(cursor: Cursor, lx: f64, ly: f64) void {
        if (server.root.output_layout.outputAt(lx, ly)) |wlr_output| {
            const output: *axiom_output.Output = @ptrFromInt(wlr_output.data);
            cursor.seat.focusOutput(output);
        }
    }

    // fn handlePointerMapping(cursor: *Cursor, event: *wlr.Pointer.event.Button, view: *axiom_view.View) bool {
    //     const wlr_keyboard = cursor.seat.wlr_seat.getKeyboard() orelse return false;
    //     const modifiers = wlr_keyboard.getModifiers();

    //     const fullscreen = view.current.fullscreen or view.pending.fullscreen;

    //     return for (cursor.server.seat.) |mapping| {
    //         if (event.button == mapping.event_code and std.meta.eql(modifiers, mapping.modifiers)) {
    //             switch (mapping.action) {
    //                 .move => if (!fullscreen) cursor.startMove(view),
    //                 .resize => if (!fullscreen) cursor.startResize(view, null),
    //                 .command => |args| {
    //                     cursor.seat.focus(view);
    //                     cursor.seat.runCommand(args);
    //                     // This is mildly inefficient as running the command may have already
    //                     // started a transaction. However we need to start one after the Seat.focus()
    //                     // call in the case where it didn't.
    //                     cursor.server.root.transaction.applyPending();
    //                 },
    //             }
    //             break true;
    //         }
    //     } else false;
    // }
};
