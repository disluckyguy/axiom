const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const axiom_root = @import("root.zig");
const gpa = @import("utils.zig").gpa;

const server = &@import("main.zig").server;

pub const PendingState = struct {
    tags: u32 = 1 << 0,
    focus_stack: wl.list.Head(axiom_view.View, .pending_focus_stack_link),
    //wm_stack: wl.list.Head(axiom_view.View, .pending_wm_stack_link),
};

pub const Output = struct {
    server: *axiom_server.Server,
    wlr_output: *wlr.Output,
    scene_output: *wlr.SceneOutput,

    all_outputs_link: wl.list.Link,
    active_outputs_link: wl.list.Link,

    usable_box: wlr.Box,

    tree: *wlr.SceneTree,
    normal_content: *wlr.SceneTree,
    locked_content: *wlr.SceneTree,

    layers: struct {
        layout: *wlr.SceneTree,
        float: *wlr.SceneTree,
        fullscreen: *wlr.SceneTree,
        popups: *wlr.SceneTree,
    },

    gamma_dirty: bool = false,

    pending: PendingState,

    inflight: struct {
        tags: u32 = 1 << 0,
        focus_stack: wl.list.Head(axiom_view.View, .inflight_focus_stack_link),
        //wm_stack: wl.list.Head(axiom_view.View, .inflight_wm_stack_link),
        fullscreen: ?*axiom_view.View = null,
        // layout_demand: ?LayoutDemand = null,
    },

    current: struct {
        tags: u32 = 1 << 0,
        fullscreen: ?*axiom_view.View = null,
    } = .{},

    previous_tags: u32 = 1 << 0,

    frame: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(frame),
    request_state: wl.Listener(*wlr.Output.event.RequestState) =
        wl.Listener(*wlr.Output.event.RequestState).init(request_state),
    destroy: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(destroy),
    present: wl.Listener(*wlr.Output.event.Present) = wl.Listener(*wlr.Output.event.Present).init(handlePresent),

    pub fn create(wlr_output: *wlr.Output) !void {
        const output: *Output = try gpa.create(Output);
        errdefer gpa.destroy(output);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return error.InitRenderFailed;

        // If no standard mode for the output works we can't enable the output automatically.
        // It will stay disabled unless the user configures a custom mode which works.
        //
        // For the Wayland backend, the list of modes will be empty and it is possible to
        // enable the output without setting a mode.
        {
            var state = wlr.Output.State.init();
            defer state.finish();

            state.setEnabled(true);

            if (wlr_output.preferredMode()) |preferred_mode| {
                state.setMode(preferred_mode);
                std.log.info("preferred mode set", .{});
            }

            if (!wlr_output.commitState(&state)) {
                std.log.err("initial output commit with preferred mode failed, trying all modes", .{});

                // It is important to try other modes if the preferred mode fails
                // which is reported to be helpful in practice with e.g. multiple
                // high resolution monitors connected through a usb dock.
                var it = wlr_output.modes.iterator(.forward);
                while (it.next()) |mode| {
                    state.setMode(mode);
                    if (wlr_output.commitState(&state)) {
                        std.log.info("initial output commit succeeded with mode {}x{}@{}mHz", .{
                            mode.width,
                            mode.height,
                            mode.refresh,
                        });
                        break;
                    } else {
                        std.log.err("initial output commit failed with mode {}x{}@{}mHz", .{
                            mode.width,
                            mode.height,
                            mode.refresh,
                        });
                    }
                }

                return;
            }
        }

        var width: c_int = undefined;
        var height: c_int = undefined;
        wlr_output.effectiveResolution(&width, &height);

        const scene_output = try server.root.scene.createSceneOutput(wlr_output);

        const tree = try server.root.interactive_layers.outputs.createSceneTree();
        const normal_content = try tree.createSceneTree();

        output.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .scene_output = scene_output,
            .all_outputs_link = undefined,
            .active_outputs_link = undefined,
            .tree = tree,
            .normal_content = normal_content,
            .locked_content = try tree.createSceneTree(),
            .layers = .{
                .layout = try normal_content.createSceneTree(),
                .float = try normal_content.createSceneTree(),
                .fullscreen = try normal_content.createSceneTree(),
                .popups = try normal_content.createSceneTree(),
            },
            .pending = .{
                .focus_stack = undefined,
                //.wm_stack = undefined,
            },
            .inflight = .{
                .focus_stack = undefined,
                //.wm_stack = undefined,
            },
            .usable_box = .{
                .x = 0,
                .y = 0,
                .width = width,
                .height = height,
            },
        };
        wlr_output.data = @intFromPtr(output);

        output.pending.focus_stack.init();
        //.pending.wm_stack.init();
        output.inflight.focus_stack.init();
        //output.inflight.wm_stack.init();

        //output.status.init();

        _ = try output.layers.fullscreen.createSceneRect(width, height, &[_]f32{ 0, 0, 0, 1.0 });
        output.layers.fullscreen.node.setEnabled(false);

        wlr_output.events.destroy.add(&output.destroy);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.present.add(&output.present);

        server.seat.focused_output = output;
        output.enableDisable();
    }

    pub fn enableDisable(output: *Output) void {
        output.gamma_dirty = true;

        if (output.wlr_output.enabled) {
            output.server.root.activateOutput(output);
        } else {
            output.server.root.deactivateOutput(output);
        }
    }

    pub fn frame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);

        const scene_output = output.server.root.scene.getSceneOutput(output.wlr_output) orelse {
            std.log.info("failed to get scene output", .{});
            unreachable;
        };

        _ = scene_output.commit(null);

        output.renderAndCommit(scene_output) catch |err| switch (err) {
            error.OutOfMemory => std.log.err("out of memory", .{}),
            error.CommitFailed => std.log.err("output commit failed for {s}", .{output.wlr_output.name}),
        };

        var now: posix.timespec = undefined;
        posix.clock_gettime(posix.CLOCK.MONOTONIC, &now) catch @panic("CLOCK_MONOTONIC not supported");
        scene_output.sendFrameDone(&now);
    }

    fn renderAndCommit(output: *Output, scene_output: *wlr.SceneOutput) !void {
        if (!output.wlr_output.needs_frame and !output.gamma_dirty and
            !scene_output.pending_commit_damage.notEmpty())
        {
            return;
        }

        var state = wlr.Output.State.init();
        defer state.finish();

        if (!scene_output.buildState(&state, null)) return error.CommitFailed;

        if (output.gamma_dirty) {
            const control = server.root.gamma_control_manager.getControl(output.wlr_output);
            if (!wlr.GammaControlV1.apply(control, &state)) return error.OutOfMemory;

            if (!output.wlr_output.testState(&state) or output.wlr_output.isHeadless()) {
                //    wlr.GammaControlV1.sendFailedAndDestroy(control);
                state.clearGammaLut();
                state.committed.gamma_lut = false;
            }
        }

        // TODO: implement tearing
        // if (output.current.fullscreen) |fullscreen| {
        //     if (fullscreen.allowTearing()) {
        //         state.tearing_page_flip = true;
        //         if (!output.wlr_output.testState(&state)) {
        //             std.log.debug("tearing page flip test failed for {s}, retrying without tearing", .{
        //                 output.wlr_output.name,
        //             });
        //             state.tearing_page_flip = false;
        //         }
        //     }
        // }

        if (!output.wlr_output.commitState(&state)) return error.CommitFailed;

        output.gamma_dirty = false;

        //TODO: implement lock manager

        // if (server.lock_manager.state == .locked or
        //     (server.lock_manager.state == .waiting_for_lock_surfaces and output.locked_content.node.enabled) or
        //     server.lock_manager.state == .waiting_for_blank)
        // {
        //     std.debug.assert(!output.normal_content.node.enabled);
        //     std.debug.assert(output.locked_content.node.enabled);

        //     switch (server.lock_manager.state) {
        //         .unlocked => unreachable,
        //         .locked => switch (output.lock_render_state) {
        //             .pending_unlock, .unlocked, .pending_blank, .pending_lock_surface => unreachable,
        //             .blanked, .lock_surface => {},
        //         },
        //         .waiting_for_blank => {
        //             if (output.lock_render_state != .blanked) {
        //                 output.lock_render_state = .pending_blank;
        //             }
        //         },
        //         .waiting_for_lock_surfaces => {
        //             if (output.lock_render_state != .lock_surface) {
        //                 output.lock_render_state = .pending_lock_surface;
        //             }
        //         },
        //     }
        // } else {
        //     if (output.lock_render_state != .unlocked) {
        //         output.lock_render_state = .pending_unlock;
        //     }
        // }
    }

    pub fn applyState(output: *Output, state: *wlr.Output.State) error{CommitFailed}!void {
        const enable_state_change = state.committed.enabled and
            (state.enabled != output.wlr_output.enabled);

        if (!output.wlr_output.commitState(state)) {
            return error.CommitFailed;
        }

        if (enable_state_change) {
            output.enableDisable();
        }

        if (state.committed.mode) {
            //TODO: implement layer shell
            //output.arrangeLayers();

            //TODO: implement lock manager
            //server.lock_manager.updateLockSurfaceSize(output);
        }
    }

    pub fn request_state(
        listener: *wl.Listener(*wlr.Output.event.RequestState),
        event: *wlr.Output.event.RequestState,
    ) void {
        const output: *Output = @fieldParentPtr("request_state", listener);

        _ = output.wlr_output.commitState(event.state);
    }

    fn handlePresent(
        listener: *wl.Listener(*wlr.Output.event.Present),
        event: *wlr.Output.event.Present,
    ) void {
        const output: *Output = @fieldParentPtr("present", listener);

        _ = output;

        if (!event.presented) {
            return;
        }

        //TODO: implement lock manager

        // switch (output.lock_render_state) {
        //     .pending_unlock => {
        //         std.debug.assert(output.server.lock_manager.state != .locked);
        //         output.lock_render_state = .unlocked;
        //     },
        //     .unlocked => std.debug.assert(output.server.lock_manager.state != .locked),
        //     .pending_blank, .pending_lock_surface => {
        //         output.lock_render_state = switch (output.lock_render_state) {
        //             .pending_blank => .blanked,
        //             .pending_lock_surface => .lock_surface,
        //             .pending_unlock, .unlocked, .blanked, .lock_surface => unreachable,
        //         };

        //         // if (server.lock_manager.state != .locked) {
        //         //     server.lock_manager.maybeLock();
        //         // }
        //     },
        //     .blanked, .lock_surface => {},
        // }
    }

    pub fn destroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("destroy", listener);

        output.frame.link.remove();
        output.destroy.link.remove();

        gpa.destroy(output);
    }

    pub fn setTitle(output: *Output) void {
        const title = std.fmt.allocPrintZ(gpa, "Axiom Wayland Compositor - {s}", .{output.wlr_output.name}) catch return;
        defer gpa.free(title);
        if (output.wlr_output.isWl()) {
            output.wlr_output.wlSetTitle(title);
        } else if (wlr.config.has_x11_backend and output.wlr_output.isX11()) {
            output.wlr_output.x11SetTitle(title);
        }
    }
};
