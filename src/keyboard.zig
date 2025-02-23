const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const server = &@import("main.zig").server;
const wlr = @import("wlroots");
const Seat = @import("seat.zig").Seat;
const gpa = @import("utils.zig").gpa;
const InputDevice = @import("input_device.zig").InputDevice;

pub const Keyboard = struct {
    seat: *Seat,
    link: wl.list.Link = undefined,
    device: InputDevice,

    modifiers: wl.Listener(*wlr.Keyboard) = wl.Listener(*wlr.Keyboard).init(handleModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = wl.Listener(*wlr.Keyboard.event.Key).init(handleKey),

    pub fn init(keyboard: *Keyboard, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
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
        if (seat.wlr_seat.getKeyboard() == wlr_keyboard) {
            var it = server.input_manager.devices.iterator(.forward);
            while (it.next()) |device| {
                if (device.seat == seat and device.wlr_device.type == .keyboard) {
                    seat.wlr_seat.setKeyboard(device.wlr_device.toKeyboard());
                }
            }
        }

        keyboard.* = undefined;
    }

    pub fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.seat.wlr_seat.setKeyboard(wlr_keyboard);
        keyboard.seat.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_keyboard = keyboard.device.wlr_device.toKeyboard();

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;

        var handled = false;

        std.debug.print("modifiers {} \n", .{wlr_keyboard.getModifiers()});

        if (wlr_keyboard.getModifiers().logo and event.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                if (keyboard.seat.handleKeybind(sym)) {
                    handled = true;
                    break;
                }
            }
        }

        if (!handled) {
            keyboard.seat.wlr_seat.setKeyboard(wlr_keyboard);
            keyboard.seat.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }
};
