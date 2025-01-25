const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const math = std.math;
//const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_seat = @import("seat.zig");
const AxiomSceneNodeData = @import("scene_node_data.zig").SceneNodeData;
const AxiomData = @import("scene_node_data.zig").Data;

const gpa = @import("utils.zig").gpa;

const server = &@import("main.zig").server;

pub const XwaylandView = struct {
    view: *axiom_view.View,

    xwayland_surface: *wlr.XwaylandSurface,
    /// Created on map and destroyed on unmap
    surface_tree: ?*wlr.SceneTree = null,

    // Active over entire lifetime
    destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
    request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
        wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
    set_override_redirect: wl.Listener(void) = wl.Listener(void).init(handleSetOverrideRedirect),
    associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
    dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),

    // Active while the xwayland_surface is associated with a wlr_surface
    map: wl.Listener(void) = wl.Listener(void).init(handleMap),
    unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),

    // Active while mapped
    set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
    set_class: wl.Listener(void) = wl.Listener(void).init(handleSetClass),
    set_decorations: wl.Listener(void) = wl.Listener(void).init(handleSetDecorations),
    request_move: wl.Listener(void) = wl.Listener(void).init(handleRequestMove),
    request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
    request_minimize: wl.Listener(*wlr.XwaylandSurface.event.Minimize) =
        wl.Listener(*wlr.XwaylandSurface.event.Minimize).init(handleRequestMinimize),
    request_maximize: wl.Listener(void) =
        wl.Listener(void).init(handleRequestMaximize),
    request_resize: wl.Listener(*wlr.XwaylandSurface.event.Resize) =
        wl.Listener(*wlr.XwaylandSurface.event.Resize).init(handleRequestResize),

    pub fn create(xwayland_surface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
        const view = try axiom_view.View.create(.{ .xwayland_view = .{
            .view = undefined,
            .xwayland_surface = xwayland_surface,
        } });
        errdefer view.destroy(.assert);

        const xwayland_view = &view.impl.xwayland_view;
        xwayland_view.view = view;

        // Add listeners that are active over the view's entire lifetime
        xwayland_surface.events.destroy.add(&xwayland_view.destroy);
        xwayland_surface.events.associate.add(&xwayland_view.associate);
        xwayland_surface.events.dissociate.add(&xwayland_view.dissociate);
        xwayland_surface.events.request_configure.add(&xwayland_view.request_configure);
        xwayland_surface.events.set_override_redirect.add(&xwayland_view.set_override_redirect);

        if (xwayland_surface.surface) |surface| {
            handleAssociate(&xwayland_view.associate);
            if (surface.mapped) {
                handleMap(&xwayland_view.map);
            }
        }
    }

    /// Always returns false as we do not care about frame perfection for Xwayland views.
    pub fn configure(xwayland_view: XwaylandView) bool {
        const output = xwayland_view.view.inflight.output orelse return false;

        var output_box: wlr.Box = undefined;
        server.root.output_layout.getBox(output.wlr_output, &output_box);

        const inflight = &xwayland_view.view.inflight;
        const current = &xwayland_view.view.current;

        if (xwayland_view.xwayland_surface.x == inflight.box.x + output_box.x and
            xwayland_view.xwayland_surface.y == inflight.box.y + output_box.y and
            xwayland_view.xwayland_surface.width == inflight.box.width and
            xwayland_view.xwayland_surface.height == inflight.box.height and
            (inflight.focus != 0) == (current.focus != 0) and
            (output.inflight.fullscreen == xwayland_view.view) ==
            (current.output != null and current.output.?.current.fullscreen == xwayland_view.view))
        {
            return false;
        }

        xwayland_view.xwayland_surface.configure(
            math.lossyCast(i16, inflight.box.x + output_box.x),
            math.lossyCast(i16, inflight.box.y + output_box.y),
            math.lossyCast(u16, inflight.box.width),
            math.lossyCast(u16, inflight.box.height),
        );

        xwayland_view.setActivated(inflight.focus != 0);

        xwayland_view.xwayland_surface.setFullscreen(output.inflight.fullscreen == xwayland_view.view);

        return false;
    }

    fn setActivated(xwayland_view: XwaylandView, activated: bool) void {
        // See comment on handleRequestMinimize() for details
        if (activated and xwayland_view.xwayland_surface.minimized) {
            xwayland_view.xwayland_surface.setMinimized(false);
        }
        xwayland_view.xwayland_surface.activate(activated);
        if (activated) {
            xwayland_view.xwayland_surface.restack(null, .above);
        }
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("destroy", listener);

        // Remove listeners that are active for the entire lifetime of the view
        xwayland_view.destroy.link.remove();
        xwayland_view.associate.link.remove();
        xwayland_view.dissociate.link.remove();
        xwayland_view.request_configure.link.remove();
        //xwayland_view.set_override_redirect.link.remove();

        const view = xwayland_view.view;
        view.impl = .none;
        view.destroy(.lazy);
    }

    fn handleAssociate(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("associate", listener);

        xwayland_view.xwayland_surface.surface.?.events.map.add(&xwayland_view.map);
        xwayland_view.xwayland_surface.surface.?.events.unmap.add(&xwayland_view.unmap);
    }

    fn handleDissociate(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("dissociate", listener);
        xwayland_view.map.link.remove();
        xwayland_view.unmap.link.remove();
    }

    pub fn handleMap(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("map", listener);
        const view = xwayland_view.view;

        const xwayland_surface = xwayland_view.xwayland_surface;
        const surface = xwayland_surface.surface.?;
        surface.data = @intFromPtr(&view.tree.node);

        // Add listeners that are only active while mapped
        xwayland_surface.events.set_title.add(&xwayland_view.set_title);
        xwayland_surface.events.set_class.add(&xwayland_view.set_class);
        xwayland_surface.events.set_decorations.add(&xwayland_view.set_decorations);
        xwayland_surface.events.request_fullscreen.add(&xwayland_view.request_fullscreen);
        xwayland_surface.events.request_minimize.add(&xwayland_view.request_minimize);
        xwayland_surface.events.request_maximize.add(&xwayland_view.request_maximize);
        xwayland_surface.events.request_move.add(&xwayland_view.request_move);
        xwayland_surface.events.request_resize.add(&xwayland_view.request_resize);

        xwayland_view.surface_tree = view.surface_tree.createSceneSubsurfaceTree(surface) catch {
            std.log.err("out of memory", .{});
            surface.resource.getClient().postNoMemory();
            return;
        };

        view.pending.box = .{
            .x = 0,
            .y = 0,
            .width = xwayland_view.xwayland_surface.width,
            .height = xwayland_view.xwayland_surface.height,
        };
        view.inflight.box = view.pending.box;
        view.current.box = view.pending.box;

        // A value of -1 seems to indicate being unset for these size hints.
        const has_fixed_size = if (xwayland_view.xwayland_surface.size_hints) |size_hints|
            size_hints.min_width > 0 and size_hints.min_height > 0 and
                (size_hints.min_width == size_hints.max_width or size_hints.min_height == size_hints.max_height)
        else
            false;

        if (xwayland_view.xwayland_surface.parent != null or has_fixed_size) {
            // If the toplevel has a parent or has a fixed size make it float by default.
            // This will be overwritten in View.map() if the view is matched by a rule.
            view.pending.float = true;
        }

        // This will be overwritten in View.map() if the view is matched by a rule.
        //view.pending.ssd = !xwayland_surface.decorations.no_border;

        view.pending.fullscreen = xwayland_surface.fullscreen;

        view.map() catch {
            std.log.err("out of memory", .{});
            surface.resource.getClient().postNoMemory();
        };
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("unmap", listener);

        xwayland_view.xwayland_surface.surface.?.data = 0;

        // Remove listeners that are only active while mapped
        xwayland_view.set_title.link.remove();
        xwayland_view.set_class.link.remove();
        xwayland_view.request_fullscreen.link.remove();
        xwayland_view.request_minimize.link.remove();
        xwayland_view.request_move.link.remove();
        xwayland_view.request_resize.link.remove();

        xwayland_view.view.unmap();

        // Don't destroy the surface tree until after View.unmap() has a chance
        // to save buffers for frame perfection.
        xwayland_view.surface_tree.?.node.destroy();
        xwayland_view.surface_tree = null;
    }

    fn handleRequestConfigure(
        listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
        event: *wlr.XwaylandSurface.event.Configure,
    ) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_configure", listener);

        // If unmapped, let the client do whatever it wants
        if (xwayland_view.xwayland_surface.surface == null or
            !xwayland_view.xwayland_surface.surface.?.mapped)
        {
            xwayland_view.xwayland_surface.configure(event.x, event.y, event.width, event.height);
            return;
        }

        // Allow xwayland views to set their own dimensions (but not position) if floating
        if (xwayland_view.view.pending.float) {
            xwayland_view.view.pending.box.width = event.width;
            xwayland_view.view.pending.box.height = event.height;
        }
        server.root.transaction.applyPending();
    }

    fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("set_override_redirect", listener);
        const xwayland_surface = xwayland_view.xwayland_surface;

        std.log.debug("xwayland surface set override redirect", .{});

        std.debug.assert(xwayland_surface.override_redirect);

        if (xwayland_surface.surface) |surface| {
            if (surface.mapped) {
                handleUnmap(&xwayland_view.unmap);
            }
            handleDissociate(&xwayland_view.dissociate);
        }
        handleDestroy(&xwayland_view.destroy);

        XwaylandOverrideRedirect.create(xwayland_surface) catch {
            std.log.err("out of memory", .{});
            return;
        };
    }

    fn handleSetTitle(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("set_title", listener);
        xwayland_view.view.notifyTitle();
    }

    fn handleSetClass(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("set_class", listener);
        xwayland_view.view.notifyAppId();
    }

    fn handleSetDecorations(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("set_decorations", listener);
        const view = xwayland_view.view;
        _ = view;
        server.root.transaction.applyPending();
    }

    fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_fullscreen", listener);
        if (xwayland_view.view.pending.fullscreen != xwayland_view.xwayland_surface.fullscreen) {
            xwayland_view.view.pending.fullscreen = xwayland_view.xwayland_surface.fullscreen;
            server.root.transaction.applyPending();
        }
    }

    /// Some X11 clients will minimize themselves regardless of how we respond.
    /// Therefore to ensure they don't get stuck in this minimized state we tell
    /// them their request has been honored without actually doing anything and
    /// unminimize them if they gain focus while minimized.
    fn handleRequestMinimize(
        listener: *wl.Listener(*wlr.XwaylandSurface.event.Minimize),
        event: *wlr.XwaylandSurface.event.Minimize,
    ) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_minimize", listener);
        xwayland_view.xwayland_surface.setMinimized(event.minimize);
    }

    fn handleRequestMaximize(listener: *wl.Listener(void)) void {
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_maximize", listener);
        xwayland_view.view.maximize();
        xwayland_view.xwayland_surface.setMaximized(true);
        server.root.transaction.applyPending();
    }

    fn handleRequestMove(listener: *wl.Listener(void)) void {
        std.log.info("starting move", .{});
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_move", listener);
        const seat: *axiom_seat.Seat = @ptrFromInt(server.xwayland.seat.?.data);
        const view = xwayland_view.view;

        view.move(seat);
    }

    fn handleRequestResize(
        listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize),
        _: *wlr.XwaylandSurface.event.Resize,
    ) void {
        std.log.info("resize requested", .{});
        const xwayland_view: *XwaylandView = @fieldParentPtr("request_resize", listener);
        const view = xwayland_view.view;

        view.resize(null);
    }
};

