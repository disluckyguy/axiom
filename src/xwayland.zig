const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");

const gpa = @import("utils.zig").gpa;

pub const XwaylandView = struct {
    surface: *wlr.XwaylandSurface,
    surface_tree: ?*wlr.SceneTree = null,
    view: *axiom_view.View,

    associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
    dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),
    map: wl.Listener(void) = wl.Listener(void).init(map),
    unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
    request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = wl.Listener(*wlr.XwaylandSurface.event.Configure).init(requestConfigure),
    request_move: wl.Listener(void) = wl.Listener(void).init(requestMove),
    request_resize: wl.Listener(*wlr.XwaylandSurface.event.Resize) = wl.Listener(*wlr.XwaylandSurface.event.Resize).init(requestResize),

    pub fn setActivated(xwayland_view: *XwaylandView, activated: bool) void {
        xwayland_view.surface.activate(activated);
        if (activated) {
            xwayland_view.surface.restack(null, .above);
        }
    }

    pub fn handleAssociate(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("associate", listener);

        xwayland_view.surface.surface.?.events.map.add(&xwayland_view.map);
        xwayland_view.surface.surface.?.events.unmap.add(&xwayland_view.unmap);
    }

    pub fn handleDissociate(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("dissociate", listener);
        xwayland_view.map.link.remove();
        xwayland_view.unmap.link.remove();
    }

    pub fn map(listener: *wl.Listener(void)) void {
        std.log.info("Mapped Xwayland surface", .{});
        const xwayland_view: *XwaylandView = @fieldParentPtr("map", listener);
        const view = xwayland_view.view;

        const xwayland_surface = xwayland_view.surface;
        const surface = xwayland_surface.surface.?;

        if (xwayland_surface.override_redirect) {} else {}

        xwayland_view.surface_tree = view.surface_tree.createSceneSubsurfaceTree(xwayland_surface.surface.?) catch {
            std.log.err("out of memory", .{});
            surface.resource.getClient().postNoMemory();
            return;
        };

        surface.data = @intFromPtr(&view.surface_tree.node);
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("unmap", listener);

        xwayland_view.surface.surface.?.data = 0;

        xwayland_view.surface_tree.?.node.destroy();
        xwayland_view.surface_tree = null;
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const xwaylandView: *XwaylandView = @fieldParentPtr("destroy", listener);

        xwaylandView.destroy.link.remove();
        xwaylandView.request_configure.link.remove();

        xwaylandView.view.destroy();
    }

    pub fn requestConfigure(
        listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
        event: *wlr.XwaylandSurface.event.Configure,
    ) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_configure", listener);

        if (xwayland_view.surface.surface == null or
            !xwayland_view.surface.surface.?.mapped)
        {
            event.surface.configure(event.x, event.y, event.width, event.height);
            return;
        }
    }

    pub fn requestMove(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_move", listener);
        const seat = xwayland_view.view.server.seat;
        seat.grabbed_view = xwayland_view.view;
        seat.cursor.cursor_mode = .move;

        seat.grab_x = seat.cursor.cursor.x - @as(f64, @floatFromInt(xwayland_view.view.box.x));
        seat.grab_y = seat.cursor.cursor.y - @as(f64, @floatFromInt(xwayland_view.view.box.y));
    }

    pub fn requestResize(
        listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize),
        event: *wlr.XwaylandSurface.event.Resize,
    ) void {
        std.log.info("resize_requested", .{});
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_resize", listener);
        const seat = xwayland_view.view.server.seat;

        seat.grabbed_view = xwayland_view.view;
        seat.cursor.cursor_mode = .resize;
        std.log.info("{}", .{event.edges});

        const edges: wlr.Edges = switch (event.edges) {
            1 => .{
                .top = true,
                .bottom = false,
                .left = false,
                .right = false,
            },
            2 => .{
                .top = false,
                .bottom = true,
                .left = false,
                .right = false,
            },
            4 => .{
                .top = false,
                .bottom = false,
                .left = true,
                .right = false,
            },
            8 => .{
                .top = false,
                .bottom = false,
                .left = false,
                .right = true,
            },
            5 => .{
                .top = true,
                .bottom = false,
                .left = true,
                .right = false,
            },
            10 => .{
                .top = false,
                .bottom = true,
                .left = false,
                .right = true,
            },
            6 => .{
                .top = false,
                .bottom = true,
                .left = true,
                .right = false,
            },
            9 => .{
                .top = true,
                .bottom = false,
                .left = false,
                .right = true,
            },
            else => unreachable,
        };

        seat.resize_edges = edges;

        const box: wlr.Box = .{
            .x = xwayland_view.surface.x,
            .y = xwayland_view.surface.y,
            .width = xwayland_view.surface.width,
            .height = xwayland_view.surface.height,
        };

        std.log.info("{}", .{xwayland_view.view.box.x});
        std.log.info("", .{});

        const border_x = xwayland_view.view.box.x + box.x + if (edges.right) box.width else 0;
        const border_y = xwayland_view.view.box.y + box.y + if (edges.bottom) box.height else 0;
        seat.grab_x = seat.cursor.cursor.x - @as(f64, @floatFromInt(border_x));
        seat.grab_y = seat.cursor.cursor.y - @as(f64, @floatFromInt(border_y));

        seat.grab_box = box;
        seat.grab_box.x += xwayland_view.view.box.x;
        seat.grab_box.y += xwayland_view.view.box.y;
    }
};

