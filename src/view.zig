const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
//const wp = @import("wayland").server.wp;

const server = &@import("main.zig").server;
const gpa = @import("utils.zig").gpa;

//const ForeignToplevelHandle = @import("ForeignToplevelHandle.zig");
const axiom_toplevel = @import("toplevel.zig");
const axiom_xwayland = @import("xwayland.zig");
const axiom_keyboard = @import("keyboard.zig");
const axiom_output = @import("output.zig");
const axiom_popup = @import("popup.zig");
const axiom_root = @import("root.zig");
const axiom_seat = @import("seat.zig");
const axiom_cursor = @import("cursor.zig");
const AxiomSceneNodeData = @import("scene_node_data.zig").SceneNodeData;
const AxiomData = @import("scene_node_data.zig").Data;

pub const Constraints = struct {
    min_width: u31 = 1,
    max_width: u31 = math.maxInt(u31),
    min_height: u31 = 1,
    max_height: u31 = math.maxInt(u31),
};

const Impl = union(enum) {
    toplevel: axiom_toplevel.Toplevel,
    xwayland_view: axiom_xwayland.XwaylandView,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the view.
    /// The toplevel could simply be set to undefined instead, but using a
    /// tag like this gives us better safety checks.
    none,
};

const AttachRelativeMode = enum {
    above,
    below,
};

const TearingMode = enum {
    no_tearing,
    tearing,
    window_hint,
};

pub const ViewState = struct {
    /// The output the view is currently assigned to.
    /// May be null if there are no outputs or for newly created views.
    /// Must be set using setPendingOutput()
    output: ?*axiom_output.Output = null,

    /// The output-relative coordinates of the view and dimensions requested by river.
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    /// The tags of the view, as a bitmask
    tags: u32 = 0,

    /// Number of seats currently focusing the view
    focus: u32 = 0,

    float: bool = true,
    maximized: bool = false,
    fullscreen: bool = false,
    urgent: bool = false,
    //ssd: bool = false,
    resizable: bool = true,
    resizing: bool = false,

    /// Modify the x/y of the given state by delta_x/delta_y, clamping to the
    /// bounds of the output.
    pub fn move(state: *ViewState, delta_x: i32, delta_y: i32) void {
        var output_width: i32 = math.maxInt(i32);
        var output_height: i32 = math.maxInt(i32);
        if (state.output) |output| {
            output.wlr_output.effectiveResolution(&output_width, &output_height);
        }

        const border_width = 2;

        const max_x = output_width - state.box.width - border_width + @divFloor(state.box.width, 2);
        state.box.x += delta_x;
        //state.box.x = @max(state.box.x, border_width);
        state.box.x = @min(state.box.x, max_x);
        state.box.x = @max(state.box.x, 0 - @divFloor(state.box.width, 2));

        const max_y = output_height - state.box.height - border_width + @divFloor(state.box.height, 2);
        state.box.y += delta_y;
        state.box.y = @max(state.box.y, border_width);
        state.box.y = @min(state.box.y, max_y);
        state.box.y = @max(state.box.y, 0);
    }

    pub fn clampToOutput(state: *ViewState) void {
        const output = state.output orelse return;

        var output_width: i32 = undefined;
        var output_height: i32 = undefined;
        output.wlr_output.effectiveResolution(&output_width, &output_height);

        const border_width = 2;
        state.box.width = @min(state.box.width, output_width - (2 * border_width));
        state.box.height = @min(state.box.height, output_height - (2 * border_width));

        state.move(0, 0);
    }
};

