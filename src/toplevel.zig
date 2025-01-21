const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const math = std.math;
//const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_popup = @import("popup.zig");
const axiom_seat = @import("seat.zig");

const server = &@import("main.zig").server;

const gpa = @import("utils.zig").gpa;

pub const Toplevel = struct {
    view: *axiom_view.View,

    wlr_toplevel: *wlr.XdgToplevel,

    //decoration: ?XdgDecoration = null,

    /// Initialized on map
    geometry: wlr.Box = undefined,

    configure_state: union(enum) {
        /// No configure has been sent since the last configure was acked.
        idle,
        /// A configure was sent with the given serial but has not yet been acked.
        inflight: u32,
        /// A configure was acked but the surface has not yet been committed.
        acked,
        /// A configure was acked and the surface was committed.
        committed,
        /// A configure was sent but not acked before the transaction timed out.
        timed_out: u32,
        /// A configure was sent and acked but not committed before the transaction timed out.
        timed_out_acked,
    } = .idle,

    // Listeners that are always active over the view's lifetime
    destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
    map: wl.Listener(void) = wl.Listener(void).init(handleMap),
    unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
    new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),

    // Listeners that are only active while the view is mapped
    ack_configure: wl.Listener(*wlr.XdgSurface.Configure) =
        wl.Listener(*wlr.XdgSurface.Configure).init(handleAckConfigure),
    request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
        wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
        wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
    request_maximize: wl.Listener(void) = wl.Listener(void).init(handleRequestMaximize),
    set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
    set_app_id: wl.Listener(void) = wl.Listener(void).init(handleSetAppId),

    pub fn create(wlr_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
        const view = try axiom_view.View.create(.{ .toplevel = .{
            .view = undefined,
            .wlr_toplevel = wlr_toplevel,
        } });
        errdefer view.destroy(.assert);

        const toplevel = &view.impl.toplevel;

        // This listener must be added before the scene xdg surface is created.
        // Otherwise, the scene surface nodes will already be disabled by the unmap
        // listeners in the scene xdg surface and scene subsurface tree helpers
        // before our unmap listener is called.
        // However, we need the surface tree to be unchanged in our unmap listener
        // so that we can save the buffers for frame perfection.
        // TODO(wlroots) This is fragile, it would be good if wlroots gave us a
        // better alternative here.
        wlr_toplevel.base.surface.events.unmap.add(&toplevel.unmap);
        errdefer toplevel.unmap.link.remove();

        _ = try view.surface_tree.createSceneXdgSurface(wlr_toplevel.base);

        toplevel.view = view;

        wlr_toplevel.base.data = @intFromPtr(toplevel);
        wlr_toplevel.base.surface.data = @intFromPtr(&view.tree.node);

        // Add listeners that are active over the toplevel's entire lifetime
        wlr_toplevel.events.destroy.add(&toplevel.destroy);
        wlr_toplevel.base.surface.events.map.add(&toplevel.map);
        wlr_toplevel.base.surface.events.commit.add(&toplevel.commit);
        wlr_toplevel.base.events.new_popup.add(&toplevel.new_popup);
    }

    /// Send a configure event, applying the inflight state of the view.
    pub fn configure(toplevel: *Toplevel) bool {
        switch (toplevel.configure_state) {
            .idle, .timed_out, .timed_out_acked => {},
            .inflight, .acked, .committed => unreachable,
        }

        defer switch (toplevel.configure_state) {
            .idle, .inflight, .acked => {},
            .timed_out, .timed_out_acked, .committed => unreachable,
        };

        const inflight = &toplevel.view.inflight;
        const current = &toplevel.view.current;

        const inflight_float = inflight.float or inflight.output != null;
        const current_float = current.float or current.output != null;

        // We avoid a special case for newly mapped views which we have not yet
        // configured by setting the current width/height to the initial width/height
        // of the view in handleMap().
        if (inflight.box.width == current.box.width and
            inflight.box.height == current.box.height and
            (inflight.focus != 0) == (current.focus != 0) and
            inflight.fullscreen == current.fullscreen and
            inflight_float == current_float and
            //inflight.ssd == current.ssd and
            inflight.resizing == current.resizing)
        {
            // If no new configure is required, continue to track a timed out configure
            // from the previous transaction if any.
            switch (toplevel.configure_state) {
                .idle => return false,
                .timed_out => |serial| {
                    toplevel.configure_state = .{ .inflight = serial };
                    return true;
                },
                .timed_out_acked => {
                    toplevel.configure_state = .acked;
                    return true;
                },
                .inflight, .acked, .committed => unreachable,
            }
        }

        const wlr_toplevel = toplevel.wlr_toplevel;

        _ = wlr_toplevel.setActivated(inflight.focus != 0);
        _ = wlr_toplevel.setFullscreen(inflight.fullscreen);
        _ = wlr_toplevel.setResizing(inflight.resizing);

        if (inflight_float) {
            _ = wlr_toplevel.setTiled(.{ .top = false, .bottom = false, .left = false, .right = false });
        } else {
            _ = wlr_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
        }

        // if (toplevel.decoration) |decoration| {
        //     _ = decoration.wlr_decoration.setMode(if (inflight.ssd) .server_side else .client_side);
        // }

        // We need to call this wlroots function even if the inflight dimensions
        // match the current dimensions in order to prevent wlroots internal state
        // from getting out of sync in the case where a client has resized ittoplevel.
        const configure_serial = wlr_toplevel.setSize(inflight.box.width, inflight.box.height);

        // Only track configures with the transaction system if they affect the dimensions of the view.
        // If the configure state is not idle this means we are currently tracking a timed out
        // configure from a previous transaction and should instead track the newly sent configure.
        if (inflight.box.width == current.box.width and
            inflight.box.height == current.box.height and
            toplevel.configure_state == .idle)
        {
            return false;
        }

        toplevel.configure_state = .{
            .inflight = configure_serial,
        };

        return true;
    }

    pub fn destroyPopups(toplevel: Toplevel) void {
        _ = toplevel;
        // var it = toplevel.wlr_toplevel.base.popups.safeIterator(.forward);
        // while (it.next()) |wlr_xdg_popup| wlr_xdg_popup.destroy();
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);

        // This can be be non-null here if the client commits a protocol error or
        // if it exits without destroying its wayland objects.
        // if (toplevel.decoration) |*decoration| {
        //     decoration.deinit();
        // }
        //std.debug.assert(toplevel.decoration == null);

        // Remove listeners that are active for the entire lifetime of the view
        toplevel.destroy.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.commit.link.remove();
        toplevel.new_popup.link.remove();

        // The wlr_surface may outlive the wlr_xdg_toplevel so we must clean up the user data.
        toplevel.wlr_toplevel.base.surface.data = 0;

        const view = toplevel.view;
        view.impl = .none;
        view.destroy(.lazy);
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        std.log.info("mapping toplevel", .{});
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        const view = toplevel.view;

        // Add listeners that are only active while mapped
        toplevel.wlr_toplevel.base.events.ack_configure.add(&toplevel.ack_configure);
        toplevel.wlr_toplevel.events.request_fullscreen.add(&toplevel.request_fullscreen);
        toplevel.wlr_toplevel.events.request_move.add(&toplevel.request_move);
        toplevel.wlr_toplevel.events.request_resize.add(&toplevel.request_resize);
        toplevel.wlr_toplevel.events.request_maximize.add(&toplevel.request_maximize);
        toplevel.wlr_toplevel.events.set_title.add(&toplevel.set_title);
        toplevel.wlr_toplevel.events.set_app_id.add(&toplevel.set_app_id);

        toplevel.wlr_toplevel.base.getGeometry(&toplevel.geometry);

        view.pending.box = .{
            .x = 0,
            .y = 0,
            .width = toplevel.geometry.width,
            .height = toplevel.geometry.height,
        };
        view.inflight.box = view.pending.box;
        view.current.box = view.pending.box;

        // const state = &toplevel.wlr_toplevel.current;
        // const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        //     (state.min_width == state.max_width or state.min_height == state.max_height);

        // if (toplevel.wlr_toplevel.parent != null or has_fixed_size) {
        //     // If the toplevel.wlr_toplevel has a parent or has a fixed size make it float.
        //     // This will be overwritten in axiom_view.View.map() if the view is matched by a rule.
        //     view.pending.float = true;
        // }

        toplevel.view.pending.fullscreen = toplevel.wlr_toplevel.requested.fullscreen;

        view.map() catch {
            std.log.err("out of memory", .{});
            toplevel.wlr_toplevel.resource.getClient().postNoMemory();
        };

        std.log.info("mapped toplevel successfully", .{});
    }

    /// Called when the surface is unmapped and will no longer be displayed.
    fn handleUnmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);

        // Remove listeners that are only active while mapped
        toplevel.ack_configure.link.remove();
        toplevel.request_fullscreen.link.remove();
        toplevel.request_move.link.remove();
        toplevel.request_resize.link.remove();
        toplevel.set_title.link.remove();
        toplevel.set_app_id.link.remove();

        toplevel.view.unmap();
    }

    fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
        const toplevel: *Toplevel = @fieldParentPtr("new_popup", listener);

        axiom_popup.Popup.create(wlr_xdg_popup, toplevel.view.popup_tree, toplevel.view.popup_tree) catch {
            wlr_xdg_popup.resource.postNoMemory();
            return;
        };
    }

    fn handleAckConfigure(
        listener: *wl.Listener(*wlr.XdgSurface.Configure),
        acked_configure: *wlr.XdgSurface.Configure,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("ack_configure", listener);
        switch (toplevel.configure_state) {
            .inflight => |serial| if (acked_configure.serial == serial) {
                toplevel.configure_state = .acked;
            },
            .timed_out => |serial| if (acked_configure.serial == serial) {
                toplevel.configure_state = .timed_out_acked;
            },
            .acked, .idle, .committed, .timed_out_acked => {},
        }
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);
        const view = toplevel.view;

        if (toplevel.wlr_toplevel.base.initial_commit) {
            //_ = toplevel.wlr_toplevel.setWmCapabilities(.{ .fullscreen = true });

            _ = toplevel.wlr_toplevel.setSize(0, 0);

            // if (toplevel.decoration) |decoration| {
            //     const ssd = server.config.rules.ssd.match(toplevel.view) orelse
            //         (decoration.wlr_decoration.requested_mode != .client_side);
            //     _ = decoration.wlr_decoration.setMode(if (ssd) .server_side else .client_side);
            //     toplevel.view.pending.ssd = ssd;
            // }

            return;
        }

        if (!view.mapped) {
            return;
        }

        {
            const state = &toplevel.wlr_toplevel.current;
            view.constraints = .{
                .min_width = @max(state.min_width, 1),
                .max_width = if (state.max_width > 0) @intCast(state.max_width) else math.maxInt(u31),
                .min_height = @max(state.min_height, 1),
                .max_height = if (state.max_height > 0) @intCast(state.max_height) else math.maxInt(u31),
            };
        }

        switch (toplevel.configure_state) {
            .idle, .committed, .timed_out => {
                const old_geometry = toplevel.geometry;
                toplevel.wlr_toplevel.base.getGeometry(&toplevel.geometry);

                const size_changed = toplevel.geometry.width != old_geometry.width or
                    toplevel.geometry.height != old_geometry.height;
                const no_layout = view.current.output != null;

                if (size_changed) {
                    std.log.debug(
                        "client initiated size change: {}x{} -> {}x{}",
                        .{ old_geometry.width, old_geometry.height, toplevel.geometry.width, toplevel.geometry.height },
                    );
                    if (!(view.current.float or no_layout) and !view.current.fullscreen) {
                        // It seems that a disappointingly high number of clients have a buggy
                        // response to configure events. They ack the configure immediately but then
                        // proceed to make one or more wl_surface.commit requests with the old size
                        // before updating the size of the surface. This obviously makes river's
                        // efforts towards frame perfection futile for such clients. However, in the
                        // interest of best serving river's users we will fix up their size here after
                        // logging a shame message.
                        std.log.err("client with app-id '{s}' is buggy and initiated size change while tiled or fullscreen, shame on it", .{
                            view.getAppId() orelse "",
                        });
                    }

                    view.inflight.box.width = toplevel.geometry.width;
                    view.inflight.box.height = toplevel.geometry.height;
                    view.pending.box.width = toplevel.geometry.width;
                    view.pending.box.height = toplevel.geometry.height;
                    view.current = view.inflight;
                    view.updateSceneState();
                } else if (old_geometry.x != toplevel.geometry.x or
                    old_geometry.y != toplevel.geometry.y)
                {
                    // We need to update the surface clip box to reflect the geometry change.
                    view.updateSceneState();
                }
            },
            // If the client has not yet acked our configure, we need to send a
            // frame done event so that it commits another buffer. These
            // buffers won't be rendered since we are still rendering our
            // stashed buffer from when the transaction started.
            .inflight => view.sendFrameDone(),
            .acked, .timed_out_acked => {
                toplevel.wlr_toplevel.base.getGeometry(&toplevel.geometry);

                if (view.inflight.resizing) {
                    view.resizeUpdatePosition(toplevel.geometry.width, toplevel.geometry.height);
                }

                view.inflight.box.width = toplevel.geometry.width;
                view.inflight.box.height = toplevel.geometry.height;
                view.pending.box.width = toplevel.geometry.width;
                view.pending.box.height = toplevel.geometry.height;

                switch (toplevel.configure_state) {
                    .acked => {
                        toplevel.configure_state = .committed;
                        server.root.transaction.notifyConfigured();
                    },
                    .timed_out_acked => {
                        toplevel.configure_state = .idle;
                        view.current = view.inflight;
                        view.updateSceneState();
                    },
                    else => unreachable,
                }
            },
        }
    }

    /// Called when the client asks to be fullscreened. We always honor the request
    /// for now, perhaps it should be denied in some cases in the future.
    fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_fullscreen", listener);
        if (toplevel.view.pending.fullscreen != toplevel.wlr_toplevel.requested.fullscreen) {
            toplevel.view.pending.fullscreen = toplevel.wlr_toplevel.requested.fullscreen;
            server.root.transaction.applyPending();
        }
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        event: *wlr.XdgToplevel.event.Move,
    ) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        const seat: *axiom_seat.Seat = @ptrFromInt(event.seat.seat.data);
        const view = toplevel.view;

        if (view.pending.fullscreen) return;

        if (view.current.output) |current_output| {
            if (view.current.tags & current_output.current.tags == 0) return;
        }
        // if (view.pending.output) |pending_output| {
        //     if (!(view.pending.float or pending_output.layout == null)) return;
        // }
        view.destroyPopups();

        // Moving windows with touch or tablet tool is not yet supported.
        if (seat.seat.validatePointerGrabSerial(null, event.serial)) {
            switch (seat.cursor.cursor_mode) {
                .passthrough => seat.cursor.startMove(view),
                .move, .resize => {},
            }
        }
    }

    fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        const seat: *axiom_seat.Seat = @ptrFromInt(event.seat.seat.data);
        const view = toplevel.view;

        if (view.pending.fullscreen) return;

        if (view.current.output) |current_output| {
            if (view.current.tags & current_output.current.tags == 0) return;
        }
        // if (view.pending.output) |pending_output| {
        //     if (!(view.pending.float or pending_output.layout == null)) return;
        // }

        // Resizing windows with touch or tablet tool is not yet supported.
        if (seat.seat.validatePointerGrabSerial(null, event.serial)) {
            switch (seat.cursor.cursor_mode) {
                .passthrough => seat.cursor.startResize(view, event.edges),
                .move, .resize => {},
            }
        }
    }

    fn handleRequestMaximize(listener: *wl.Listener(void)) void {
        std.log.info("Maximize requested", .{});
        const toplevel: *Toplevel = @fieldParentPtr("request_maximize", listener);
        toplevel.view.maximize();
        _ = toplevel.wlr_toplevel.setMaximized(toplevel.view.pending.maximized);
        server.root.transaction.applyPending();
    }

    /// Called when the client sets / updates its title
    fn handleSetTitle(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("set_title", listener);
        toplevel.view.notifyTitle();
    }

    /// Called when the client sets / updates its app_id
    fn handleSetAppId(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("set_app_id", listener);
        toplevel.view.notifyAppId();
    }
};
