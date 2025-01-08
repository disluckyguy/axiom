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

const gpa = @import("utils.zig").gpa;

pub const Seat = struct {
    server: *axiom_server.Server,
    seat: *wlr.Seat,
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = wl.Listener(*wlr.Seat.event.RequestSetCursor).init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = wl.Listener(*wlr.Seat.event.RequestSetSelection).init(requestSetSelection),
    keyboards: wl.list.Head(axiom_keyboard.Keyboard, .link) = undefined,
    cursor: *axiom_cursor.Cursor,

    grabbed_view: ?*axiom_view.View = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},

    pub fn create(server: *axiom_server.Server) !*Seat {
        const seat = try gpa.create(Seat);
        errdefer gpa.destroy(seat);

        const wlr_seat = try wlr.Seat.create(server.wl_server, "default");

        errdefer wlr_seat.destroy();

        seat.* = .{
            .server = server,
            .seat = wlr_seat,
            .cursor = try axiom_cursor.Cursor.create(server),
        };

        seat.seat.events.request_set_cursor.add(&seat.request_set_cursor);
        seat.seat.events.request_set_selection.add(&seat.request_set_selection);
        seat.keyboards.init();

        return seat;
    }

    pub fn destroy(seat: *Seat) void {
        seat.request_set_cursor.link.remove();
        seat.request_set_selection.link.remove();
        seat.cursor.destroy();

        gpa.destroy(seat);
    }

    pub fn focusView(seat: *Seat, view: *axiom_view.View, surface: *wlr.Surface) void {
        if (seat.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            } else if (wlr.XwaylandSurface.tryFromWlrSurface(previous_surface)) |xwayland_surface| {
                _ = xwayland_surface.activate(false);
            }
        }

        const server = seat.server;

        view.scene_tree.node.raiseToTop();
        view.link.remove();
        server.views.prepend(view);

        switch (view.impl) {
            .xwayland_surface => |xwayland_view| {
                xwayland_view.surface.activate(true);
            },
            .toplevel => |toplevel| {
                _ = toplevel.xdg_toplevel.setActivated(true);
            },
            .none => {},
        }

        const wlr_keyboard = server.seat.seat.getKeyboard() orelse return;
        server.seat.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    pub fn focusOverrideRedirect(seat: *Seat, override_redirect: *axiom_xwayland.XwaylandOverrideRedirect) void {
        std.log.info("focusing", .{});

        const server = seat.server;
        const surface = override_redirect.surface.surface orelse return;

        const surface_tree = override_redirect.surface_tree orelse return;
        surface_tree.node.raiseToTop();

        std.log.info("surface present", .{});

        server.override_redirect_tree.node.raiseToTop();

        const wlr_keyboard = server.seat.seat.getKeyboard() orelse return;

        std.log.info("keyboard present", .{});
        server.seat.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    pub fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const seat: *Seat = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == seat.seat.pointer_state.focused_client)
            seat.cursor.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
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
        const server = seat.server;
        switch (@intFromEnum(key)) {
            // Exit the compositor
            xkb.Keysym.Escape => {
                server.wl_server.terminate();
            },
            // Focus the next toplevel in the stack, pushing the current top to the back
            xkb.Keysym.F1 => {
                if (server.views.length() < 2) return true;
                if (server.views.link.prev) |prev| {
                    const view: *axiom_view.View = @fieldParentPtr("link", prev);
                    const surface = view.rootSurface() orelse return false;
                    std.log.info("focusing surface", .{});
                    seat.focusView(view, surface);
                }
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