pub const XwaylandOverrideRedirect = struct {
    xwayland_surface: *wlr.XwaylandSurface,
    surface_tree: ?*wlr.SceneTree = null,

    // Active over entire lifetime
    request_configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) =
        wl.Listener(*wlr.XwaylandSurface.event.Configure).init(handleRequestConfigure),
    destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
    set_override_redirect: wl.Listener(void) = wl.Listener(void).init(handleSetOverrideRedirect),
    associate: wl.Listener(void) = wl.Listener(void).init(handleAssociate),
    dissociate: wl.Listener(void) = wl.Listener(void).init(handleDissociate),

    // Active while the xwayland_surface is associated with a wlr_surface
    map: wl.Listener(void) = wl.Listener(void).init(handleMap),
    unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),

    // Active while mapped
    set_geometry: wl.Listener(void) = wl.Listener(void).init(handleSetGeometry),

    pub fn create(xwayland_surface: *wlr.XwaylandSurface) error{OutOfMemory}!void {
        const override_redirect = try gpa.create(XwaylandOverrideRedirect);
        errdefer gpa.destroy(override_redirect);

        override_redirect.* = .{ .xwayland_surface = xwayland_surface };

        xwayland_surface.events.request_configure.add(&override_redirect.request_configure);
        xwayland_surface.events.destroy.add(&override_redirect.destroy);
        xwayland_surface.events.set_override_redirect.add(&override_redirect.set_override_redirect);

        xwayland_surface.events.associate.add(&override_redirect.associate);
        xwayland_surface.events.dissociate.add(&override_redirect.dissociate);

        if (xwayland_surface.surface) |surface| {
            handleAssociate(&override_redirect.associate);
            if (surface.mapped) {
                handleMap(&override_redirect.map);
            }
        }
    }

    fn handleRequestConfigure(
        _: *wl.Listener(*wlr.XwaylandSurface.event.Configure),
        event: *wlr.XwaylandSurface.event.Configure,
    ) void {
        event.surface.configure(event.x, event.y, event.width, event.height);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("destroy", listener);

        override_redirect.request_configure.link.remove();
        override_redirect.destroy.link.remove();
        override_redirect.associate.link.remove();
        override_redirect.dissociate.link.remove();
        override_redirect.set_override_redirect.link.remove();

        gpa.destroy(override_redirect);
    }

    fn handleAssociate(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("associate", listener);

        override_redirect.xwayland_surface.surface.?.events.map.add(&override_redirect.map);
        override_redirect.xwayland_surface.surface.?.events.unmap.add(&override_redirect.unmap);
    }

    fn handleDissociate(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("dissociate", listener);

        override_redirect.map.link.remove();
        override_redirect.unmap.link.remove();
    }

    pub fn handleMap(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("map", listener);

        override_redirect.mapImpl() catch {
            std.log.err("out of memory", .{});
            override_redirect.xwayland_surface.surface.?.resource.getClient().postNoMemory();
        };
    }

    fn mapImpl(override_redirect: *XwaylandOverrideRedirect) error{OutOfMemory}!void {
        const surface = override_redirect.xwayland_surface.surface.?;
        override_redirect.surface_tree =
            try server.root.interactive_layers.override_redirect.createSceneSubsurfaceTree(surface);
        try AxiomSceneNodeData.attach(&override_redirect.surface_tree.?.node, .{
            .override_redirect = override_redirect,
        });

        surface.data = @intFromPtr(&override_redirect.surface_tree.?.node);

        override_redirect.surface_tree.?.node.setPosition(
            override_redirect.xwayland_surface.x,
            override_redirect.xwayland_surface.y,
        );

        override_redirect.xwayland_surface.events.set_geometry.add(&override_redirect.set_geometry);

        override_redirect.focusIfDesired();
    }

    pub fn focusIfDesired(override_redirect: *XwaylandOverrideRedirect) void {
        //if (server.lock_manager.state != .unlocked) return;

        if (override_redirect.xwayland_surface.overrideRedirectWantsFocus() and
            override_redirect.xwayland_surface.icccmInputModel() != .none)
        {
            const seat = server.seat;
            // Keep the parent top-level Xwayland view of any override redirect surface
            // activated while that override redirect surface is focused. This ensures
            // override redirect menus do not disappear as a result of deactivating
            // their parent window.
            if (seat.focused == .view and
                seat.focused.view.impl == .xwayland_view and
                seat.focused.view.impl.xwayland_view.xwayland_surface.pid == override_redirect.xwayland_surface.pid)
            {
                seat.keyboardEnterOrLeave(override_redirect.xwayland_surface.surface);
            } else {
                seat.setFocusRaw(.{ .override_redirect = override_redirect });
            }
        }
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("unmap", listener);

        override_redirect.set_geometry.link.remove();

        override_redirect.xwayland_surface.surface.?.data = 0;
        override_redirect.surface_tree.?.node.destroy();
        override_redirect.surface_tree = null;

        // If the unmapped surface is currently focused, pass keyboard focus
        // to the most appropriate surface.
        const seat = server.seat;
        if (seat.focused == .view and seat.focused.view.impl == .xwayland_view and
            seat.focused.view.impl.xwayland_view.xwayland_surface.pid == override_redirect.xwayland_surface.pid and
            seat.seat.keyboard_state.focused_surface == override_redirect.xwayland_surface.surface)
        {
            seat.keyboardEnterOrLeave(seat.focused.view.rootSurface());
        }

        server.root.transaction.applyPending();
    }

    fn handleSetGeometry(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_geometry", listener);

        override_redirect.surface_tree.?.node.setPosition(
            override_redirect.xwayland_surface.x,
            override_redirect.xwayland_surface.y,
        );
    }

    fn handleSetOverrideRedirect(listener: *wl.Listener(void)) void {
        const override_redirect: *XwaylandOverrideRedirect = @fieldParentPtr("set_override_redirect", listener);
        const xwayland_surface = override_redirect.xwayland_surface;

        std.log.debug("xwayland surface unset override redirect", .{});

        std.debug.assert(!xwayland_surface.override_redirect);

        if (xwayland_surface.surface) |surface| {
            if (surface.mapped) {
                handleUnmap(&override_redirect.unmap);
            }
            handleDissociate(&override_redirect.dissociate);
        }
        handleDestroy(&override_redirect.destroy);

        XwaylandView.create(xwayland_surface) catch {
            std.log.err("out of memory", .{});
            return;
        };
    }
};
