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
const axiom_root = @import("root.zig");
const axiom_view = @import("view.zig");
const axiom_seat = @import("seat.zig");
const axiom_input_manager = @import("input_manager.zig");
const IpcSocket = @import("ipc/server.zig").IpcSocket;
const gpa = @import("utils.zig").gpa;

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    compositor: *wlr.Compositor,

    root: *axiom_root.Root,
    shm: *wlr.Shm,
    drm: ?*wlr.Drm = null,
    linux_dmabuf: ?*wlr.LinuxDmabufV1 = null,
    single_pixel_buffer_manager: *wlr.SinglePixelBufferManagerV1,

    input_manager: *axiom_input_manager.InputManager,

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = wl.Listener(*wlr.XdgToplevel).init(newXdgToplevel),
    views: std.ArrayList(*axiom_view.View),

    xwayland: *wlr.Xwayland,
    xwayland_ready: wl.Listener(void) = wl.Listener(void).init(xwaylandReady),
    new_xwayland_surface: wl.Listener(*wlr.XwaylandSurface) = wl.Listener(*wlr.XwaylandSurface).init(newXwaylandSurface),

    ipc_server: *IpcSocket,

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
        const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

        const root = try gpa.create(axiom_root.Root);
        errdefer gpa.destroy(root);

        const input_manager = try gpa.create(axiom_input_manager.InputManager);
        errdefer gpa.destroy(input_manager);

        const ipc_server = try gpa.create(IpcSocket);
        errdefer gpa.destroy(ipc_server);

        server.* = .{
            .wl_server = wl_server,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .compositor = compositor,
            .shm = try wlr.Shm.createWithRenderer(wl_server, 1, renderer),
            .single_pixel_buffer_manager = try wlr.SinglePixelBufferManagerV1.create(wl_server),
            .root = root,
            .input_manager = input_manager,
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .xwayland = undefined,
            .ipc_server = ipc_server,
            .views = std.ArrayList(*axiom_view.View).init(gpa),
        };

        try server.root.init();

        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);

        if (renderer.getTextureFormats(@intFromEnum(wlr.BufferCap.dmabuf)) != null) {
            // wl_drm is a legacy interface and all clients should switch to linux_dmabuf.
            // However, enough widely used clients still rely on wl_drm that the pragmatic option
            // is to keep it around for the near future.
            // TODO remove wl_drm support
            //server.drm = try wlr.Drm.create(wl_server, renderer);

            server.linux_dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(wl_server, 4, renderer);
        }

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);

        server.xwayland = try wlr.Xwayland.create(wl_server, compositor, true);
        server.xwayland.events.ready.add(&server.xwayland_ready);
        try server.input_manager.init();
        server.xwayland.events.new_surface.add(&server.new_xwayland_surface);

        try server.ipc_server.init();
    }

    pub fn deinit(server: *Server) void {
        server.wl_server.destroyClients();
        server.xwayland.destroy();
        server.wl_server.destroy();
        server.input_manager.deinit();
        server.ipc_server.deinit();
    }

    pub fn newXdgToplevel(_: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        axiom_toplevel.Toplevel.create(xdg_toplevel) catch {
            std.log.err("out of memory", .{});
            return;
        };
    }

    pub fn xwaylandReady(listener: *wl.Listener(void)) void {
        std.log.info("Xwayland is ready", .{});
        const server: *Server = @fieldParentPtr("xwayland_ready", listener);
        const xwayland = server.xwayland;
        const xcursor: *wlr.Xcursor = server.input_manager.defaultSeat().cursor.xcursor_manager.getXcursor("default", 1.0) orelse {
            std.log.err("couldn't get Xcursor", .{});
            return;
        };

        xwayland.setCursor(
            xcursor.images[0].buffer,
            xcursor.images[0].width * 4,
            xcursor.images[0].width,
            xcursor.images[0].height,
            @intCast(xcursor.images[0].hotspot_x),
            @intCast(xcursor.images[0].hotspot_y),
        );
    }

    pub fn newXwaylandSurface(_: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
        //const server: *Server = @fieldParentPtr("new_xwayland_surface", listener);

        if (xwayland_surface.override_redirect) {
            _ = axiom_xwayland.XwaylandOverrideRedirect.create(xwayland_surface) catch {
                std.log.debug("out of memory", .{});
                xwayland_surface.close();
                return;
            };
        } else {
            const view = axiom_view.View.create(
                .{ .xwayland_view = .{
                    .view = undefined,
                    .xwayland_surface = xwayland_surface,
                } },
            ) catch {
                std.log.err("out of memory", .{});
                xwayland_surface.close();
                return;
            };
            errdefer view.destroy();

            const xwayland_view = &view.impl.xwayland_view;
            xwayland_view.view = view;

            xwayland_surface.events.destroy.add(&xwayland_view.destroy);
            xwayland_surface.events.request_configure.add(&xwayland_view.request_configure);
            xwayland_surface.events.associate.add(&xwayland_view.associate);
            xwayland_surface.events.dissociate.add(&xwayland_view.dissociate);
            //xwayland_surface.events.request_move.add(&xwayland_view.request_move);
            //xwayland_surface.events.request_resize.add(&xwayland_view.request_resize);

            if (xwayland_surface.surface) |surface| {
                xwayland_view.xwayland_surface.surface.?.events.map.add(&xwayland_view.map);
                xwayland_view.xwayland_surface.surface.?.events.unmap.add(&xwayland_view.unmap);
                if (surface.mapped) {
                    surface.data = @intFromPtr(&view.tree.node);

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
};
