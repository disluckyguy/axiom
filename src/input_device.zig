const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const c = @import("c.zig");
const server = &@import("main.zig").server;
const utils = @import("utils.zig");

const Seat = @import("seat.zig").Seat;
const Keyboard = @import("keyboard.zig").Keyboard;
//const Switch = @import("Switch.zig");
//const Tablet = @import("Tablet.zig");

const log = std.log;

pub const InputDevice = struct {
    seat: *Seat,
    wlr_device: *wlr.InputDevice,

    destroy: wl.Listener(*wlr.InputDevice) = wl.Listener(*wlr.InputDevice).init(handleDestroy),

    /// Careful: The identifier is not unique! A physical input device may have
    /// multiple logical input devices with the exact same vendor id, product id
    /// and name. However identifiers of InputConfigs are unique.
    identifier: []const u8,

    config: struct {
        scroll_factor: f32 = 1.0,
    } = .{},

    /// InputManager.devices
    link: wl.list.Link,

    pub fn init(device: *InputDevice, seat: *Seat, wlr_device: *wlr.InputDevice) !void {
        var vendor: c_uint = 0;
        var product: c_uint = 0;

        if (wlr_device.getLibinputDevice()) |d| {
            vendor = c.libinput_device_get_id_vendor(@ptrCast(d));
            product = c.libinput_device_get_id_product(@ptrCast(d));
        }

        const identifier = try std.fmt.allocPrint(
            utils.gpa,
            "{s}-{}-{}-{s}",
            .{
                @tagName(wlr_device.type),
                vendor,
                product,
                mem.trim(u8, mem.sliceTo(wlr_device.name orelse "unknown", 0), &ascii.whitespace),
            },
        );
        errdefer utils.gpa.free(identifier);

        for (identifier) |*char| {
            if (!ascii.isPrint(char.*) or ascii.isWhitespace(char.*)) {
                char.* = '_';
            }
        }

        device.* = .{
            .seat = seat,
            .wlr_device = wlr_device,
            .identifier = identifier,
            .link = undefined,
        };

        wlr_device.data = @intFromPtr(device);

        wlr_device.events.destroy.add(&device.destroy);

        // Keyboard groups are implemented as "virtual" input devices which we don't want to expose
        // in riverctl list-inputs as they can't be configured.
        if (!isKeyboardGroup(wlr_device)) {
            // Apply all matching input device configuration.
            // for (server.input_manager.configs.items) |input_config| {
            //     if (globber.match(identifier, input_config.glob)) {
            //         input_config.apply(device);
            //     }
            // }

            server.input_manager.devices.append(device);
            seat.updateCapabilities();
        }

        log.debug("new input device: {s}", .{identifier});
    }

    pub fn deinit(device: *InputDevice) void {
        device.destroy.link.remove();

        utils.gpa.free(device.identifier);

        if (!isKeyboardGroup(device.wlr_device)) {
            device.link.remove();
            device.seat.updateCapabilities();
        }

        device.wlr_device.data = 0;

        device.* = undefined;
    }

    fn isKeyboardGroup(wlr_device: *wlr.InputDevice) bool {
        return wlr_device.type == .keyboard and
            wlr.KeyboardGroup.fromKeyboard(wlr_device.toKeyboard()) != null;
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const device: *InputDevice = @fieldParentPtr("destroy", listener);

        log.debug("removed input device: {s}", .{device.identifier});

        switch (device.wlr_device.type) {
            .keyboard => {
                const keyboard: *Keyboard = @fieldParentPtr("device", device);
                keyboard.deinit();
                utils.gpa.destroy(keyboard);
            },
            .pointer, .touch => {
                device.deinit();
                utils.gpa.destroy(device);
            },
            // .tablet => {
            //     const tablet: *Tablet = @fieldParentPtr("device", device);
            //     tablet.destroy();
            // },
            // .@"switch" => {
            //     const switch_device: *Switch = @fieldParentPtr("device", device);
            //     switch_device.deinit();
            //     utils.gpa.destroy(switch_device);
            // },
            //.tablet_pad => unreachable,
            else => {},
        }
    }
};
