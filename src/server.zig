const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const c = @import("c.zig");
const pixman = @import("pixman");

const wlr = @import("wlroots");

const axiom_toplevel = @import("toplevel.zig");
const axiom_xwayland = @import("xwayland.zig");
const axiom_keyboard = @import("keyboard.zig");
const axiom_output = @import("output.zig");
const axiom_popup = @import("popup.zig");
const axiom_view = @import("view.zig");
const gpa = @import("utils.zig").gpa;

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,
    compositor: *wlr.Compositor,
    //socket: []const u8,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(newOutput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = wl.Listener(*wlr.XdgToplevel).init(newXdgToplevel),
    views: wl.list.Head(axiom_view.View, .link) = undefined,

    xwayland: *wlr.Xwayland,
    xwayland_ready: wl.Listener(void) = wl.Listener(void).init(xwaylandReady),
    new_xwayland_surface: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(newXwaylandSurface),
    override_redirect_tree: *wlr.SceneTree,

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = wl.Listener(*wlr.Seat.event.RequestSetCursor).init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = wl.Listener(*wlr.Seat.event.RequestSetSelection).init(requestSetSelection),
    keyboards: wl.list.Head(axiom_keyboard.Keyboard, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = wl.Listener(*wlr.Pointer.event.Motion).init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = wl.Listener(*wlr.Pointer.event.MotionAbsolute).init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = wl.Listener(*wlr.Pointer.event.Button).init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = wl.Listener(*wlr.Pointer.event.Axis).init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = wl.Listener(*wlr.Cursor).init(cursorFrame),

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*axiom_view.View = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},

    pub fn start(server: Server) !void {
        var buf: [11]u8 = undefined;
        const socket = try server.wl_server.addSocketAuto(&buf);
        try server.backend.start();

        //server.socket = socket;
        if (c.setenv("WAYLAND_DISPLAY", socket.ptr, 1) < 0) return error.SetenvError;
        if (c.setenv("DISPLAY", server.xwayland.display_name, 1) < 0) return error.SetenvError;
    }

    pub fn init(server: *Server) !void {
        const wl_server = try wl.Server.create();
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();

        server.* = .{
            //.socket = undefined,
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .compositor = undefined,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .seat = try wlr.Seat.create(wl_server, "default"),
            .xwayland = undefined,
            .override_redirect_tree = try scene.tree.createSceneTree(),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        };

        try server.renderer.initServer(wl_server);

        server.compositor = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);
        server.xwayland = try wlr.Xwayland.create(wl_server, server.compositor, false);
        server.xwayland.setSeat(server.seat);
        server.xwayland.events.ready.add(&server.xwayland_ready);
        server.backend.events.new_output.add(&server.new_output);

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.views.init();

        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();

        server.xwayland.events.ready.add(&server.xwayland_ready);
        server.xwayland.events.new_surface.add(&server.new_xwayland_surface);
        server.override_redirect_tree.node.setEnabled(true);
        server.override_redirect_tree.node.raiseToTop();

        try env_map.put("DISPLAY", std.mem.span(server.xwayland.display_name));

        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.keyboards.init();

        server.cursor.attachOutputLayout(server.output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);
    }

    pub fn deinit(server: *Server) void {
        server.wl_server.destroyClients();
        server.xwayland.destroy();
        server.wl_server.destroy();
    }

    pub fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        axiom_output.Output.create(server, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    pub fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        std.log.info("new toplevel created", .{});

        const view = axiom_view.View.create(
            .{ .toplevel = .{
                .view = undefined,
                .xdg_toplevel = xdg_toplevel,
            } },
            server,
        ) catch {
            std.log.err("out of memory", .{});
            xdg_toplevel.resource.postNoMemory();
            return;
        };
        errdefer view.destroy();

        const toplevel = &view.impl.toplevel;

        xdg_surface.surface.events.map.add(&toplevel.map);
        errdefer toplevel.unmap.link.remove();

        _ = view.surface_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("out of memory", .{});
            xdg_toplevel.resource.postNoMemory();
            return;
        };
        toplevel.view = view;

        xdg_surface.data = @intFromPtr(toplevel);
        xdg_surface.surface.data = @intFromPtr(&toplevel.view.scene_tree.node);

        xdg_surface.surface.events.commit.add(&toplevel.commit);

        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
        xdg_toplevel.base.events.new_popup.add(&toplevel.new_popup);
    }

    pub fn xwaylandReady(listener: *wl.Listener(void)) void {
        const server: *Server = @fieldParentPtr("xwayland_ready", listener);
        const xwayland = server.xwayland;
        const xcursor: *wlr.Xcursor = server.cursor_mgr.getXcursor("default", 1.0) orelse {
            std.log.err("couldn't get Xcursor", .{});
            return;
        };

        xwayland.setSeat(server.seat);
        xwayland.setCursor(
            xcursor.images[0].buffer,
            xcursor.images[0].width * 4,
            xcursor.images[0].width,
            xcursor.images[0].height,
            @intCast(xcursor.images[0].hotspot_x),
            @intCast(xcursor.images[0].hotspot_y),
        );
    }

    pub fn newXwaylandSurface(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
        const server: *Server = @fieldParentPtr("new_xwayland_surface", listener);

        if (xwayland_surface.override_redirect) {
            _ = axiom_xwayland.XwaylandOverrideRedirect.new(xwayland_surface, server) catch {
                std.log.debug("out of memory", .{});
                xwayland_surface.close();
                return;
            };
        } else {
            const view = axiom_view.View.create(
                .{ .xwayland_surface = .{
                    .view = undefined,
                    .surface = xwayland_surface,
                } },
                server,
            ) catch {
                std.log.err("out of memory", .{});
                xwayland_surface.close();
                return;
            };
            errdefer view.destroy();

            const xwayland_view = &view.impl.xwayland_surface;
            xwayland_view.view = view;

            xwayland_surface.events.destroy.add(&xwayland_view.destroy);
            xwayland_surface.events.request_configure.add(&xwayland_view.request_configure);
            xwayland_surface.events.associate.add(&xwayland_view.associate);
            xwayland_surface.events.dissociate.add(&xwayland_view.dissociate);

            if (xwayland_surface.surface) |surface| {
                xwayland_view.surface.surface.?.events.map.add(&xwayland_view.map);
                xwayland_view.surface.surface.?.events.unmap.add(&xwayland_view.unmap);
                if (surface.mapped) {
                    surface.data = @intFromPtr(&view.scene_tree.node);

                    xwayland_view.surface_tree = view.surface_tree.createSceneSubsurfaceTree(xwayland_surface.surface.?) catch {
                        std.log.err("out of memory", .{});
                        surface.resource.getClient().postNoMemory();
                        return;
                    };
                }
            }
        }

        std.log.debug(
            "new xwayland surface: title='{?s}', class='{?s}', override redirect={}",
            .{ xwayland_surface.title, xwayland_surface.class, xwayland_surface.override_redirect },
        );
    }

    const ViewAtResult = struct {
        view: *axiom_view.View,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    const OverrideRedirectAtResult = struct {
        override_redirect: *axiom_xwayland.XwaylandOverrideRedirect,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    pub fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*axiom_view.View, @ptrFromInt(n.node.data))) |view| {
                    return ViewAtResult{
                        .view = view,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    pub fn overrideRedirectAt(server: *Server, lx: f64, ly: f64) ?OverrideRedirectAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;

            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*axiom_xwayland.XwaylandOverrideRedirect, @ptrFromInt(n.node.data))) |override_redirect| {
                    std.log.info("found override redirect", .{});
                    return OverrideRedirectAtResult{
                        .sx = sx,
                        .sy = sy,
                        .override_redirect = override_redirect,
                        .surface = scene_surface.surface,
                    };
                }
            }
        }
        return null;
    }

    pub fn focusView(server: *Server, view: *axiom_view.View, surface: *wlr.Surface) void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);
            } else if (wlr.XwaylandSurface.tryFromWlrSurface(previous_surface)) |xwayland_surface| {
                _ = xwayland_surface.activate(false);
            }
        }

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

        const wlr_keyboard = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    pub fn focusOverrideRedirect(server: *Server, override_redirect: *axiom_xwayland.XwaylandOverrideRedirect) void {
        std.log.info("focusing", .{});

        const surface = override_redirect.surface.surface orelse return;

        const surface_tree = override_redirect.surface_tree orelse return;
        surface_tree.node.raiseToTop();

        std.log.info("surface present", .{});

        server.override_redirect_tree.node.raiseToTop();

        const wlr_keyboard = server.seat.getKeyboard() orelse return;

        std.log.info("keyboard present", .{});
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    pub fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => axiom_keyboard.Keyboard.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => server.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    pub fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    pub fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    pub fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    pub fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    pub fn processCursorMotion(server: *Server, time_msec: u32) void {
        switch (server.cursor_mode) {
            .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else if (server.overrideRedirectAt(server.cursor.x, server.cursor.y)) |res| {
                server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else {
                server.cursor.setXcursor(server.cursor_mgr, "default");
                server.seat.pointerClearFocus();
            },
            .move => {
                const view = server.grabbed_view.?;
                view.box.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                view.box.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));
                view.scene_tree.node.setPosition(view.box.x, view.box.y);
            },
            .resize => {
                const view = server.grabbed_view.?;
                const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;

                if (server.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom)
                        new_top = new_bottom - 1;
                } else if (server.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top)
                        new_bottom = new_top + 1;
                }

                if (server.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right)
                        new_left = new_right - 1;
                } else if (server.resize_edges.right) {
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
        const server: *Server = @fieldParentPtr("cursor_button", listener);
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        if (event.state == .released) {
            server.cursor_mode = .passthrough;
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.view, res.surface);
        } else if (server.overrideRedirectAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusOverrideRedirect(res.override_redirect);
        }
    }

    pub fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_axis", listener);
        server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    pub fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame", listener);
        server.seat.pointerNotifyFrame();
    }

    /// Assumes the modifier used for compositor keybinds is pressed
    /// Returns true if the key was handled
    pub fn handleKeybind(server: *Server, key: xkb.Keysym) bool {
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
                    server.focusView(view, surface);
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
