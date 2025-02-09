const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const zwlr = @import("wayland").server.zwlr;
const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_root = @import("root.zig");
const axiom_view = @import("view.zig");
const axiom_xwayland = @import("xwayland.zig");
const axiom_keyboard = @import("keyboard.zig");
const axiom_cursor = @import("cursor.zig");
const axiom_output = @import("output.zig");
const AxiomSceneNodeData = @import("scene_node_data.zig").SceneNodeData;
const AxiomData = @import("scene_node_data.zig").Data;

const server = &@import("main.zig").server;

pub const Transaction = struct {
    hidden: struct {
        /// This tree is always disabled.
        tree: *wlr.SceneTree,

        pending: struct {
            focus_stack: wl.list.Head(axiom_view.View, .pending_focus_stack_link),
            //wm_stack: wl.list.Head(axiom_view.View, .pending_wm_stack_link),
        },

        inflight: struct {
            focus_stack: wl.list.Head(axiom_view.View, .inflight_focus_stack_link),
            //wm_stack: wl.list.Head(axiom_view.View, .inflight_wm_stack_link),
        },
    },

    fallback_state: axiom_output.PendingState,

    inflight_layout_demands: u32 = 0,
    inflight_configures: u32 = 0,
    transaction_timeout: *wl.EventSource,
    pending_state_dirty: bool = false,

    pub fn init(transaction: *Transaction) !void {
        const hidden_tree = try server.root.scene.tree.createSceneTree();
        hidden_tree.node.setEnabled(false);

        const event_loop = server.wl_server.getEventLoop();

        const transaction_timeout = try event_loop.addTimer(*Transaction, handleTransactionTimeout, transaction);
        errdefer transaction_timeout.remove();

        transaction.* = .{
            .hidden = .{
                .tree = hidden_tree,
                .pending = .{
                    .focus_stack = undefined,
                    //.wm_stack = undefined,
                },
                .inflight = .{
                    .focus_stack = undefined,
                    //.wm_stack = undefined,
                },
            },
            .fallback_state = .{
                .focus_stack = undefined,
                //.wm_stack = undefined,
            },
            .transaction_timeout = transaction_timeout,
        };

        transaction.hidden.pending.focus_stack.init();
        //transaction.hidden.pending.wm_stack.init();
        transaction.hidden.inflight.focus_stack.init();
        //transaction.hidden.inflight.wm_stack.init();

        transaction.fallback_state.focus_stack.init();
        //transaction.fallback_state.wm_stack.init();
    }

    pub fn applyPending(transaction: *Transaction) void {
        {
            // Changes to the pending state may require a focus update to keep
            // state consistent. Instead of having focus(null) calls spread all
            // around the codebase and risk forgetting one, always ensure focus
            // state is synchronized here.
            var it = server.input_manager.seats.first;
            while (it) |node| : (it = node.next) node.data.focus(null);
        }

        // If there is already a transaction inflight, wait until it completes.
        if (transaction.inflight_layout_demands > 0 or transaction.inflight_configures > 0) {
            transaction.pending_state_dirty = true;
            return;
        }

        transaction.pending_state_dirty = false;

        {
            var it = transaction.hidden.pending.focus_stack.iterator(.forward);
            while (it.next()) |view| {
                std.debug.assert(view.pending.output == null);
                view.inflight.output = null;
                view.inflight_focus_stack_link.remove();
                transaction.hidden.inflight.focus_stack.append(view);
            }
        }

        // {
        //     var it = transaction.hidden.pending.wm_stack.iterator(.forward);
        //     while (it.next()) |view| {
        //         //view.inflight_wm_stack_link.remove();
        //         transaction.hidden.inflight.wm_stack.append(view);
        //     }
        // }

        {
            var output_it = server.root.active_outputs.iterator(.forward);
            while (output_it.next()) |output| {
                // Iterate the focus stack in order to ensure the currently focused/most
                // recently focused view that requests fullscreen is given fullscreen.
                output.inflight.fullscreen = null;
                {
                    var it = output.pending.focus_stack.iterator(.forward);

                    //if (output.pending.focus_stack.empty()) server.seat.focus(null);
                    while (it.next()) |view| {
                        std.debug.assert(view.pending.output == output);

                        // if (view.current.float and !view.pending.float) {
                        //     // If switching from float to non-float, save the dimensions.
                        //     view.float_box = view.current.box;
                        // } else if (!view.current.float and view.pending.float) {
                        //     // If switching from non-float to float, apply the saved float dimensions.
                        //     view.pending.box = view.float_box;
                        //     //view.pending.clampToOutput();
                        // }

                        if (!view.current.fullscreen and view.pending.fullscreen) {
                            view.post_fullscreen_box = view.pending.box;
                            view.pending.box = .{ .x = 0, .y = 0, .width = undefined, .height = undefined };
                            output.wlr_output.effectiveResolution(&view.pending.box.width, &view.pending.box.height);
                        } else if (view.current.fullscreen and !view.pending.fullscreen) {
                            view.pending.box = view.post_fullscreen_box;
                            //view.pending.clampToOutput();
                        }

                        if (output.inflight.fullscreen == null and view.pending.fullscreen and
                            view.pending.tags & output.pending.tags != 0)
                        {
                            output.inflight.fullscreen = view;
                        }

                        view.inflight_focus_stack_link.remove();
                        output.inflight.focus_stack.append(view);

                        view.inflight = view.pending;
                    }
                }

                // {
                //     var it = output.pending.wm_stack.iterator(.forward);
                //     while (it.next()) |view| {
                //         view.inflight_wm_stack_link.remove();
                //         output.inflight.wm_stack.append(view);
                //     }
                // }

                output.inflight.tags = output.pending.tags;
            }
        }

        // {
        //     // Layout demands can't be sent until after the inflight stacks of
        //     // all outputs have been updated.
        //     var output_it = server.root.active_outputs.iterator(.forward);
        //     while (output_it.next()) |output| {
        //         std.debug.assert(output.inflight.layout_demand == null);
        //         if (output.layout) |layout| {
        //             var layout_count: u32 = 0;
        //             {
        //                 var it = output.inflight.wm_stack.iterator(.forward);
        //                 while (it.next()) |view| {
        //                     if (!view.inflight.float and !view.inflight.fullscreen and
        //                         view.inflight.tags & output.inflight.tags != 0)
        //                     {
        //                         layout_count += 1;
        //                     }
        //                 }
        //             }

        //             if (layout_count > 0) {
        //                 // TODO don't do this if the count has not changed
        //                 layout.startLayoutDemand(layout_count);
        //             }
        //         }
        //     }
        // }

        // {
        //     const seat = server.seat;
        //     const cursor = seat.cursor;

        //     switch (cursor.current_mode) {
        //         .passthrough => {},
        //         inline .move, .resize => |data| {
        //             if (data.view.inflight.output == null or
        //                 data.view.inflight.tags & data.view.inflight.output.?.inflight.tags == 0 or
        //                 (!data.view.inflight.float) or
        //                 data.view.inflight.fullscreen)
        //             {
        //                 cursor.current_mode = .passthrough;
        //                 data.view.pending.resizing = false;
        //                 data.view.inflight.resizing = false;
        //             }
        //         },
        //     }

        //     cursor.inflight_mode = cursor.current_mode;
        // }

        var it = server.input_manager.seats.first;
        while (it) |node| : (it = node.next) {
            const cursor = &node.data.cursor;

            switch (cursor.current_mode) {
                .passthrough => {}, //.passthrough, .down => {},
                inline .move, .resize => |data| {
                    if (data.view.inflight.output == null or
                        data.view.inflight.tags & data.view.inflight.output.?.inflight.tags == 0 or
                        //(!data.view.inflight.float and data.view.inflight.output.?.layout != null) or
                        data.view.inflight.fullscreen)
                    {
                        cursor.current_mode = .passthrough;
                        data.view.pending.resizing = false;
                        data.view.inflight.resizing = false;
                    }
                },
            }

            cursor.inflight_mode = cursor.current_mode;
        }
        if (transaction.inflight_layout_demands == 0) {
            transaction.sendConfigures();
        }
    }

    fn commit(transaction: *Transaction) void {
        std.debug.assert(transaction.inflight_layout_demands == 0);
        std.debug.assert(transaction.inflight_configures == 0);

        {
            var it = transaction.hidden.inflight.focus_stack.safeIterator(.forward);
            while (it.next()) |view| {
                std.debug.assert(view.inflight.output == null);
                view.current.output = null;

                view.tree.node.reparent(transaction.hidden.tree);
                view.popup_tree.node.reparent(transaction.hidden.tree);
            }
        }

        var output_it = server.root.active_outputs.iterator(.forward);
        while (output_it.next()) |output| {
            if (output.inflight.tags != output.current.tags) {
                std.log.scoped(.output).debug(
                    "changing current focus: {b:0>10} to {b:0>10}",
                    .{ output.current.tags, output.inflight.tags },
                );
            }
            output.current.tags = output.inflight.tags;

            var focus_stack_it = output.inflight.focus_stack.iterator(.forward);

            while (focus_stack_it.next()) |view| {
                std.debug.assert(view.inflight.output == output);

                if (view.inflight.float) {
                    view.tree.node.reparent(output.layers.float);
                } else {
                    view.tree.node.reparent(output.layers.layout);
                }
                view.popup_tree.node.reparent(output.layers.popups);

                view.commitTransaction();

                const enabled = view.current.tags & output.current.tags != 0;
                view.tree.node.setEnabled(enabled);
                view.popup_tree.node.setEnabled(enabled);
                if (output.inflight.fullscreen != view) {
                    view.tree.node.lowerToBottom();
                }
            }

            if (output.inflight.fullscreen) |view| {
                std.debug.assert(view.inflight.output == output);
                std.debug.assert(view.current.output == output);
                view.tree.node.reparent(output.layers.fullscreen);
            }
            output.current.fullscreen = output.inflight.fullscreen;
            output.layers.fullscreen.node.setEnabled(output.current.fullscreen != null);

            //output.status.handleTransactionCommit(output);
        }

        // {
        //     var it = server.input_manager.seats.first;
        //     while (it) |node| : (it = node.next) node.data.cursor.updateState();
        // }

        {
            // This must be done after updating cursor state in case the view was the target of move/resize.
            var it = transaction.hidden.inflight.focus_stack.safeIterator(.forward);
            while (it.next()) |view| {
                view.dropSavedSurfaceTree();
                if (view.destroying) view.destroy(.assert);
            }
        }

        //server.idle_inhibit_manager.checkActive();

        if (transaction.pending_state_dirty) {
            transaction.applyPending();
        }
    }

    pub fn notifyLayoutDemandDone(transaction: *Transaction) void {
        transaction.inflight_layout_demands -= 1;
        if (transaction.inflight_layout_demands == 0) {
            transaction.sendConfigures();
        }
    }

    fn sendConfigures(transaction: *Transaction) void {
        std.debug.assert(transaction.inflight_layout_demands == 0);
        std.debug.assert(transaction.inflight_configures == 0);

        // Iterate over all views of all outputs
        var output_it = server.root.active_outputs.iterator(.forward);
        while (output_it.next()) |output| {
            var focus_stack_it = output.inflight.focus_stack.iterator(.forward);
            while (focus_stack_it.next()) |view| {
                std.debug.assert(!view.inflight_transaction);
                view.inflight_transaction = true;

                // This can happen if a view is unmapped while a layout demand including it is inflight
                // If a view has been unmapped, don't send it a configure.
                if (!view.mapped) continue;

                if (view.configure()) {
                    transaction.inflight_configures += 1;

                    view.saveSurfaceTree();
                    view.sendFrameDone();
                }
            }
        }

        if (transaction.inflight_configures > 0) {
            std.log.scoped(.transaction).debug("started transaction with {} pending configure(s)", .{
                transaction.inflight_configures,
            });

            transaction.transaction_timeout.timerUpdate(100) catch {
                std.log.scoped(.transaction).err("failed to update timer", .{});
                transaction.commit();
            };
        } else {
            transaction.commit();
        }
    }

    pub fn notifyConfigured(transaction: *Transaction) void {
        std.debug.assert(transaction.inflight_layout_demands == 0);

        transaction.inflight_configures -= 1;
        if (transaction.inflight_configures == 0) {
            transaction.transaction_timeout.timerUpdate(0) catch std.log.err("error disarming timer", .{});
            transaction.commit();
        }
    }

    fn handleTransactionTimeout(transaction: *Transaction) c_int {
        std.debug.assert(transaction.inflight_layout_demands == 0);

        std.log.err("transaction timeout", .{});

        transaction.inflight_configures = 0;
        transaction.commit();

        return 0;
    }
};
