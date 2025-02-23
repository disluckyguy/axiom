const std = @import("std");
const posix = std.posix;
const net = std.net;

const gpa = @import("../utils.zig").gpa;

const server = &@import("../main.zig").server;

pub const IpcSocket = struct {
    address: net.Address,

    pub fn init(socket: *IpcSocket) !void {
        std.fs.deleteFileAbsolute("/home/mostafa/.config/axiom/ipc") catch {};
        const address = try net.Address.initUnix("/home/mostafa/.config/axiom/ipc");

        socket.* = .{
            .address = address,
        };

        const thread = try std.Thread.spawn(.{}, read, .{@as(*IpcSocket, socket)});
        _ = thread;
    }

    pub fn deinit(_: *IpcSocket) void {
        std.fs.deleteFileAbsolute("/home/mostafa/.config/axiom/ipc") catch {};
    }

    pub fn read(socket: *IpcSocket) !void {
        var socket_server = try socket.address.listen(.{});

        while (true) {
            std.debug.print("function started \n", .{});

            var client = socket_server.accept() catch |err| {
                std.debug.print("failed to accept socket {} \n", .{err});
                return;
            };
            defer client.stream.close();

            //const client_reader = client.stream.reader();
            const client_writer = client.stream.writer();

            while (true) {
                // const msg = client_reader.readUntilDelimiterOrEofAlloc(gpa, '\n', 65536) catch |err| {
                //     std.debug.print("failed to read {} \n", .{err});
                //     break;
                // } orelse break;

                // defer gpa.free(msg);

                // std.log.info("Recieved message: \"{}\"", .{std.zig.fmtEscapes(msg)});
                // std.debug.print("message recieved '{}' \n", .{std.zig.fmtEscapes(msg)});

                client_writer.writeAll("I hear youu!!! \n") catch {
                    std.debug.print("failed to write \n", .{});
                    break;
                };

                std.time.sleep(2000000000);

                client_writer.writeAll("Hi!!! \n") catch {
                    std.debug.print("failed to write \n", .{});
                    break;
                };

                std.time.sleep(200000000);

                // const view = server.root.views.first().?;

                // view.pending.box.x = 0;

                // server.root.transaction.applyPending();
            }
        }
    }
};
