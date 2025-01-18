const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");
const pixman = @import("pixman");

const wlr = @import("wlroots");
const axiom_server = @import("server.zig");
const gpa = @import("utils.zig").gpa;

pub const Keyboard = struct {
    server: *axiom_server.Server,
    link: wl.list.Link = undefined,
    device: *wlr.InputDevice,

    modifiers: wl.Listener(*wlr.Keyboard) = wl.Listener(*wlr.Keyboard).init(modifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = wl.Listener(*wlr.Keyboard.event.Key).init(key),

    pub fn create(server: *axiom_server.Server, device: *wlr.InputDevice) !void {
        const keyboard = try gpa.create(Keyboard);
        errdefer gpa.destroy(keyboard);

        keyboard.* = .{
            .server = server,
            .device = device,
        };

        const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
        defer context.unref();
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
        defer keymap.unref();

        const wlr_keyboard = device.toKeyboard();

        wlr_keyboard.data = @intFromPtr(keyboard);
        if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_keyboard.setRepeatInfo(25, 600);

        wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
        wlr_keyboard.events.key.add(&keyboard.key);

        server.seat.seat.setKeyboard(wlr_keyboard);
        server.seat.keyboards.append(keyboard);
    }

    pub fn modifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
        const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
        keyboard.server.seat.seat.setKeyboard(wlr_keyboard);
        keyboard.server.seat.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
    }

    pub fn key(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const keyboard: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_keyboard = keyboard.device.toKeyboard();

        // Translate libinput keycode -> xkbcommon
        const keycode = event.keycode + 8;

        var handled = false;

        if (wlr_keyboard.getModifiers().shift and event.state == .pressed) {
            for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
                if (keyboard.server.seat.handleKeybind(sym)) {
                    handled = true;
                    break;
                }
            }
        }

        if (!handled) {
            keyboard.server.seat.seat.setKeyboard(wlr_keyboard);
            keyboard.server.seat.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }
};
