const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const zwlr = @import("wayland").server.zwlr;
const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_transaction = @import("transaction.zig");
const axiom_view = @import("view.zig");
const axiom_xwayland = @import("xwayland.zig");
const axiom_keyboard = @import("keyboard.zig");
const axiom_cursor = @import("cursor.zig");
const axiom_output = @import("output.zig");
const AxiomSceneNodeData = @import("scene_node_data.zig").SceneNodeData;
const AxiomData = @import("scene_node_data.zig").Data;

const gpa = @import("utils.zig").gpa;

const server = &@import("main.zig").server;

pub const Root = struct {
    server: *axiom_server.Server,
    scene: *wlr.Scene,
    interactive_content: *wlr.SceneTree,
    drag_icons: *wlr.SceneTree,
    transaction: *axiom_transaction.Transaction,

    interactive_layers: struct {
        outputs: *wlr.SceneTree,
        override_redirect: *wlr.SceneTree,
    },

    views: wl.list.Head(axiom_view.View, .link),

    new_output: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(newOutput),

    output_layout: *wlr.OutputLayout,
    layout_change: wl.Listener(*wlr.OutputLayout) = wl.Listener(*wlr.OutputLayout).init(handleLayoutChange),

    presentation: *wlr.Presentation,
    xdg_output_manager: *wlr.XdgOutputManagerV1,
    output_manager: *wlr.OutputManagerV1,

    power_manager: *wlr.OutputPowerManagerV1,
    gamma_control_manager: *wlr.GammaControlManagerV1,

    all_outputs: wl.list.Head(axiom_output.Output, .all_outputs_link),

    active_outputs: wl.list.Head(axiom_output.Output, .active_outputs_link),

    manager_apply: wl.Listener(*wlr.OutputConfigurationV1) =
        wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerApply),
    manager_test: wl.Listener(*wlr.OutputConfigurationV1) =
        wl.Listener(*wlr.OutputConfigurationV1).init(handleManagerTest),

    power_manager_set_mode: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) =
        wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode).init(handlePowerManagerSetMode),

    gamma_control_set_gamma: wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma) =
        wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma).init(handleSetGamma),

    pub fn init(root: *Root) !void {
        const output_layout = try wlr.OutputLayout.create(server.wl_server);
        errdefer output_layout.destroy();

        const scene = try wlr.Scene.create();
        errdefer scene.tree.node.destroy();

        const interactive_content = try scene.tree.createSceneTree();
        const drag_icons = try scene.tree.createSceneTree();

        const outputs = try interactive_content.createSceneTree();
        const override_redirect = try interactive_content.createSceneTree();

        const transaction = try gpa.create(axiom_transaction.Transaction);
        errdefer gpa.destroy(transaction);

        root.* = .{
            .server = server,
            .transaction = transaction,
            .scene = scene,
            .interactive_content = interactive_content,
            .drag_icons = drag_icons,
            .interactive_layers = .{
                .outputs = outputs,
                .override_redirect = override_redirect,
            },
            .views = undefined,
            .output_layout = output_layout,
            .all_outputs = undefined,
            .active_outputs = undefined,

            .presentation = try wlr.Presentation.create(server.wl_server, server.backend),
            .xdg_output_manager = try wlr.XdgOutputManagerV1.create(server.wl_server, output_layout),
            .output_manager = try wlr.OutputManagerV1.create(server.wl_server),
            .power_manager = try wlr.OutputPowerManagerV1.create(server.wl_server),
            .gamma_control_manager = try wlr.GammaControlManagerV1.create(server.wl_server),
        };

        root.views.init();
        root.all_outputs.init();
        root.active_outputs.init();
        try transaction.init();

        server.backend.events.new_output.add(&root.new_output);
        root.output_manager.events.apply.add(&root.manager_apply);
        root.output_manager.events.@"test".add(&root.manager_test);
        root.output_layout.events.change.add(&root.layout_change);
        root.power_manager.events.set_mode.add(&root.power_manager_set_mode);
        root.gamma_control_manager.events.set_gamma.add(&root.gamma_control_set_gamma);
    }

    pub const AtResult = struct {
        node: *wlr.SceneNode,
        surface: ?*wlr.Surface,
        sx: f64,
        sy: f64,
        data: AxiomData,
    };

    pub fn at(root: Root, lx: f64, ly: f64) ?AtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        const node = root.interactive_content.node.at(lx, ly, &sx, &sy) orelse return null;

        const surface: ?*wlr.Surface = blk: {
            if (node.type == .buffer) {
                const scene_buffer = wlr.SceneBuffer.fromNode(node);
                if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface| {
                    break :blk scene_surface.surface;
                }
            }
            break :blk null;
        };

        if (AxiomSceneNodeData.fromNode(node)) |scene_node_data| {
            return .{
                .node = node,
                .surface = surface,
                .sx = sx,
                .sy = sy,
                .data = scene_node_data.data,
            };
        } else {
            return null;
        }
    }

    fn handleLayoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
        const root: *Root = @fieldParentPtr("layout_change", listener);

        root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
    }

    pub fn newOutput(_: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        axiom_output.Output.create(wlr_output) catch |err| {
            switch (err) {
                error.OutOfMemory => std.log.err("out of memory", .{}),
                error.InitRenderFailed => std.log.err("failed to initialize renderer for output {s}", .{wlr_output.name}),
            }
            wlr_output.destroy();
            return;
        };

        server.root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
    }

    pub fn deactivateOutput(root: *Root, output: *axiom_output.Output) void {
        {
            // If the output has already been removed, do nothing
            var it = root.active_outputs.iterator(.forward);
            while (it.next()) |o| {
                if (o == output) break;
            } else return;
        }

        root.output_layout.remove(output.wlr_output);
        output.tree.node.setEnabled(false);

        output.active_outputs_link.remove();
        output.active_outputs_link.init();

        {
            var it = output.inflight.focus_stack.safeIterator(.forward);
            while (it.next()) |view| {
                view.inflight.output = null;
                view.current.output = null;

                view.tree.node.reparent(root.transaction.hidden.tree);
                view.popup_tree.node.reparent(root.transaction.hidden.tree);

                view.inflight_focus_stack_link.remove();
                view.inflight_focus_stack_link.init();

                //view.inflight_wm_stack_link.remove();
                //view.inflight_wm_stack_link.init();

                if (view.inflight_transaction) {
                    view.commitTransaction();
                }

                // Store outputs connector name so that views can be moved back to
                // reconnecting outputs. Skip if there is already a connector name
                // stored to better handle the case of multiple outputs being
                // removed sequentially.
                if (view.output_before_evac == null) {
                    const name = std.mem.span(output.wlr_output.name);
                    view.output_before_evac = gpa.dupe(u8, name) catch null;
                }
            }
        }

        const fallback_output = blk: {
            var it = root.active_outputs.iterator(.forward);
            break :blk it.next();
        };
        if (fallback_output) |fallback| {
            var it = output.pending.focus_stack.safeIterator(.reverse);
            while (it.next()) |view| view.setPendingOutput(fallback);
        } else {
            var it = output.pending.focus_stack.iterator(.forward);
            while (it.next()) |view| view.pending.output = null;
            root.transaction.fallback_state.focus_stack.prependList(&output.pending.focus_stack);
            //root.fallback_state.wm_stack.prependList(&output.pending.wm_stack);
            // Store the focused output tags if we are hotplugged down to
            // 0 real outputs so they can be restored on gaining a new output.
            root.transaction.fallback_state.tags = output.pending.tags;
        }

        // TODO: implement layer shell
        // for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
        //     const tree = output.layerSurfaceTree(layer);
        //     var it = tree.children.safeIterator(.forward);
        //     while (it.next()) |scene_node| {
        //         std.debug.assert(scene_node.type == .tree);
        //         if (@as(?*AxiomSceneNodeData, @ptrFromInt(scene_node.data))) |node_data| {
        //             node_data.data.layer_surface.wlr_layer_surface.destroy();
        //         }
        //     }
        // }

        // If any seat has the removed output focused, focus the fallback one

        const seat = root.server.seat;
        if (seat.focused_output == output) {
            seat.focusOutput(fallback_output);
        }

        //TODO: what does this do?
        // if (output.inflight.layout_demand) |layout_demand| {
        //     layout_demand.deinit();
        //     output.inflight.layout_demand = null;
        //     root.notifyLayoutDemandDone();
        // }

        //while (output.layouts.first) |node| node.data.destroy();

        //server.input_manager.reconfigureDevices();

    }

    pub fn activateOutput(root: *Root, output: *axiom_output.Output) void {
        {
            // If we have already added the output, do nothing and return
            var it = root.active_outputs.iterator(.forward);
            while (it.next()) |o| if (o == output) return;
        }

        const first = root.active_outputs.empty();

        root.active_outputs.append(output);

        _ = root.output_layout.addAuto(output.wlr_output) catch {
            std.log.err("failed to add output '{s}' ", .{output.wlr_output.name});
            root.deactivateOutput(output);
        };

        // If we previously had no outputs, move all views to the new output and focus it.
        if (first) {
            const log = std.log.scoped(.output_manager);
            log.debug("moving views from fallback stacks to new output", .{});

            output.pending.tags = root.transaction.fallback_state.tags;
            // {
            //     var it = root.fallback_state.wm_stack.safeIterator(.reverse);
            //     while (it.next()) |view| view.setPendingOutput(output);
            // }
            {
                // Focus the new output with all seats

                const seat = server.seat;
                seat.focusOutput(output);
            }
        } else {
            // Otherwise check if any views were previously evacuated from an output
            // with the same (connector-)name and move them back.
            var it = root.views.iterator(.forward);
            while (it.next()) |view| {
                const name = view.output_before_evac orelse continue;
                if (std.mem.eql(u8, name, std.mem.span(output.wlr_output.name))) {
                    if (view.pending.output != output) {
                        view.setPendingOutput(output);
                    }
                    gpa.free(name);
                    view.output_before_evac = null;
                }
            }
        }
        std.debug.assert(root.transaction.fallback_state.focus_stack.empty());
        //std.debug.assert(root.fallback_state.wm_stack.empty());

        // Enforce map-to-output configuration for the newly active output.
        // server.input_manager.reconfigureDevices();
    }

    fn processOutputConfig(
        root: *Root,
        config: *wlr.OutputConfigurationV1,
        action: enum { test_only, apply },
    ) void {
        // Ignore layout change events this function generates while applying the config

        //const server = root.server;
        root.layout_change.link.remove();
        defer root.output_layout.events.change.add(&root.layout_change);

        var success = true;

        var it = config.heads.iterator(.forward);
        while (it.next()) |head| {
            const wlr_output = head.state.output;
            const output: *axiom_output.Output = @ptrFromInt(wlr_output.data);

            var proposed_state = wlr.Output.State.init();
            head.state.apply(&proposed_state);

            if (head.state.x < 0 or head.state.y < 0) {
                std.log.err("Attempted to set negative coordinates for output {s}.", .{output.wlr_output.name});
                success = false;
                continue;
            }

            switch (action) {
                .test_only => {
                    if (!wlr_output.testState(&proposed_state)) success = false;
                },
                .apply => {
                    output.applyState(&proposed_state) catch {
                        std.log.scoped(.output_manager).err("failed to apply config to output {s}", .{
                            output.wlr_output.name,
                        });
                        success = false;
                    };
                    if (output.wlr_output.enabled) {
                        _ = root.output_layout.add(output.wlr_output, head.state.x, head.state.y) catch unreachable;
                    }
                },
            }
        }

        if (action == .apply) root.transaction.applyPending();

        if (success) {
            config.sendSucceeded();
        } else {
            config.sendFailed();
        }
    }

    pub fn handleOutputConfigChange(root: *Root) !void {
        const config = try wlr.OutputConfigurationV1.create();
        // this destroys all associated config heads as well
        errdefer config.destroy();

        var it = root.all_outputs.iterator(.forward);
        while (it.next()) |output| {
            // If the output is not part of the layout (and thus disabled)
            // the box will be zeroed out.
            var box: wlr.Box = undefined;
            root.output_layout.getBox(output.wlr_output, &box);

            output.tree.node.setEnabled(!box.empty());
            output.tree.node.setPosition(box.x, box.y);
            output.scene_output.setPosition(box.x, box.y);

            const head = try wlr.OutputConfigurationV1.Head.create(config, output.wlr_output);
            head.state.x = box.x;
            head.state.y = box.y;
        }

        root.output_manager.setConfiguration(config);
    }

    fn handleManagerApply(
        listener: *wl.Listener(*wlr.OutputConfigurationV1),
        config: *wlr.OutputConfigurationV1,
    ) void {
        const root: *Root = @fieldParentPtr("manager_apply", listener);
        defer config.destroy();

        std.log.info("applying output configuration", .{});

        root.processOutputConfig(config, .apply);

        root.handleOutputConfigChange() catch std.log.err("out of memory", .{});
    }

    fn handleManagerTest(
        listener: *wl.Listener(*wlr.OutputConfigurationV1),
        config: *wlr.OutputConfigurationV1,
    ) void {
        const root: *Root = @fieldParentPtr("manager_test", listener);
        defer config.destroy();

        root.processOutputConfig(config, .test_only);
    }

    fn handlePowerManagerSetMode(
        _: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode),
        event: *wlr.OutputPowerManagerV1.event.SetMode,
    ) void {
        const output = @as(?*axiom_output.Output, @ptrFromInt(event.output.data)) orelse return;

        std.log.debug("client requested dpms {s} for output {s}", .{
            @tagName(event.mode),
            event.output.name,
        });

        const requested = event.mode == .on;

        if (output.wlr_output.enabled == requested) {
            std.log.debug("output {s} dpms is already {s}, ignoring request", .{
                event.output.name,
                @tagName(event.mode),
            });
            return;
        }

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(requested);

        if (!output.wlr_output.commitState(&state)) {
            std.log.err("output commit failed for {s}", .{output.wlr_output.name});
            return;
        }

        //TODO: implement lock manager

        //output.updateLockRenderStateOnEnableDisable();
        output.gamma_dirty = true;
    }

    fn handleSetGamma(
        _: *wl.Listener(*wlr.GammaControlManagerV1.event.SetGamma),
        event: *wlr.GammaControlManagerV1.event.SetGamma,
    ) void {
        // The output may have been destroyed, in which case there is nothing to do
        const output = @as(?*axiom_output.Output, @ptrFromInt(event.output.data)) orelse return;

        std.log.debug("client requested to set gamma", .{});

        output.gamma_dirty = true;
        output.wlr_output.scheduleFrame();
    }
};
