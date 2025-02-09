const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const server = &@import("main.zig").server;
const wlr = @import("wlroots");
const axiom_seat = @import("seat.zig");
const gpa = @import("utils.zig").gpa;
const axiom_input_device = @import("input_device.zig");

pub const Keyboard = struct {
    seat: *axiom_seat.Seat,
    link: wl.list.Link = undefined,
    device: axiom_input_device.InputDevice,

    modifiers: wl.Listener(*wlr.Keyboard) = wl.Listener(*wlr.Keyboard).init(modifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = wl.Listener(*wlr.Keyboard.event.Key).init(key),

    // pub fn create(seat: axiom_seat.Seat, device: *wlr.InputDevice) !void {
    //     const keyboard = try gpa.create(Keyboard);
    //     errdefer gpa.destroy(keyboard);

    //     keyboard.* = .{
    //         .seat = seat,
    //         .device = device,
    //     };

    //     const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
    //     defer context.unref();
    //     const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
    //     defer keymap.unref();

    //     const wlr_keyboard = device.toKeyboard();

    //     wlr_keyboard.data = @intFromPtr(keyboard);
    //     if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
    //     wlr_keyboard.setRepeatInfo(25, 600);

    //     wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    //     wlr_keyboard.events.key.add(&keyboard.key);

    //     seat.seat.setKeyboard(wlr_keyboard);
    //     seat.keyboards.append(keyboard);
    // }

    pub fn init(keyboard: *Keyboard, seat: *axiom_seat.Seat, wlr_device: *wlr.InputDevice) !void {
        keyboard.* = .{
            .seat = seat,
            .device = undefined,
        };
        try keyboard.device.init(seat, wlr_device);
        errdefer keyboard.device.deinit();

        const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();
        wlr_keyboard.data = @intFromPtr(keyboard);

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 600);

        // wlroots will log a more detailed error if this fails.
        //if (!wlr_keyboard.setKeymap(server.config.keymap)) return error.OutOfMemory;

        // Add to keyboard-group, if applicable.
        // var group_it = seat.keyboard_groups.first;
        // outer: while (group_it) |group_node| : (group_it = group_node.next) {
        //     for (group_node.data.globs.items) |glob| {
        //         if (globber.match(glob, keyboard.device.identifier)) {
        //             // wlroots will log an error if this fails explaining the reason.
        //             _ = group_node.data.wlr_group.addKeyboard(wlr_keyboard);
        //             break :outer;
        //         }
        //     }
        // }

        //wlr_keyboard.setRepeatInfo(server.config.repeat_rate, server.config.repeat_delay);

        wlr_keyboard.events.key.add(&keyboard.key);
        wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    }

    pub fn deinit(keyboard: *Keyboard) void {
        keyboard.key.link.remove();
        keyboard.modifiers.link.remove();

        const seat = keyboard.device.seat;
        const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

        keyboard.device.deinit();

        // If the currently active keyboard of a seat is destroyed we need to set
        // a new active keyboard. Otherwise wlroots may send an enter event without
        // first having sent a keymap event if Seat.keyboardNotifyEnter() is called
        // before a new active keyboard is set.
        if (seat.seat.getKeyboard() == wlr_keyboard) {
            var it = server.input_manager.devices.iterator(.forward);
            while (it.next()) |device| {
                if (device.seat == seat and device.wlr_device.type == .keyboard) {
                    seat.seat.setKeyboard(device.wlr_device.toKeyboard());
                }
            }
        }

        keyboard.* = undefined;
    }

    pub fn modifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.seat.seat.setKeyboard(wlr_keyboard);
        keyboard.seat.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    pub fn key(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;

        var handled = false;

        if (wlr_keyboard.getModifiers().shift and event.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                if (keyboard.seat.handleKeybind(sym)) {
                    handled = true;
                    break;
                }
            }
        }

        if (!handled) {
            keyboard.seat.seat.setKeyboard(wlr_keyboard);
            keyboard.seat.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }
};
