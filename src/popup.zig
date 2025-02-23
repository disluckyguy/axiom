const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const axiom_view = @import("view.zig");
const AxiomSceneNodeData = @import("scene_node_data.zig").SceneNodeData;
const AxiomData = @import("scene_node_data.zig").Data;
const gpa = @import("utils.zig").gpa;

const server = &@import("main.zig").server;

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,

    scene_tree: *wlr.SceneTree,
    root_tree: *wlr.SceneTree,

    commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
    destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
    reposition: wl.Listener(void) = wl.Listener(void).init(handleReposition),

    pub fn create(
        xdg_popup: *wlr.XdgPopup,
        root: *wlr.SceneTree,
        parent: *wlr.SceneTree,
    ) error{OutOfMemory}!void {
        const popup = try gpa.create(Popup);
        errdefer gpa.destroy(popup);

        popup.* = .{
            .xdg_popup = xdg_popup,
            .root_tree = root,
            .scene_tree = try parent.createSceneXdgSurface(xdg_popup.base),
        };

        xdg_popup.events.destroy.add(&popup.destroy);
        xdg_popup.base.surface.events.commit.add(&popup.commit);
        xdg_popup.events.reposition.add(&popup.reposition);
    }

    pub fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (popup.xdg_popup.base.initial_commit) {
            handleReposition(&popup.reposition);
            _ = popup.xdg_popup.base.scheduleConfigure();
        }
    }

    pub fn handleDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);

        popup.commit.link.remove();
        popup.destroy.link.remove();

        gpa.destroy(popup);
    }

    fn handleReposition(listener: *wl.Listener(void)) void {
        std.log.info("repositioning", .{});
        const popup: *Popup = @fieldParentPtr("reposition", listener);
        const node_data: *AxiomSceneNodeData = @ptrFromInt(popup.root_tree.node.data);
        const view = node_data.data.view;

        const output = view.rootSurface().?.current_outputs.first().?.output;
        var box: wlr.Box = undefined;
        server.root.output_layout.getBox(output, &box);

        var root_lx: c_int = undefined;
        var root_ly: c_int = undefined;
        _ = popup.root_tree.node.coords(&root_lx, &root_ly);

        //std.log.info("{}", .{popup.scene_tree.node.x});

        box.x -= root_lx;
        box.y -= root_ly;

        //std.log.info("{}", .{box.y});
    }
};
