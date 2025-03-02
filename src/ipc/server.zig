const std = @import("std");
const posix = std.posix;
const net = std.net;
const json = std.json;
const Mutex = std.Thread.Mutex;

const gpa = @import("../utils.zig").gpa;

var mutex = Mutex{};

pub const AxiomClient = struct {
    connection: net.Server.Connection,
    open: bool = true,
    subscriptions: std.ArrayList(Subscription) = std.ArrayList(Subscription).init(gpa),

    pub fn deinit(self: AxiomClient) void {
        self.connection.stream.close();
        self.subscriptions.deinit();
    }
};

pub const IpcSocket = struct {
    address: net.Address,
    clients: std.ArrayList(*AxiomClient) = std.ArrayList(*AxiomClient).init(gpa),

    pub fn init(socket: *IpcSocket) !void {
        std.fs.deleteFileAbsolute("/tmp/axiom-ipc") catch {};
        const address = try net.Address.initUnix("/tmp/axiom-ipc");

        socket.* = .{ .address = address };

        const thread = try std.Thread.spawn(.{}, read, .{socket});

        thread.detach();
    }

    pub fn deinit(socket: *IpcSocket) void {
        std.fs.deleteFileAbsolute("/tmp/axiom-ipc") catch {};
        gpa.destroy(socket);
    }

    pub fn read(socket: *IpcSocket) !void {
        var socket_server = try socket.address.listen(.{});

        const notify_thread = try std.Thread.spawn(.{}, virtualNotify, .{socket});

        notify_thread.detach();

        while (true) {
            const connection = try socket_server.accept();

            const client = try gpa.create(AxiomClient);

            client.* = .{
                .connection = connection,
            };

            try socket.clients.append(client);

            const thread = try std.Thread.spawn(.{}, handleConnection, .{ client, socket });

            thread.detach();
        }
    }

    pub fn handleConnection(client: *AxiomClient, socket: *IpcSocket) !void {
        defer socket.clean_clients();
        defer client.open = false;

        while (true) {
            const request = read_from_stream(client) catch {
                //std.debug.print("read failed \n", .{});
                break;
            };

            defer request.deinit();

            const msg = request.items;

            const value = try std.json.parseFromSlice(std.json.Value, gpa, msg, .{});

            const object = value.value.object;

            if (object.get("type")) |res| {
                const mesg_type = std.meta.stringToEnum(MessageType, res.string) orelse {
                    std.debug.print("failed to convert \n", .{});
                    continue;
                };
                switch (mesg_type) {
                    .Actions => try handleActions(client, msg),

                    .Get => try handleGet(client, msg),
                    .Subscribe => try handleSubscribe(client, msg),
                }
            }
        }
    }

    pub fn notifyView(socket: *IpcSocket, event: ViewEvent) !void {
        for (socket.clients.items) |client| {
            //std.debug.print("client {} open: {} \n", .{ i, client.open });
            for (client.subscriptions.items) |value| {
                if (value == .View) {
                    if (client.open) {
                        var buf = std.ArrayList(u8).init(gpa);
                        defer buf.deinit();

                        try std.json.stringify(event, .{}, buf.writer());

                        //std.debug.print("notifying {s} \n", .{buf.items});
                        write_to_stream(client, buf.items) catch {};
                        //     std.debug.print("failed to write \n", .{});
                        //     client.open = false;
                        //     socket.clean_clients();
                        // };

                        break;
                    }

                    break;
                }
            }
        }
    }

    pub fn handleSubscribe(client: *AxiomClient, src: []const u8) !void {
        const msg_json = try std.json.parseFromSlice(std.json.Value, gpa, src, .{});
        const args = msg_json.value.object.get("args").?;
        const subscriptions = try std.json.parseFromValue([]Subscription, gpa, args, .{ .ignore_unknown_fields = true });
        try client.subscriptions.appendSlice(subscriptions.value);
    }

    pub fn handleActions(client: *AxiomClient, src: []const u8) !void {
        const msg_json = try std.json.parseFromSlice(std.json.Value, gpa, src, .{});

        const args = msg_json.value.object.get("args").?.array;

        var replies = std.ArrayList(MessageReply).init(gpa);
        defer replies.deinit();

        for (args.items) |value| {
            const type_string = value.object.get("type").?.string;
            const action_type = std.meta.stringToEnum(Action, type_string) orelse {
                std.debug.print("failed to convert", .{});
                return;
            };
            switch (action_type) {
                .MoveView => {
                    const action = std.json.parseFromValue(MoveViewAction, gpa, value, .{ .ignore_unknown_fields = true }) catch {
                        const reply = MessageReply{
                            .success = false,
                            .err = "invalid arguments",
                            .container = null,
                        };

                        try replies.append(reply);

                        break;
                    };

                    _ = action;

                    const reply = MessageReply{
                        .success = true,
                        .err = null,
                        .container = null,
                    };

                    try replies.append(reply);
                },
                else => {},
            }
        }

        var string = std.ArrayList(u8).init(gpa);
        try std.json.stringify(replies.items, .{}, string.writer());

        try write_to_stream(client, string.items);
    }

    pub fn handleGet(client: *AxiomClient, src: []const u8) !void {
        const msg_json = try json.parseFromSlice(json.Value, gpa, src, .{});

        const arg = msg_json.value.object.get("args") orelse return;

        const arg_str = arg.string;

        const get_type = std.meta.stringToEnum(Getter, arg_str) orelse {
            std.debug.print("failed to convert to getter", .{});
            return;
        };

        switch (get_type) {
            .Views => {
                var ids = std.ArrayList(u32).init(gpa);
                defer ids.deinit();

                try ids.append(12131321);
                try ids.append(24214212);

                var container_string = std.ArrayList(u8).init(gpa);
                defer container_string.deinit();

                try std.json.stringify(
                    ids.items,
                    .{},
                    container_string.writer(),
                );

                const container = try std.json.parseFromSlice(std.json.Value, gpa, container_string.items, .{});

                const reply = MessageReply{
                    .success = true,
                    .err = null,
                    .container = container.value,
                };

                var string = std.ArrayList(u8).init(gpa);
                defer string.deinit();

                try std.json.stringify(reply, .{ .whitespace = .indent_tab }, string.writer());

                try write_to_stream(client, string.items);
            },
        }
    }

    pub fn read_from_stream(client: *AxiomClient) !std.ArrayList(u8) {
        const reader = client.connection.stream.reader();
        const msg: [8]u8 = try reader.readBytesNoEof(8);
        const size = try std.fmt.parseUnsigned(u64, &msg, 10);

        var body = try std.ArrayList(u8).initCapacity(gpa, size);

        body.expandToCapacity();
        body.shrinkAndFree(@as(usize, size));
        _ = try reader.readAll(body.items);

        // std.debug.print("{s} \n", .{body.items});

        return body;
    }

    pub fn write_to_stream(client: *AxiomClient, src: []u8) !void {
        const writer = client.connection.stream.writer();

        const max_len = 8;
        var buf: [max_len]u8 = undefined;
        const size_string = try std.fmt.bufPrint(&buf, "{:0>8}", .{src.len});

        var full_buf = try std.ArrayList(u8).initCapacity(gpa, 8 + src.len);
        defer full_buf.deinit();

        full_buf.expandToCapacity();
        const full_string = try std.fmt.bufPrint(full_buf.items, "{s}{s}", .{ size_string, src });

        try writer.writeAll(full_string);

        //std.debug.print("{s} \n", .{full_string});
    }

    pub fn clean_clients(socket: *IpcSocket) void {
        mutex.lock();
        for (socket.clients.items, 0..) |value, i| {
            if (!value.open) {
                value.deinit();
                _ = socket.clients.swapRemove(i);
            }
        }
        mutex.unlock();
    }

    pub fn virtualNotify(socket: *IpcSocket) !void {
        while (true) {
            try socket.notifyView(.{
                .change = .New,
                .id = 2234324,
            });

            std.time.sleep(2000000000);
        }
    }
};

const MoveViewAction = struct {
    id: u32,
    x: i32,
    y: i32,
};

const MessageReply = struct {
    success: bool,
    err: ?[]const u8,
    container: ?std.json.Value,
};

const MessageType = enum {
    Actions,
    Subscribe,
    Get,
};

const Action = enum {
    MoveView,
    ResizeView,
};

const Getter = enum {
    Views,
};

pub const Subscription = enum {
    View,
};

pub const EventType = enum {
    View,
};

pub const ViewEvent = struct {
    type: []const u8 = "View",
    change: enum { New },
    id: u32,
};
