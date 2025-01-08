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

    pub fn new(xwayland_surface: *wlr.XwaylandSurface, server: *axiom_server.Server) !void {
        const xwayland_override_redirect = try gpa.create(XwaylandOverrideRedirect);

        errdefer gpa.destroy(xwayland_override_redirect);

        xwayland_override_redirect.* = .{
            .surface = xwayland_surface,
            .server = server,
        };

        xwayland_surface.events.destroy.add(&xwayland_override_redirect.destroy);
        xwayland_surface.events.request_configure.add(&xwayland_override_redirect.request_configure);
        xwayland_surface.events.associate.add(&xwayland_override_redirect.associate);
        xwayland_surface.events.dissociate.add(&xwayland_override_redirect.dissociate);

        if (xwayland_surface.surface) |surface| {
            surface.events.map.add(&xwayland_override_redirect.map);
            surface.events.unmap.add(&xwayland_override_redirect.unmap);

            xwayland_override_redirect.surface_tree = try server.override_redirect_tree.createSceneSubsurfaceTree(surface);
            surface.data = @intFromPtr(&xwayland_override_redirect.surface_tree.?.node);
        }
    }

    pub fn handleAssociate(listener: *wl.Listener(void)) void {
        const xwaylandOverrideRedirect: *XwaylandOverrideRedirect = @fieldParentPtr("associate", listener);

        xwaylandOverrideRedirect.surface.surface.?.events.map.add(&xwaylandOverrideRedirect.map);
        xwaylandOverrideRedirect.surface.surface.?.events.unmap.add(&xwaylandOverrideRedirect.unmap);
    }

    pub fn handleDissociate(listener: *wl.Listener(void)) void {
        const xwaylandOverrideRedirect: *XwaylandOverrideRedirect = @fieldParentPtr("dissociate", listener);
        xwaylandOverrideRedirect.map.link.remove();
        xwaylandOverrideRedirect.unmap.link.remove();
    }

    pub fn map(listener: *wl.Listener(void)) void {
        std.log.info("Mapped Xwayland surface", .{});
        const xwaylandOverrideRedirect: *XwaylandOverrideRedirect = @fieldParentPtr("map", listener);

        const xwayland_surface = xwaylandOverrideRedirect.surface;
        const surface = xwayland_surface.surface.?;

        xwaylandOverrideRedirect.surface_tree = xwaylandOverrideRedirect.server.override_redirect_tree.createSceneSubsurfaceTree(surface) catch {
            std.log.err("out of memory", .{});
            surface.resource.getClient().postNoMemory();
            return;
        };
        surface.data = @intFromPtr(&xwaylandOverrideRedirect.surface_tree.?.node);

        xwaylandOverrideRedirect.surface_tree.?.node.raiseToTop();

        xwaylandOverrideRedirect.surface_tree.?.node.setPosition(
            xwayland_surface.x,
            xwayland_surface.y,
        );

        xwaylandOverrideRedirect.surface_tree.?.node.data = @intFromPtr(xwaylandOverrideRedirect);

        xwaylandOverrideRedirect.server.seat.focusOverrideRedirect(xwaylandOverrideRedirect);
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const xwaylandOverrideRedirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

        xwaylandOverrideRedirect.surface.surface.?.data = 0;

        xwaylandOverrideRedirect.surface_tree.?.node.destroy();
        xwaylandOverrideRedirect.surface_tree = null;
    }

    fn destroy(listener: *wl.Listener(void)) void {
        const xwaylandOverrideRedirect: *XwaylandOverrideRedirect = @fieldParentPtr("destroy", listener);

        xwaylandOverrideRedirect.destroy.link.remove();
        xwaylandOverrideRedirect.request_configure.link.remove();

        gpa.destroy(xwaylandOverrideRedirect);
    }

    pub fn requestConfigure(
        _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
        event: *wlr.XwaylandSurface.event.Configure,
    ) void {
        event.surface.configure(event.x, event.y, event.width, event.height);
    }
};
