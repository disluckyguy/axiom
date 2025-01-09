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
const axiom_seat = @import("seat.zig");
const gpa = @import("utils.zig").gpa;

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,
    compositor: *wlr.Compositor,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(newOutput),

    seat: *axiom_seat.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(newInput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = wl.Listener(*wlr.XdgToplevel).init(newXdgToplevel),
    views: wl.list.Head(axiom_view.View, .link) = undefined,

    xwayland: *wlr.Xwayland,
    xwayland_ready: wl.Listener(void) = wl.Listener(void).init(xwaylandReady),
    new_xwayland_surface: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(newXwaylandSurface),
    override_redirect_tree: *wlr.SceneTree,

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
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .compositor = undefined,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .seat = undefined,
            .xwayland = undefined,
            .override_redirect_tree = try scene.tree.createSceneTree(),
        };

        server.seat = try axiom_seat.Seat.create(server);

        try server.renderer.initServer(wl_server);

        server.compositor = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);
        server.xwayland = try wlr.Xwayland.create(wl_server, server.compositor, false);
        server.xwayland.setSeat(server.seat.seat);
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

    pub fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => axiom_keyboard.Keyboard.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => server.seat.cursor.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.seat.keyboards.length() > 0,
        });
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
        const xcursor: *wlr.Xcursor = server.seat.cursor.cursor_mgr.getXcursor("default", 1.0) orelse {
            std.log.err("couldn't get Xcursor", .{});
            return;
        };

        xwayland.setSeat(server.seat.seat);
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
            xwayland_surface.events.request_move.add(&xwayland_view.request_move);
            xwayland_surface.events.request_resize.add(&xwayland_view.request_resize);

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
};