pub const XwaylandOverrideRedirect = struct {
    server: *axiom_server.Server,
    surface: *wlr.XwaylandSurface,
    surface_tree: ?*wlr.SceneTree = null,

    associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
    dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),
    map: wl.Listener(void) = wl.Listener(void).init(map),
    unmap: wl.Listener(void) = wl.Listener(void).init(unmap),
    destroy: wl.Listener(void) = wl.Listener(void).init(destroy),
    request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = wl.Listener(*wlr.XwaylandSurface.event.Configure).init(requestConfigure),
    set_geometry: wl.Listener(void) = wl.Listener(void).init(setGeometry),

    pub fn new(xwayland_surface: *wlr.XwaylandSurface, server: *axiom_server.Server) !void {
        const override_redirect = try gpa.create(XwaylandOverrideRedirect);

        errdefer gpa.destroy(override_redirect);

        override_redirect.* = .{
            .surface = xwayland_surface,
            .server = server,
        };

        xwayland_surface.events.destroy.add(&override_redirect.destroy);
        xwayland_surface.events.request_configure.add(&override_redirect.request_configure);
        xwayland_surface.events.associate.add(&override_redirect.associate);
        xwayland_surface.events.dissociate.add(&override_redirect.dissociate);

        if (xwayland_surface.surface) |surface| {
            surface.events.map.add(&override_redirect.map);
            surface.events.unmap.add(&override_redirect.unmap);

            override_redirect.surface_tree = try server.override_redirect_tree.createSceneSubsurfaceTree(surface);
            surface.data = @intFromPtr(&override_redirect.surface_tree.?.node);
        }
    }

    pub fn handleAssociate(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("associate", listener);

        override_redirect.surface.surface.?.events.map.add(&override_redirect.map);
        override_redirect.surface.surface.?.events.unmap.add(&override_redirect.unmap);
    }

    pub fn handleDissociate(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("dissociate", listener);
        override_redirect.map.link.remove();
        override_redirect.unmap.link.remove();
    }

    pub fn map(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("map", listener);

        const xwayland_surface = override_redirect.surface;
        const surface = xwayland_surface.surface.?;

        override_redirect.surface_tree = override_redirect.server.override_redirect_tree.createSceneSubsurfaceTree(surface) catch {
            std.log.err("out of memory", .{});
            surface.resource.getClient().postNoMemory();
            return;
        };
        surface.data = @intFromPtr(&override_redirect.surface_tree.?.node);

        override_redirect.surface_tree.?.node.raiseToTop();

        override_redirect.surface_tree.?.node.data = @intFromPtr(override_redirect);

        xwayland_surface.events.set_geometry.add(&override_redirect.set_geometry);

        override_redirect.surface_tree.?.node.setPosition(
            xwayland_surface.x,
            xwayland_surface.y,
        );

        override_redirect.server.seat.focusOverrideRedirect(override_redirect);
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

        override_redirect.surface.surface.?.data = 0;

        override_redirect.surface_tree.?.node.destroy();
        override_redirect.surface_tree = null;

        override_redirect.set_geometry.link.remove();
    }

    fn setGeometry(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_geometry", listener);

        std.log.info("setting geometry", .{});
        override_redirect.surface_tree.?.node.setPosition(
            override_redirect.surface.x,
            override_redirect.surface.y,
        );
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const override_rediect: *XwaylandOverrideRedirect = @fieldParentPtr("destroy", listener);

        override_rediect.destroy.link.remove();
        override_rediect.request_configure.link.remove();

        gpa.destroy(override_rediect);
    }

    pub fn requestConfigure(
        _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
        event: *wlr.XwaylandSurface.event.Configure,
    ) void {
        event.surface.configure(event.x, event.y, event.width, event.height);
    }
};
