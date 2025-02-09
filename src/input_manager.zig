const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const globber = @import("globber");

const server = &@import("main.zig").server;
const util = @import("utils.zig");

const axiom_input_config = @import("input_config.zig");
const axiom_input_device = @import("input_device.zig");
const axiom_input_relay = @import("input_relay.zig");
const Keyboard = @import("keyboard.zig");
//const PointerConstraint = @import("PointerConstraint.zig");
const axiom_seat = @import("seat.zig");
//const Switch = @import("Switch.zig");
const axiom_text_input = @import("text_input.zig");

const default_seat_name = "default";

const log = std.log;

pub const InputManager = struct {
    new_input: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleNewInput),

    idle_notifier: *wlr.IdleNotifierV1,
    // relative_pointer_manager: *wlr.RelativePointerManagerV1,
    // pointer_gestures: *wlr.PointerGesturesV1,
    virtual_pointer_manager: *wlr.VirtualPointerManagerV1,
    virtual_keyboard_manager: *wlr.VirtualKeyboardManagerV1,
    //pointer_constraints: *wlr.PointerConstraintsV1,
    input_method_manager: *wlr.InputMethodManagerV2,
    text_input_manager: *wlr.TextInputManagerV3,
    tablet_manager: *wlr.TabletManagerV2,

    /// List of input device configurations. Ordered by glob generality, with
    /// the most general towards the start and the most specific towards the end.
    configs: std.ArrayList(axiom_input_config.InputConfig),

    devices: wl.list.Head(axiom_input_device.InputDevice, .link),
    seats: std.TailQueue(axiom_seat.Seat) = .{},

    exclusive_client: ?*wl.Client = null,

    new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) =
        wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer).init(handleNewVirtualPointer),
    new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) =
        wl.Listener(*wlr.VirtualKeyboardV1).init(handleNewVirtualKeyboard),
    // new_constraint: wl.Listener(*wlr.PointerConstraintV1) =
    //     wl.Listener(*wlr.PointerConstraintV1).init(handleNewConstraint),
    new_input_method: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleNewInputMethod),
    new_text_input: wl.Listener(*wlr.TextInputV3) =
        wl.Listener(*wlr.TextInputV3).init(handleNewTextInput),

    pub fn init(input_manager: *InputManager) !void {
        const seat_node = try util.gpa.create(std.TailQueue(axiom_seat.Seat).Node);
        errdefer util.gpa.destroy(seat_node);

        input_manager.* = .{
            // These are automatically freed when the display is destroyed
            .idle_notifier = try wlr.IdleNotifierV1.create(server.wl_server),
            //.relative_pointer_manager = try wlr.RelativePointerManagerV1.create(server.wl_server),
            //.pointer_gestures = try wlr.PointerGesturesV1.create(server.wl_server),
            .virtual_pointer_manager = try wlr.VirtualPointerManagerV1.create(server.wl_server),
            .virtual_keyboard_manager = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
            //.pointer_constraints = try wlr.PointerConstraintsV1.create(server.wl_server),
            .input_method_manager = try wlr.InputMethodManagerV2.create(server.wl_server),
            .text_input_manager = try wlr.TextInputManagerV3.create(server.wl_server),
            .tablet_manager = try wlr.TabletManagerV2.create(server.wl_server),
            .configs = std.ArrayList(axiom_input_config.InputConfig).init(util.gpa),

            .devices = undefined,
        };
        input_manager.devices.init();

        input_manager.seats.prepend(seat_node);
        try seat_node.data.init(default_seat_name);
        server.xwayland.setSeat(input_manager.defaultSeat().seat);

        server.backend.events.new_input.add(&input_manager.new_input);
        input_manager.virtual_pointer_manager.events.new_virtual_pointer.add(&input_manager.new_virtual_pointer);
        input_manager.virtual_keyboard_manager.events.new_virtual_keyboard.add(&input_manager.new_virtual_keyboard);
        //input_manager.pointer_constraints.events.new_constraint.add(&input_manager.new_constraint);
        input_manager.input_method_manager.events.input_method.add(&input_manager.new_input_method);
        input_manager.text_input_manager.events.text_input.add(&input_manager.new_text_input);
    }

    pub fn deinit(input_manager: *InputManager) void {
        // This function must be called after the backend has been destroyed
        assert(input_manager.devices.empty());

        input_manager.new_virtual_pointer.link.remove();
        input_manager.new_virtual_keyboard.link.remove();
        //input_manager.new_constraint.link.remove();
        input_manager.new_input_method.link.remove();
        input_manager.new_text_input.link.remove();

        while (input_manager.seats.pop()) |seat_node| {
            seat_node.data.deinit();
            util.gpa.destroy(seat_node);
        }

        for (input_manager.configs.items) |*config| {
            config.deinit();
        }
        input_manager.configs.deinit();
    }

    pub fn defaultSeat(input_manager: InputManager) *axiom_seat.Seat {
        return &input_manager.seats.first.?.data;
    }

    /// Returns true if input is currently allowed on the passed surface.
    pub fn inputAllowed(input_manager: InputManager, wlr_surface: *wlr.Surface) bool {
        return if (input_manager.exclusive_client) |exclusive_client|
            exclusive_client == wlr_surface.resource.getClient()
        else
            true;
    }

    /// Reconfigures all devices' libinput configuration as well as their output mapping.
    /// This is called on outputs being added or removed and on the input configuration being changed.
    pub fn reconfigureDevices(input_manager: *InputManager) void {
        var it = input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            for (input_manager.configs.items) |config| {
                if (globber.match(device.identifier, config.glob)) {
                    config.apply(device);
                }
            }
        }
    }

    fn handleNewInput(listener: *wl.Listener(*wlr.InputDevice), wlr_device: *wlr.InputDevice) void {
        const input_manager: *InputManager = @fieldParentPtr("new_input", listener);
        input_manager.defaultSeat().addDevice(wlr_device);
    }

    fn handleNewVirtualPointer(
        listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer),
        event: *wlr.VirtualPointerManagerV1.event.NewPointer,
    ) void {
        const input_manager: *InputManager = @fieldParentPtr("new_virtual_pointer", listener);

        // TODO Support multiple seats and don't ignore
        if (event.suggested_seat != null) {
            log.debug("Ignoring seat suggestion from virtual pointer", .{});
        }
        // TODO dont ignore output suggestion
        if (event.suggested_output != null) {
            log.debug("Ignoring output suggestion from virtual pointer", .{});
        }

        input_manager.defaultSeat().addDevice(&event.new_pointer.pointer.base);
    }

    fn handleNewVirtualKeyboard(
        _: *wl.Listener(*wlr.VirtualKeyboardV1),
        virtual_keyboard: *wlr.VirtualKeyboardV1,
    ) void {
        const seat: *axiom_seat.Seat = @ptrFromInt(virtual_keyboard.seat.data);
        seat.addDevice(&virtual_keyboard.keyboard.base);
    }

    // fn handleNewConstraint(
    //     _: *wl.Listener(*wlr.PointerConstraintV1),
    //     _: *wlr.PointerConstraintsV1, // wlr_constraint: *wlr.PointerConstraintV1,
    // ) void {
    // PointerConstraint.create(wlr_constraint) catch {
    //     log.err("out of memory", .{});
    //     wlr_constraint.resource.postNoMemory();
    // };
    //}

    fn handleNewInputMethod(_: *wl.Listener(*wlr.InputMethodV2), input_method: *wlr.InputMethodV2) void {
        const seat: *axiom_seat.Seat = @ptrFromInt(input_method.seat.data);

        log.debug("new input method on seat {s}", .{seat.seat.name});

        seat.relay.newInputMethod(input_method);
    }

    fn handleNewTextInput(_: *wl.Listener(*wlr.TextInputV3), wlr_text_input: *wlr.TextInputV3) void {
        axiom_text_input.TextInput.create(wlr_text_input) catch {
            log.err("out of memory", .{});
            wlr_text_input.resource.postNoMemory();
            return;
        };
    }
};