pub const View = struct {
    id: u64,
    /// The implementation of this view
    impl: Impl,

    /// Link for Root.views
    link: wl.list.Link,

    tree: *wlr.SceneTree,
    surface_tree: *wlr.SceneTree,
    saved_surface_tree: *wlr.SceneTree,
    /// Order is left, right, top, bottom
    borders: [4]*wlr.SceneRect,
    border_color: [4]f32 = .{ 255, 255, 255, 0.2 },
    border_width: u32 = 2,
    popup_tree: *wlr.SceneTree,

    /// Bounds on the width/height of the view, set by the toplevel/xwayland_view implementation.
    constraints: Constraints = .{},

    mapped: bool = false,
    /// This is true if the View is involved in the currently inflight transaction.
    inflight_transaction: bool = false,
    /// This indicates that the view should be destroyed when the current
    /// transaction completes. See View.destroy()
    destroying: bool = false,

    /// The state of the view that is directly acted upon/modified through user input.
    ///
    /// Pending state will be copied to the inflight state and communicated to clients
    /// to be applied as a single atomic transaction across all clients as soon as any
    /// in progress transaction has been completed.
    ///
    /// Any time pending state is modified Root.applyPending() must be called
    /// before yielding back to the event loop.
    pending: ViewState = .{},
    pending_focus_stack_link: wl.list.Link,
    //pending_wm_stack_link: wl.list.Link,

    /// The state most recently sent to the layout generator and clients.
    /// This state is immutable until all clients have replied and the transaction
    /// is completed, at which point this inflight state is copied to current.
    inflight: ViewState = .{},
    inflight_focus_stack_link: wl.list.Link,
    //inflight_wm_stack_link: wl.list.Link,

    /// The current state represented by the scene graph.
    current: ViewState = .{},

    /// The floating dimensions the view, saved so that they can be restored if the
    /// view returns to floating mode.
    float_box: wlr.Box = undefined,

    post_maximize_box: wlr.Box = undefined,

    /// This state exists purely to allow for more intuitive behavior when
    /// exiting fullscreen if there is no active layout.
    post_fullscreen_box: wlr.Box = undefined,

    //foreign_toplevel_handle: ForeignToplevelHandle = .{},

    /// Connector name of the output this view occupied before an evacuation.
    output_before_evac: ?[]const u8 = null,

    tearing_mode: TearingMode = .window_hint,

    pub fn create(impl: Impl) error{OutOfMemory}!*View {
        assert(impl != .none);

        const view = try gpa.create(View);
        errdefer gpa.destroy(view);

        const tree = try server.root.transaction.hidden.tree.createSceneTree();
        errdefer tree.node.destroy();
        const popup_tree = try server.root.transaction.hidden.tree.createSceneTree();
        errdefer popup_tree.node.destroy();

        const id = view.generateRandomId() catch blk: {
            break :blk 1;
        };

        //const border_color = .{ 255, 0, 0, 0 };
        view.* = .{
            .id = id,
            .impl = impl,
            .link = undefined,
            .tree = tree,
            .surface_tree = try tree.createSceneTree(),
            .saved_surface_tree = try tree.createSceneTree(),
            .borders = .{
                try tree.createSceneRect(0, 0, &view.border_color),
                try tree.createSceneRect(0, 0, &view.border_color),
                try tree.createSceneRect(0, 0, &view.border_color),
                try tree.createSceneRect(0, 0, &view.border_color),
            },
            .popup_tree = popup_tree,

            //.pending_wm_stack_link = undefined,
            .pending_focus_stack_link = undefined,
            //.inflight_wm_stack_link = undefined,
            .inflight_focus_stack_link = undefined,
        };

        server.root.views.prepend(view);
        server.root.transaction.hidden.pending.focus_stack.prepend(view);
        server.root.transaction.hidden.inflight.focus_stack.prepend(view);

        view.tree.node.setEnabled(false);
        view.popup_tree.node.setEnabled(false);
        view.saved_surface_tree.node.setEnabled(false);
        try AxiomSceneNodeData.attach(&view.tree.node, .{ .view = view });
        try AxiomSceneNodeData.attach(&view.popup_tree.node, .{ .view = view });

        try server.views.append(view);
        std.debug.print("length: {} \n", .{server.views.items.len});
        std.debug.print("id: {} \n", .{view.id});

        return view;
    }

    /// If saved buffers of the view are currently in use by a transaction,
    /// mark this view for destruction when the transaction completes. Otherwise
    /// destroy immediately.
    pub fn destroy(view: *View, when: enum { lazy, assert }) void {
        assert(view.impl == .none);
        assert(!view.mapped);

        view.destroying = true;

        {
            for (server.views.items, 0..) |value, i| {
                if (value.id == view.id) {
                    _ = server.views.swapRemove(i);
                }
            }
        }

        // If there are still saved buffers, then this view needs to be kept
        // around until the current transaction completes. This function will be
        // called again in Root.commitTransaction()
        if (!view.saved_surface_tree.node.enabled) {
            view.tree.node.destroy();
            view.popup_tree.node.destroy();

            view.link.remove();
            view.pending_focus_stack_link.remove();
            //view.pending_wm_stack_link.remove();
            view.inflight_focus_stack_link.remove();
            //view.inflight_wm_stack_link.remove();

            if (view.output_before_evac) |name| gpa.free(name);

            gpa.destroy(view);
        } else {
            switch (when) {
                .lazy => {},
                .assert => unreachable,
            }
        }
    }

    pub fn resize(
        view: *View,
        edges: ?wlr.Edges,
    ) void {
        if (view.pending.fullscreen or !view.pending.resizable) return;

        if (view.current.output) |current_output| {
            if (view.current.tags & current_output.current.tags == 0) return;
        }
        // if (view.pending.output) |pending_output| {
        //     if (!(view.pending.float or pending_output.layout == null)) return;
        // }

        // Resizing windows with touch or tablet tool is not yet supported.
        // TODO: do this properly
        switch (server.input_manager.defaultSeat().cursor.current_mode) {
            .passthrough => server.input_manager.defaultSeat().cursor.startResize(view, edges),
            .move, .resize => {},
        }
    }

    pub fn move(
        view: *View,
        seat: *axiom_seat.Seat,
    ) void {
        if (view.pending.fullscreen) return;

        if (view.current.output) |current_output| {
            if (view.current.tags & current_output.current.tags == 0) return;
        }
        // if (view.pending.output) |pending_output| {
        //     if (!(view.pending.float or pending_output.layout == null)) return;
        // }
        view.destroyPopups();

        // Moving windows with touch or tablet tool is not yet supported.
        //if (seat.wlr_seat.validatePointerGrabSerial(null, event.serial)) {
        switch (seat.cursor.current_mode) {
            .passthrough => seat.cursor.startMove(view),
            .move, .resize => {},
        }
        //}
    }

    /// The change in x/y position of the view during resize cannot be determined
    /// until the size of the buffer actually committed is known. Clients are permitted
    /// by the protocol to take a size smaller than that requested by the compositor in
    /// order to maintain an aspect ratio or similar (mpv does this for example).
    pub fn resizeUpdatePosition(view: *View, width: i32, height: i32) void {
        assert(view.inflight.resizing);

        const data = blk: {
            // TODO: do this properly
            const seat = server.input_manager.defaultSeat();
            const cursor = seat.cursor;
            if (cursor.inflight_mode == .resize and cursor.inflight_mode.resize.view == view) {
                break :blk cursor.inflight_mode.resize;
            } else {
                unreachable;
            }
        };

        if (data.edges.left) {
            view.inflight.box.x += view.current.box.width - width;
            view.pending.box.x = view.inflight.box.x;
        }

        if (data.edges.top) {
            view.inflight.box.y += view.current.box.height - height;
            view.pending.box.y = view.inflight.box.y;
        }
    }

    pub fn commitTransaction(view: *View) void {
        assert(view.inflight_transaction);
        view.inflight_transaction = false;

        //view.foreign_toplevel_handle.update();

        view.dropSavedSurfaceTree();

        switch (view.impl) {
            .toplevel => |*toplevel| {
                switch (toplevel.configure_state) {
                    .inflight, .acked => {
                        switch (toplevel.configure_state) {
                            .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                            .acked => toplevel.configure_state = .timed_out_acked,
                            else => unreachable,
                        }

                        // The transaction has timed out for the xdg toplevel, which means a commit
                        // in response to the configure with the inflight width/height has not yet
                        // been made. It may seem that we should therefore leave the current.box
                        // width/height unchanged. However, this would in fact cause visual glitches.
                        //
                        // We must update the dimensions to the current geometry of the
                        // xdg toplevel here in order to handle the following series of events:
                        //
                        // 0. initial state: client has dimensions X
                        // 1. transaction A sends a configure of size Y
                        // 2. transaction A times out - saved surfaces are dropped
                        // 3. transaction B sends a configure of size Z
                        // 4. client commits buffer of size Y
                        // 5. transaction B times out - saved surfaces are dropped
                        //
                        // If we did not use the current geometry of the toplevel at this point
                        // we would be rendering the SSD border at initial size X but the surface
                        // would be rendered at size Y.
                        if (view.inflight.resizing) {
                            view.resizeUpdatePosition(toplevel.geometry.width, toplevel.geometry.height);
                        }

                        view.current = view.inflight;
                        view.current.box.width = toplevel.geometry.width;
                        view.current.box.height = toplevel.geometry.height;
                    },
                    .idle, .committed => {
                        toplevel.configure_state = .idle;
                        view.current = view.inflight;
                    },
                    .timed_out, .timed_out_acked => unreachable,
                }
            },
            .xwayland_view => |xwayland_view| {
                if (view.inflight.resizing) {
                    view.resizeUpdatePosition(
                        xwayland_view.xwayland_surface.width,
                        xwayland_view.xwayland_surface.height,
                    );
                }

                view.inflight.box.width = xwayland_view.xwayland_surface.width;
                view.inflight.box.height = xwayland_view.xwayland_surface.height;
                view.pending.box.width = xwayland_view.xwayland_surface.width;
                view.pending.box.height = xwayland_view.xwayland_surface.height;

                view.current = view.inflight;
            },
            // This may seem pointless at first glance, but is in fact necessary
            // to prevent an assertion failure in Root.commitTransaction() as that
            // function assumes that the inflight tags/output will be applied by
            // View.commitTransaction() even for views being destroyed.
            .none => view.current = view.inflight,
        }

        view.updateSceneState();
    }

    pub fn updateSceneState(view: *View) void {
        const box = &view.current.box;
        view.tree.node.setPosition(box.x, box.y);
        view.popup_tree.node.setPosition(box.x, box.y);

        var output_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (view.current.output) |output| {
            output.wlr_output.effectiveResolution(&output_box.width, &output_box.height);
        }

        {
            var surface_clip: wlr.Box = output_box;

            // The clip is applied relative to the root node of the subsurface tree.
            surface_clip.x -= box.x;
            surface_clip.y -= box.y;

            switch (view.impl) {
                .toplevel => |toplevel| {
                    surface_clip.x += toplevel.geometry.x;
                    surface_clip.y += toplevel.geometry.y;
                },
                .xwayland_view, .none => {},
            }

            if (!view.surface_tree.children.empty()) {
                view.surface_tree.node.subsurfaceTreeSetClip(&surface_clip);
            }
        }

        {
            //const config = &server.config;
            const border_width: c_int = @intCast(view.border_width);
            const border_color = blk: {
                if (view.current.urgent) break :blk view.border_color;
                if (view.current.focus != 0) break :blk view.border_color;
                break :blk view.border_color;
            };

            // Order is left, right, top, bottom
            // left and right borders include the corners, top and bottom do not.
            var border_boxes = [4]wlr.Box{
                .{
                    .x = -border_width,
                    .y = -border_width,
                    .width = border_width,
                    .height = box.height + 2 * border_width,
                },
                .{
                    .x = box.width,
                    .y = -border_width,
                    .width = border_width,
                    .height = box.height + 2 * border_width,
                },
                .{
                    .x = 0,
                    .y = -border_width,
                    .width = box.width,
                    .height = border_width,
                },
                .{
                    .x = 0,
                    .y = box.height,
                    .width = box.width,
                    .height = border_width,
                },
            };

            for (&view.borders, &border_boxes) |border, *border_box| {
                border_box.x += box.x;
                border_box.y += box.y;
                _ = border_box.intersection(border_box, &output_box);
                border_box.x -= box.x;
                border_box.y -= box.y;

                border.node.setEnabled(true);
                border.node.setPosition(border_box.x, border_box.y);
                border.setSize(border_box.width, border_box.height);
                border.setColor(&border_color);
            }
        }
    }

    /// Returns true if the configure should be waited for by the transaction system.
    pub fn configure(view: *View) bool {
        assert(view.mapped and !view.destroying);
        switch (view.impl) {
            .toplevel => |*toplevel| return toplevel.configure(),
            .xwayland_view => |*xwayland_view| return xwayland_view.configure(),
            .none => unreachable,
        }
    }

    /// Returns null if the view is currently being destroyed and no longer has
    /// an associated surface.
    /// May also return null for Xwayland views that are not currently mapped.
    pub fn rootSurface(view: View) ?*wlr.Surface {
        return switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.surface,
            .none => null,
        };
    }

    pub fn sendFrameDone(view: View) void {
        assert(view.mapped and !view.destroying);

        var now: posix.timespec = undefined;
        posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
        view.rootSurface().?.sendFrameDone(&now);
    }

    pub fn dropSavedSurfaceTree(view: *View) void {
        if (!view.saved_surface_tree.node.enabled) return;

        var it = view.saved_surface_tree.children.safeIterator(.forward);
        while (it.next()) |node| node.destroy();

        view.saved_surface_tree.node.setEnabled(false);
        view.surface_tree.node.setEnabled(true);
    }

    pub fn saveSurfaceTree(view: *View) void {
        assert(!view.saved_surface_tree.node.enabled);
        assert(view.saved_surface_tree.children.empty());

        view.surface_tree.node.forEachBuffer(*wlr.SceneTree, saveSurfaceTreeIter, view.saved_surface_tree);

        view.surface_tree.node.setEnabled(false);
        view.saved_surface_tree.node.setEnabled(true);
    }

    fn saveSurfaceTreeIter(
        buffer: *wlr.SceneBuffer,
        sx: c_int,
        sy: c_int,
        saved_surface_tree: *wlr.SceneTree,
    ) void {
        const saved = saved_surface_tree.createSceneBuffer(buffer.buffer) catch {
            std.log.err("out of memory", .{});
            return;
        };
        saved.node.setPosition(sx, sy);
        saved.setDestSize(buffer.dst_width, buffer.dst_height);
        saved.setSourceBox(&buffer.src_box);
        saved.setTransform(buffer.transform);
    }

    pub fn setPendingOutput(view: *View, output: *axiom_output.Output) void {

        // remove view from previous output
        view.removeFromOutputList();

        view.pending.output = output;
        output.views.append(view) catch std.log.err("failed to add to view list", .{});
        //view.pending_wm_stack_link.remove();
        view.pending_focus_stack_link.remove();

        // switch (output.attachMode()) {
        //     .top => output.pending.wm_stack.prepend(view),
        //     .bottom => output.pending.wm_stack.append(view),
        //     .after => |n| view.attachAfter(&output.pending, n),
        //     .above => view.attachRelative(&output.pending, .above),
        //     .below => view.attachRelative(&output.pending, .below),
        // }
        output.pending.focus_stack.prepend(view);

        if (view.pending.fullscreen) {
            view.pending.box = .{ .x = 0, .y = 0, .width = undefined, .height = undefined };
            output.wlr_output.effectiveResolution(&view.pending.box.width, &view.pending.box.height);
        } else if (view.pending.float) {
            view.pending.clampToOutput();
        }
    }

    fn removeFromOutputList(view: *View) void {
        std.debug.print("removing.. \n", .{});
        if (view.pending.output) |prev_output| {
            std.debug.print("output present", .{});
            for (prev_output.views.items, 0..) |value, i| {
                if (value == view) {
                    std.debug.print("removed view \n", .{});
                    _ = prev_output.views.swapRemove(i);
                }
            }
        }
    }

    fn generateRandomId(_: *View) !u64 {
        var prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        const rand = prng.random();

        var redo = true;

        while (redo) {
            redo = false;
            const id = rand.int(u32);
            for (server.views.items) |value| {
                if (value.id == id) {
                    redo = true;
                }
            }

            if (!redo) {
                return id;
            }
        }

        return 1;
    }

    pub fn close(view: *View) void {
        switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.close(),
            .none => {},
        }
    }

    pub fn destroyPopups(view: View) void {
        switch (view.impl) {
            .toplevel => |toplevel| toplevel.destroyPopups(),
            .xwayland_view, .none => {},
        }
    }

    /// Return the current title of the view if any.
    pub fn getTitle(view: View) ?[*:0]const u8 {
        assert(!view.destroying);
        return switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.title,
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.title,
            .none => unreachable,
        };
    }

    /// Return the current app_id of the view if any.
    pub fn getAppId(view: View) ?[*:0]const u8 {
        assert(!view.destroying);
        return switch (view.impl) {
            .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
            // X11 clients don't have an app_id but the class serves a similar role.
            .xwayland_view => |xwayland_view| xwayland_view.xwayland_surface.class,
            .none => unreachable,
        };
    }

    /// Return true if tearing should be allowed for the view.
    pub fn allowTearing(view: *View) bool {
        switch (view.tearing_mode) {
            .no_tearing => return false,
            .tearing => return true,
            .window_hint => {
                if (server.config.allow_tearing) {
                    if (view.rootSurface()) |root_surface| {
                        return server.tearing_control_manager.hintFromSurface(root_surface) == .@"async";
                    }
                }
                return false;
            },
        }
    }

    /// Clamp the width/height of the box to the constraints of the view
    pub fn applyConstraints(view: *View, box: *wlr.Box) void {
        box.width = math.clamp(box.width, view.constraints.min_width, view.constraints.max_width);
        box.height = math.clamp(box.height, view.constraints.min_height, view.constraints.max_height);
    }

    /// Called by the impl when the surface is ready to be displayed
    pub fn map(view: *View) !void {
        std.log.debug("view '{?s}' mapped", .{view.getTitle()});

        assert(!view.mapped and !view.destroying);
        view.mapped = true;

        const output = server.input_manager.defaultSeat().focused_output;

        if (output) |o| {
            // Center the initial pending box on the output
            view.pending.box.x = @divTrunc(@max(0, o.usable_box.width - view.pending.box.width), 2);
            view.pending.box.y = @divTrunc(@max(0, o.usable_box.height - view.pending.box.height), 2);
        }

        view.pending.tags = blk: {
            const default = if (output) |o| o.pending.tags else server.root.transaction.fallback_state.tags;
            //if (server.config.rules.tags.match(view)) |tags| break :blk tags;
            //const tags = default & server.config.spawn_tagmask;
            break :blk default;
        };

        if (output) |o| {
            view.setPendingOutput(o);

            var it = server.input_manager.seats.first;
            while (it) |seat_node| : (it = seat_node.next) seat_node.data.focus(view);
        } else {
            std.log.debug("no output available for newly mapped view, adding to fallback stacks", .{});

            //view.pending_wm_stack_link.remove();
            view.pending_focus_stack_link.remove();

            // switch (server.config.default_attach_mode) {
            //     .top => server.root.fallback_pending.wm_stack.prepend(view),
            //     .bottom => server.root.fallback_pending.wm_stack.append(view),
            //     .after => |n| view.attachAfter(&server.root.fallback_pending, n),
            //     .above => view.attachRelative(&server.root.fallback_pending, .above),
            //     .below => view.attachRelative(&server.root.fallback_pending, .below),
            // }
            server.root.transaction.fallback_state.focus_stack.prepend(view);

            //view.inflight_wm_stack_link.remove();
            //view.inflight_wm_stack_link.init();

            view.inflight_focus_stack_link.remove();
            view.inflight_focus_stack_link.init();
        }

        //view.float_box = view.pending.box;

        server.root.transaction.applyPending();
    }

    /// Called by the impl when the surface will no longer be displayed
    pub fn unmap(view: *View) void {
        std.log.debug("view '{?s}' unmapped", .{view.getTitle()});

        view.removeFromOutputList();

        if (!view.saved_surface_tree.node.enabled) view.saveSurfaceTree();

        {
            view.pending.output = null;
            view.pending_focus_stack_link.remove();
            // view.pending_wm_stack_link.remove();
            server.root.transaction.hidden.pending.focus_stack.prepend(view);
            //server.root.transaction.hidden.pending.wm_stack.prepend(view);
        }

        assert(view.mapped and !view.destroying);
        view.mapped = false;

        //view.foreign_toplevel_handle.unmap();

        server.root.transaction.applyPending();
    }

    pub fn maximize(view: *View) void {
        if (!view.current.maximized) {
            std.log.info("View is not maximized", .{});
            const box = &view.pending.box;

            var width: c_int = undefined;
            var height: c_int = undefined;
            view.post_maximize_box = view.pending.box;
            _ = view.pending.output.?.wlr_output.effectiveResolution(&width, &height);
            box.* = .{
                .width = width,
                .height = height,
                .x = 0,
                .y = 0,
            };

            view.pending.maximized = true;
            view.pending.resizable = false;
        } else {
            std.log.info("View is maximized", .{});
            const box = &view.pending.box;
            var width: c_int = undefined;
            var height: c_int = undefined;
            _ = view.pending.output.?.wlr_output.effectiveResolution(&width, &height);
            box.* = view.post_maximize_box;
            view.pending.maximized = false;
            view.pending.resizable = true;
        }

        server.root.transaction.applyPending();
    }

    pub fn notifyTitle(view: *const View) void {
        // if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        //     if (view.getTitle()) |title| wlr_handle.setTitle(title);
        // }
        // Send title to all status listeners attached to a seat which focuses this view

        _ = view;

        // const seat = server.seat;
        // if (seat_node.data.focused == .view and seat_node.data.focused.view == view) {
        //     var client_it = seat_node.data.status_trackers.first;
        //     while (client_it) |client_node| : (client_it = client_node.next) {
        //         client_node.data.sendFocusedView();
        //     }
        // }
    }

    pub fn notifyAppId(view: View) void {
        _ = view;
        // if (view.foreign_toplevel_handle.wlr_handle) |wlr_handle| {
        //     if (view.getAppId()) |app_id| wlr_handle.setAppId(app_id);
        // }
    }
};
