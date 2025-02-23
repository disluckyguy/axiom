const std = @import("std");
const posix = std.posix;

const c = @import("c.zig");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const Server = @import("server.zig").Server;
const View = @import("view.zig").View;
const Seat = @import("seat.zig").Seat;
const Root = @import("root.zig").Root;
const Output = @import("output.zig").Output;
const PointerConstraint = @import("pointer_constraint.zig").PointerConstraint;

const gpa = @import("utils.zig").gpa;
const server = &@import("main.zig").server;

// States of the cursor
// Passthrough is the default simply means passing without a move or resize

pub const CursorMode = union(enum) {
    passthrough: void,
    move: struct {
        view: *View,

        delta_x: f64 = 0,
        delta_y: f64 = 0,

        offset_x: i32,

        offset_y: i32,
    },
    resize: struct {
        view: *View,

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
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = wl.Listener(*wlr.Pointer.event.Motion).init(handleCursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(handleCursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = wl.Listener(*wlr.Pointer.event.Button).init(handleCursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(handleCursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(handleCursorFrame),

    // Current cursor mde
    current_mode: CursorMode = .passthrough,

    // Set to the current cursor mode when a transaction starts
    // This is needed to stop move and resize operations, since they don't
    // terminate until a transaction completes and View.resizeUpdatePosition() is called
    inflight_mode: CursorMode = .passthrough,

    default_size: u32 = 24,

    seat: *Seat,

    // XcursorManager for current Xcursor theme
    xcursor_manager: *wlr.XcursorManager,

    // Xcursor shape name
    // Null when a client makes a surface as the cursor
    xcursor_name: ?[*:0]const u8 = null,

    // Number of different buttons currently pressed
    pressed_count: u32 = 0,

    // Hashmap of all the current touchpoint in layout coordinates
    touch_points: std.AutoHashMapUnmanaged(i32, LayoutPoint) = .{},

    constraint: ?*PointerConstraint = null,

    pub fn init(cursor: *Cursor, seat: *Seat) !void {
        const wlr_cursor = try wlr.Cursor.create();
        errdefer wlr_cursor.destroy();

        wlr_cursor.attachOutputLayout(server.root.output_layout);

        const xcursor_manager = try wlr.XcursorManager.create(null, cursor.default_size);

        try xcursor_manager.load(1);
        errdefer xcursor_manager.destroy();

        cursor.* = .{
            .seat = seat,
            .wlr_cursor = wlr_cursor,
            .xcursor_manager = xcursor_manager,
        };
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
        seat.wlr_seat.events.request_set_cursor.add(&cursor.request_set_cursor);
    }

    pub fn deinit(cursor: *Cursor) void {
        cursor.xcursor_manager.destroy();
        cursor.wlr_cursor.destroy();
    }

    pub fn setTheme(cursor: *Cursor, theme: ?[*:0]const u8, _size: ?u32) !void {
        const size = _size orelse cursor.default_size;

        const xcursor_manager = try wlr.XcursorManager.create(theme, size);
        errdefer xcursor_manager.destroy();

        // If this cursor belongs to the default seat, set the xcursor environment
        // variables as well as the xwayland cursor theme.
        if (cursor.seat == server.input_manager.defaultSeat()) {
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
        }

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

    fn handleClearFocus(cursor: *Cursor) void {
        cursor.setXcursor("default");
        cursor.seat.wlr_seat.pointerNotifyClearFocus();
    }

    pub fn handleRequestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("request_set_cursor", listener);
        const seat = cursor.seat;
        if (event.seat_client == seat.wlr_seat.pointer_state.focused_client)
            seat.cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    pub fn handleCursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion", listener);
        cursor.seat.notifyActivity();
        cursor.processMotion(
            event.device,
            event.time_msec,
            event.delta_x,
            event.delta_y,
            event.unaccel_dx,
            event.unaccel_dy,
        );
    }

    fn handleCursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_motion_absolute", listener);

        cursor.seat.notifyActivity();

        // layout x and y coordinates
        var lx: f64 = undefined;
        var ly: f64 = undefined;

        cursor.wlr_cursor.absoluteToLayoutCoords(event.device, event.x, event.y, &lx, &ly);

        cursor.wlr_cursor.warpAbsolute(event.device, event.x, event.y);

        const dx = lx - cursor.wlr_cursor.x;
        const dy = ly - cursor.wlr_cursor.y;

        cursor.processMotion(event.device, event.time_msec, dx, dy, dx, dy);
    }

    pub fn handleCursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_button", listener);

        cursor.seat.notifyActivity();

        if (event.state == .released) {
            std.debug.assert(cursor.pressed_count > 0);
            cursor.pressed_count -= 1;
            if (cursor.pressed_count == 0 and cursor.current_mode != .passthrough) {
                std.log.debug("leaving {s} mode", .{@tagName(cursor.current_mode)});

                switch (cursor.current_mode) {
                    .passthrough => unreachable,
                    // .down => {
                    //     // If we were in down mode, we need pass along the release event
                    //     _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
                    // },
                    .move => {},
                    .resize => |data| data.view.pending.resizing = false,
                }

                cursor.current_mode = .passthrough;
                cursor.passthrough(event.time_msec);

                server.root.transaction.applyPending();
            } else {
                _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            }
            return;
        }

        std.debug.assert(event.state == .pressed);
        cursor.pressed_count += 1;

        if (cursor.pressed_count > 1) {
            _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }

        if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
            cursor.updateKeyboardFocus(result);

            _ = cursor.seat.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        } else {
            cursor.updateOutputFocus(cursor.wlr_cursor.x, cursor.wlr_cursor.y);
        }

        server.root.transaction.applyPending();
    }

    pub fn startMove(cursor: *Cursor, view: *View) void {
        // Guard against assertion in enterMode()
        if (view.current.output == null) return;

        if (view.current.maximized) view.maximize();

        const new_mode: CursorMode = .{ .move = .{
            .view = view,
            .offset_x = @as(i32, @intFromFloat(cursor.wlr_cursor.x)) - view.current.box.x,
            .offset_y = @as(i32, @intFromFloat(cursor.wlr_cursor.y)) - view.current.box.y,
        } };
        cursor.enterMode(new_mode, view, "move");
    }

    pub fn startResize(cursor: *Cursor, view: *View, proposed_edges: ?wlr.Edges) void {
        // Guard against assertions in computeEdges() and enterMode()
        if (view.current.output == null) return;

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

    fn computeEdges(cursor: *const Cursor, view: *const View) wlr.Edges {
        const min_handle_size = 20;
        const box = &view.current.box;

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

    fn enterMode(cursor: *Cursor, mode: CursorMode, view: *View, xcursor_name: [*:0]const u8) void {
        std.debug.assert(cursor.current_mode == .passthrough);
        std.debug.assert(mode == .move or mode == .resize);

        std.log.debug("enter {s} cursor mode", .{@tagName(mode)});

        cursor.current_mode = mode;

        cursor.seat.focus(view);

        cursor.seat.wlr_seat.pointerNotifyClearFocus();
        cursor.setXcursor(xcursor_name);

        server.root.transaction.applyPending();
    }

    fn processMotion(cursor: *Cursor, device: *wlr.InputDevice, time: u32, delta_x: f64, delta_y: f64, unaccel_dx: f64, unaccel_dy: f64) void {
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

        if (cursor.constraint) |constraint| {
            if (constraint.state == .active) {
                switch (constraint.wlr_constraint.type) {
                    .locked => return,
                    .confined => constraint.confine(&dx, &dy),
                }
            }
        }

        switch (cursor.current_mode) {
            // TODO: add down
            .passthrough => {
                cursor.wlr_cursor.move(device, dx, dy);

                switch (cursor.current_mode) {
                    .passthrough => {
                        cursor.passthrough(time);
                    },
                    else => unreachable,
                }
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
                const output: *Output = data.view.current.output orelse {
                    data.view.pending.resizing = false;

                    cursor.current_mode = .passthrough;
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

    /// Pass an event on to the surface under the cursor, if any.
    fn passthrough(cursor: *Cursor, time: u32) void {
        std.debug.assert(cursor.current_mode == .passthrough);
        if (server.root.at(cursor.wlr_cursor.x, cursor.wlr_cursor.y)) |result| {
            if (result.surface) |surface| {
                cursor.seat.wlr_seat.pointerNotifyEnter(surface, result.sx, result.sy);
                cursor.seat.wlr_seat.pointerNotifyMotion(time, result.sx, result.sy);
                return;
            }
        }

        cursor.handleClearFocus();
    }

    pub fn handleCursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_axis", listener);

        cursor.seat.wlr_seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    pub fn handleCursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const cursor: *Cursor = @fieldParentPtr("cursor_frame", listener);
        cursor.seat.wlr_seat.pointerNotifyFrame();
    }

    fn updateKeyboardFocus(cursor: Cursor, result: Root.AtResult) void {
        switch (result.data) {
            .view => |view| {
                cursor.seat.focus(view);
            },
            .override_redirect => |override_redirect| {
                override_redirect.focusIfDesired();
            },
        }
    }

    /// Focus the output at the given layout coordinates, if any
    /// Requires a call to Root.transaction.applyPending()
    fn updateOutputFocus(cursor: Cursor, lx: f64, ly: f64) void {
        if (server.root.output_layout.outputAt(lx, ly)) |wlr_output| {
            const output: *Output = @ptrFromInt(wlr_output.data);
            cursor.seat.focusOutput(output);
        }
    }
};
