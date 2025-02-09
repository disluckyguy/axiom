const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_xwayland = @import("xwayland.zig");
const axiom_keyboard = @import("keyboard.zig");
const axiom_cursor = @import("cursor.zig");
const axiom_output = @import("output.zig");
const axiom_input_relay = @import("input_relay.zig");
const axiom_input_device = @import("input_device.zig");

const server = &@import("main.zig").server;

const gpa = @import("utils.zig").gpa;

pub const FocusTarget = union(enum) {
    view: *axiom_view.View,
    override_redirect: *axiom_xwayland.XwaylandOverrideRedirect,
    // layer: *LayerSurface,
    // lock_surface: *LockSurface,
    none: void,

    pub fn surface(target: FocusTarget) ?*wlr.Surface {
        return switch (target) {
            .view => |view| view.rootSurface(),
            .override_redirect => |override_redirect| override_redirect.xwayland_surface.surface,
            // .layer => |layer| layer.wlr_layer_surface.surface,
            // .lock_surface => |lock_surface| lock_surface.wlr_lock_surface.surface,
            .none => null,
        };
    }
};

pub const Seat = struct {
    seat: *wlr.Seat,
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = wl.Listener(*wlr.Seat.event.RequestSetSelection).init(requestSetSelection),
    keyboards: wl.list.Head(axiom_keyboard.Keyboard, .link) = undefined,
    cursor: axiom_cursor.Cursor,
    relay: axiom_input_relay.InputRelay,
    focused: FocusTarget = .none,
    focused_output: ?*axiom_output.Output = null,

    grabbed_view: ?*axiom_view.View = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},

    pub fn init(seat: *Seat, name: [*:0]const u8) !void {
        errdefer gpa.destroy(seat);

        const wlr_seat = try wlr.Seat.create(server.wl_server, name);

        errdefer wlr_seat.destroy();

        seat.* = .{
            // This will be automatically destroyed when the display is destroyed
            .seat = wlr_seat,
            .cursor = undefined,
            .relay = undefined,
            //.mapping_repeat_timer = mapping_repeat_timer,
        };

        seat.relay.init();
        try seat.cursor.init(seat);
        seat.seat.data = @intFromPtr(seat);
        seat.keyboards.init();
    }

    pub fn deinit(seat: *Seat) void {
        _ = seat;
        // {
        //     var it = server.input_manager.devices.iterator(.forward);
        //     while (it.next()) |device| assert(device.seat != seat);
        // }

        // seat.cursor.deinit();
        // seat.mapping_repeat_timer.remove();

        // while (seat.keyboard_groups.first) |node| {
        //     node.data.destroy();
        // }

        // seat.request_set_selection.link.remove();
        // seat.request_start_drag.link.remove();
        // seat.start_drag.link.remove();
        // if (seat.drag != .none) seat.drag_destroy.link.remove();
        // seat.request_set_primary_selection.link.remove();
    }

    pub fn updateCapabilities(seat: *Seat) void {
        // Currently a cursor is always drawn even if there are no pointer input devices.
        // TODO Don't draw a cursor if there are no input devices.
        var capabilities: wl.Seat.Capability = .{ .pointer = true };

        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.seat == seat) {
                switch (device.wlr_device.type) {
                    .keyboard => capabilities.keyboard = true,
                    .touch => capabilities.touch = true,
                    .pointer, .@"switch", .tablet => {},
                    .tablet_pad => unreachable,
                }
            }
        }

        seat.seat.setCapabilities(capabilities);
    }

    pub fn addDevice(seat: *Seat, wlr_device: *wlr.InputDevice) void {
        seat.tryAddDevice(wlr_device) catch |err| switch (err) {
            error.OutOfMemory => std.log.err("out of memory", .{}),
            //TODO: finish
            else => {},
        };
    }

    fn tryAddDevice(seat: *Seat, wlr_device: *wlr.InputDevice) !void {
        switch (wlr_device.type) {
            .keyboard => {
                const keyboard = try gpa.create(axiom_keyboard.Keyboard);
                errdefer gpa.destroy(keyboard);

                try keyboard.init(seat, wlr_device);

                seat.seat.setKeyboard(keyboard.device.wlr_device.toKeyboard());
                if (seat.seat.keyboard_state.focused_surface) |wlr_surface| {
                    seat.keyboardNotifyEnter(wlr_surface);
                }
            },
            .pointer, .touch => {
                const device = try gpa.create(axiom_input_device.InputDevice);
                errdefer gpa.destroy(device);

                try device.init(seat, wlr_device);

                seat.cursor.wlr_cursor.attachInputDevice(wlr_device);
            },
            // .tablet => {
            //     try Tablet.create(seat, wlr_device);
            //     seat.cursor.wlr_cursor.attachInputDevice(wlr_device);
            // },
            // .@"switch" => {
            //     const switch_device = try util.gpa.create(Switch);
            //     errdefer util.gpa.destroy(switch_device);

            //     try switch_device.init(seat, wlr_device);
            // },

            // TODO Support these types of input devices.
            //.tablet_pad => {},
            else => {},
        }
    }

    pub fn focus(seat: *Seat, _target: ?*axiom_view.View) void {
        var target = _target;

        // Don't change focus if there are no outputs.
        if (seat.focused_output == null) return;

        // Views may not receive focus while locked.
        //if (server.lock_manager.state != .unlocked) return;

        // A layer surface with exclusive focus will prevent any view from gaining
        // focus if it is on the top or overlay layer. Otherwise, only steal focus
        // from a focused layer surface if there is an explicit target view.
        // if (seat.focused == .layer) {
        //     const wlr_layer_surface = seat.focused.layer.wlr_layer_surface;
        //     std.debug.assert(wlr_layer_surface.surface.mapped);
        //     switch (wlr_layer_surface.current.keyboard_interactive) {
        //         .none => {},
        //         .exclusive => switch (wlr_layer_surface.current.layer) {
        //             .top, .overlay => return,
        //             .bottom, .background => if (target == null) return,
        //             _ => {},
        //         },
        //         .on_demand => if (target == null) return,
        //         _ => {},
        //     }
        // }

        if (target) |view| {
            if (view.pending.output == null or
                view.pending.tags & view.pending.output.?.pending.tags == 0)
            {
                // If the view is not currently visible, behave as if null was passed
                target = null;
            } else if (view.pending.output.? != seat.focused_output.?) {
                // If the view is not on the currently focused output, focus it
                seat.focusOutput(view.pending.output.?);
            }
        }

        {
            var it = seat.focused_output.?.pending.focus_stack.iterator(.forward);
            while (it.next()) |view| {
                if (view.pending.fullscreen and
                    view.pending.tags & seat.focused_output.?.pending.tags != 0)
                {
                    target = view;
                    break;
                }
            }
        }

        // If null, set the target to the first currently visible view in the focus stack if any
        if (target == null) {
            var it = seat.focused_output.?.pending.focus_stack.iterator(.forward);
            target = while (it.next()) |view| {
                if (view.pending.tags & seat.focused_output.?.pending.tags != 0) {
                    break view;
                }
            } else null;
        }

        // Focus the target view or clear the focus if target is null
        if (target) |view| {
            view.pending_focus_stack_link.remove();
            seat.focused_output.?.pending.focus_stack.prepend(view);
            seat.setFocusRaw(.{ .view = view });
        } else {
            seat.setFocusRaw(.{ .none = {} });
        }
    }

    pub fn focusOutput(seat: *Seat, output: ?*axiom_output.Output) void {
        if (seat.focused_output == output) return;

        // if (seat.focused_output) |old| {
        //     var it = seat.status_trackers.first;
        //     while (it) |node| : (it = node.next) node.data.sendOutput(old, .unfocused);
        // }

        seat.focused_output = output;

        // if (seat.focused_output) |new| {
        //     var it = seat.status_trackers.first;
        //     while (it) |node| : (it = node.next) node.data.sendOutput(new, .focused);
        // }

        // Depending on configuration and cursor position, changing output focus
        // may cause the cursor to be warped.
        //seat.cursor.may_need_warp = true;
    }

    pub fn setFocusRaw(seat: *Seat, new_focus: FocusTarget) void {
        // If the target is already focused, do nothing
        if (std.meta.eql(new_focus, seat.focused)) return;

        const target_surface = new_focus.surface();

        // First clear the current focus
        switch (seat.focused) {
            .view => |view| {
                if (view.pending.focus > 0) {
                    view.pending.focus -= 1;
                }

                view.destroyPopups();
            },
            // .layer => |layer_surface| {
            //     layer_surface.destroyPopups();
            // },
            .override_redirect, .none => {},
        }

        // Set the new focus
        switch (new_focus) {
            .view => |target_view| {
                //assert(server.lock_manager.state != .locked);
                std.debug.assert(seat.focused_output == target_view.pending.output);
                target_view.pending.focus += 1;
                target_view.pending.urgent = false;
            },
            // .layer => |target_layer| {
            //     std.debug.assert(server.lock_manager.state != .locked);
            //     std.debug.assert(seat.focused_output == target_layer.output);
            // },
            //.lock_surface => std.debug.assert(server.lock_manager.state != .unlocked),
            .override_redirect, .none => {},
        }
        seat.focused = new_focus;

        // if (seat.cursor.constraint) |constraint| {
        //     if (constraint.wlr_constraint.surface != target_surface) {
        //         if (constraint.state == .active) {
        //             std.log.info("deactivating pointer constraint for surface, keyboard focus lost", .{});
        //             constraint.deactivate();
        //         }
        //         seat.cursor.constraint = null;
        //     }
        // }

        seat.keyboardEnterOrLeave(target_surface);
        seat.relay.focus(target_surface);

        // if (target_surface) |surface| {
        //     const pointer_constraints = server.input_manager.pointer_constraints;
        //     if (pointer_constraints.constraintForSurface(surface, seat.wlr_seat)) |wlr_constraint| {
        //         if (seat.cursor.constraint) |constraint| {
        //             std.debug.assert(constraint.wlr_constraint == wlr_constraint);
        //         } else {
        //             seat.cursor.constraint = @ptrFromInt(wlr_constraint.data);
        //             std.debug.assert(seat.cursor.constraint != null);
        //         }
        //     }
        // }

        // // Depending on configuration and cursor position, changing keyboard focus
        // // may cause the cursor to be warped.
        // seat.cursor.may_need_warp = true;

        // // Inform any clients tracking status of the change
        // var it = seat.status_trackers.first;
        // while (it) |node| : (it = node.next) node.data.sendFocusedView();
    }

    pub fn keyboardEnterOrLeave(seat: *Seat, target_surface: ?*wlr.Surface) void {
        if (target_surface) |wlr_surface| {
            seat.keyboardNotifyEnter(wlr_surface);
        } else {
            seat.seat.keyboardNotifyClearFocus();
        }
    }

    fn keyboardNotifyEnter(seat: *Seat, wlr_surface: *wlr.Surface) void {
        if (seat.seat.getKeyboard()) |wlr_keyboard| {
            //const keyboard: *axiom_keyboard.Keyboard = @ptrFromInt(wlr_keyboard.data);

            seat.seat.keyboardNotifyEnter(
                wlr_surface,
                wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
                &wlr_keyboard.modifiers,
            );
        } else {
            seat.seat.keyboardNotifyEnter(wlr_surface, &.{}, null);
        }
    }

    pub fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const seat: *Seat = @fieldParentPtr("request_set_selection", listener);
        seat.seat.setSelection(event.source, event.serial);
    }

    /// Assumes the modifier used for compositor keybinds is pressed
    /// Returns true if the key was handled
    pub fn handleKeybind(seat: *Seat, key: xkb.Keysym) bool {
        _ = seat;

        switch (@intFromEnum(key)) {
            // Exit the compositor
            xkb.Keysym.Escape => {
                server.wl_server.terminate();
            },

            xkb.Keysym.F2 => {
                var env_map = std.process.getEnvMap(gpa) catch return false;
                defer env_map.deinit();
                var process = std.process.Child.init(
                    &[_][]const u8{"konsole"},
                    gpa,
                );

                process.env_map = &env_map;

                process.spawn() catch return false;

                return true;
            },

            else => return false,
        }
        return true;
    }
};
