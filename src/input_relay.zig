const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("utils.zig");

const axiom_text_input = @import("text_input.zig");
const axiom_input_popup = @import("input_popup.zig");
const axiom_seat = @import("seat.zig");

const log = std.log;

/// List of all text input objects for the seat.
/// Multiple text input objects may be created per seat, even multiple from the same client.
/// However, only one text input per seat may be enabled at a time.
pub const InputRelay = struct {
    text_inputs: wl.list.Head(axiom_text_input.TextInput, .link),

    /// The input method currently in use for this seat.
    /// Only one input method per seat may be used at a time and if one is
    /// already in use new input methods are ignored.
    /// If this is null, no text input enter events will be sent.
    input_method: ?*wlr.InputMethodV2 = null,
    input_popups: wl.list.Head(axiom_input_popup.InputPopup, .link),
    /// The currently enabled text input for the currently focused surface.
    /// Always null if there is no input method.
    text_input: ?*axiom_text_input.TextInput = null,

    input_method_commit: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodCommit),
    grab_keyboard: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboard),
    input_method_destroy: wl.Listener(*wlr.InputMethodV2) =
        wl.Listener(*wlr.InputMethodV2).init(handleInputMethodDestroy),
    input_method_new_popup: wl.Listener(*wlr.InputPopupSurfaceV2) =
        wl.Listener(*wlr.InputPopupSurfaceV2).init(handleInputMethodNewPopup),

    grab_keyboard_destroy: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) =
        wl.Listener(*wlr.InputMethodV2.KeyboardGrab).init(handleInputMethodGrabKeyboardDestroy),

    pub fn init(relay: *InputRelay) void {
        relay.* = .{ .text_inputs = undefined, .input_popups = undefined };

        relay.text_inputs.init();
        relay.input_popups.init();
    }

    pub fn newInputMethod(relay: *InputRelay, input_method: *wlr.InputMethodV2) void {
        const seat: *axiom_seat.Seat = @fieldParentPtr("relay", relay);

        log.debug("new input method on seat {s}", .{seat.seat.name});

        // Only one input_method can be bound to a seat.
        if (relay.input_method != null) {
            log.info("seat {s} already has an input method", .{seat.seat.name});
            input_method.sendUnavailable();
            return;
        }

        relay.input_method = input_method;

        input_method.events.commit.add(&relay.input_method_commit);
        input_method.events.grab_keyboard.add(&relay.grab_keyboard);
        input_method.events.destroy.add(&relay.input_method_destroy);
        input_method.events.new_popup_surface.add(&relay.input_method_new_popup);

        if (seat.focused.surface()) |surface| {
            relay.focus(surface);
        }
    }

    fn handleInputMethodCommit(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const relay: *InputRelay = @fieldParentPtr("input_method_commit", listener);
        assert(input_method == relay.input_method);

        if (!input_method.client_active) return;
        const text_input = relay.text_input orelse return;

        if (input_method.current.preedit.text) |preedit_text| {
            text_input.wlr_text_input.sendPreeditString(
                preedit_text,
                input_method.current.preedit.cursor_begin,
                input_method.current.preedit.cursor_end,
            );
        }

        if (input_method.current.commit_text) |commit_text| {
            text_input.wlr_text_input.sendCommitString(commit_text);
        }

        if (input_method.current.delete.before_length != 0 or
            input_method.current.delete.after_length != 0)
        {
            text_input.wlr_text_input.sendDeleteSurroundingText(
                input_method.current.delete.before_length,
                input_method.current.delete.after_length,
            );
        }

        text_input.wlr_text_input.sendDone();
    }

    fn handleInputMethodDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2),
        input_method: *wlr.InputMethodV2,
    ) void {
        const relay: *InputRelay = @fieldParentPtr("input_method_destroy", listener);
        assert(input_method == relay.input_method);

        relay.input_method_commit.link.remove();
        relay.grab_keyboard.link.remove();
        relay.input_method_destroy.link.remove();
        relay.input_method_new_popup.link.remove();
        relay.input_method = null;

        relay.focus(null);

        assert(relay.text_input == null);
    }

    fn handleInputMethodGrabKeyboard(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const relay: *InputRelay = @fieldParentPtr("grab_keyboard", listener);
        const seat: *axiom_seat.Seat = @fieldParentPtr("relay", relay);

        const active_keyboard = seat.seat.getKeyboard();
        keyboard_grab.setKeyboard(active_keyboard);

        keyboard_grab.events.destroy.add(&relay.grab_keyboard_destroy);
    }

    fn handleInputMethodNewPopup(
        listener: *wl.Listener(*wlr.InputPopupSurfaceV2),
        wlr_popup: *wlr.InputPopupSurfaceV2,
    ) void {
        const relay: *InputRelay = @fieldParentPtr("input_method_new_popup", listener);

        axiom_input_popup.InputPopup.create(wlr_popup, relay) catch {
            log.err("out of memory", .{});
            return;
        };
    }

    fn handleInputMethodGrabKeyboardDestroy(
        listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
        keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
    ) void {
        const relay: *InputRelay = @fieldParentPtr("grab_keyboard_destroy", listener);
        relay.grab_keyboard_destroy.link.remove();

        if (keyboard_grab.keyboard) |keyboard| {
            keyboard_grab.input_method.seat.keyboardNotifyModifiers(&keyboard.modifiers);
        }
    }

    pub fn disableTextInput(relay: *InputRelay) void {
        assert(relay.text_input != null);
        relay.text_input = null;

        if (relay.input_method) |input_method| {
            {
                var it = relay.input_popups.iterator(.forward);
                while (it.next()) |popup| popup.update();
            }
            input_method.sendDeactivate();
            input_method.sendDone();
        }
    }

    pub fn sendInputMethodState(relay: *InputRelay) void {
        const input_method = relay.input_method.?;
        const wlr_text_input = relay.text_input.?.wlr_text_input;

        // TODO Send these events only if something changed.
        // On activation all events must be sent for all active features.

        if (wlr_text_input.active_features.surrounding_text) {
            if (wlr_text_input.current.surrounding.text) |text| {
                input_method.sendSurroundingText(
                    text,
                    wlr_text_input.current.surrounding.cursor,
                    wlr_text_input.current.surrounding.anchor,
                );
            }
        }

        input_method.sendTextChangeCause(wlr_text_input.current.text_change_cause);

        if (wlr_text_input.active_features.content_type) {
            input_method.sendContentType(
                wlr_text_input.current.content_type.hint,
                wlr_text_input.current.content_type.purpose,
            );
        }

        {
            var it = relay.input_popups.iterator(.forward);
            while (it.next()) |popup| popup.update();
        }

        input_method.sendDone();
    }

    pub fn focus(relay: *InputRelay, new_focus: ?*wlr.Surface) void {
        // Send leave events
        {
            var it = relay.text_inputs.iterator(.forward);
            while (it.next()) |text_input| {
                if (text_input.wlr_text_input.focused_surface) |surface| {
                    // This function should not be called unless focus changes
                    assert(surface != new_focus);
                    text_input.wlr_text_input.sendLeave();
                }
            }
        }

        // Clear currently enabled text input
        if (relay.text_input != null) {
            relay.disableTextInput();
        }

        // Send enter events if we have an input method.
        // No text input for the new surface should be enabled yet as the client
        // should wait until it receives an enter event.
        if (new_focus) |surface| {
            if (relay.input_method != null) {
                var it = relay.text_inputs.iterator(.forward);
                while (it.next()) |text_input| {
                    if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                        text_input.wlr_text_input.sendEnter(surface);
                    }
                }
            }
        }
    }
};
