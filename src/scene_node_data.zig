const build_options = @import("build_options");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const gpa = @import("utils.zig").gpa;

const View = @import("view.zig").View;
const XwaylandView = @import("xwayland.zig").XwaylandView;
const XwaylandOverrideRedirect = @import("xwayland.zig").XwaylandOverrideRedirect;

pub const SceneData = union(enum) {
    view: *View,
    // TODO: implement lock and layer surface
    // lock_surface: *LockSurface,
    // layer_surface: *LayerSurface,
    override_redirect: *XwaylandOverrideRedirect,
};

pub const SceneNodeData = struct {
    node: *wlr.SceneNode,
    data: SceneData,
    destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),

    pub fn attach(node: *wlr.SceneNode, data: SceneData) error{OutOfMemory}!void {
        const scene_node_data = try gpa.create(SceneNodeData);

        scene_node_data.* = .{
            .node = node,
            .data = data,
        };
        node.data = @intFromPtr(scene_node_data);

        node.events.destroy.add(&scene_node_data.destroy);
    }

    pub fn fromNode(node: *wlr.SceneNode) ?*SceneNodeData {
        var n = node;
        while (true) {
            if (@as(?*SceneNodeData, @ptrFromInt(n.data))) |scene_node_data| {
                return scene_node_data;
            }
            if (n.parent) |parent_tree| {
                n = &parent_tree.node;
            } else {
                return null;
            }
        }
    }

    pub fn fromSurface(surface: *wlr.Surface) ?*SceneNodeData {
        if (@as(?*wlr.SceneNode, @ptrFromInt(surface.getRootSurface().data))) |node| {
            return fromNode(node);
        }
        return null;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const scene_node_data: *SceneNodeData = @fieldParentPtr("destroy", listener);

        scene_node_data.destroy.link.remove();
        scene_node_data.node.data = 0;

        gpa.destroy(scene_node_data);
    }
};
