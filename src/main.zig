const std = @import("std");
const poro = @import("lib.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();

    const wal_intent_file = "poro_intent.wal";
    const wal_completion_file = "poro_completion.wal";
    var db = try poro.Database.init(arena.allocator(), wal_intent_file, wal_completion_file);
    defer db.deinit();

    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    try stdout.print("Poro - Poor mans DB\n", .{});
    try stdout.print("Commands: SET key value, GET key, DEL key, QUIT\n", .{});
    try stdout.print("> ", .{});

    var buf: [4096]u8 = undefined;
    while (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |input| {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) {
            try stdout.print("> ", .{});
            continue;
        }

        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const command = parts.next() orelse {
            try stdout.print("ERR: Empty command\n> ", .{});
            continue;
        };

        if (std.ascii.eqlIgnoreCase(command, "QUIT")) {
            try db.flush();
            try stdout.print("Goodbye!\n", .{});
            break;
        } else if (std.ascii.eqlIgnoreCase(command, "SET")) {
            const key = parts.next() orelse {
                try stdout.print("ERR: SET requires key and value\n> ", .{});
                continue;
            };
            const value = parts.rest();
            if (value.len == 0) {
                try stdout.print("ERR: SET requires value\n> ", .{});
                continue;
            }

            db.set(key, value) catch |err| {
                try stdout.print("ERR: Failed to set key: {}\n> ", .{err});
                continue;
            };
            try stdout.print("OK\n> ", .{});
        } else if (std.ascii.eqlIgnoreCase(command, "GET")) {
            const key = parts.next() orelse {
                try stdout.print("ERR: GET requires key\n> ", .{});
                continue;
            };

            if (db.get(key)) |value| {
                try stdout.print("\"{s}\"\n> ", .{value});
            } else {
                try stdout.print("(nil)\n> ", .{});
            }
        } else if (std.ascii.eqlIgnoreCase(command, "DEL")) {
            const key = parts.next() orelse {
                try stdout.print("ERR: DEL requires key\n> ", .{});
                continue;
            };

            const deleted = db.del(key) catch |err| {
                try stdout.print("ERR: Failed to delete key: {}\n> ", .{err});
                continue;
            };

            if (deleted) {
                try stdout.print("(integer) 1\n> ", .{});
            } else {
                try stdout.print("(integer) 0\n> ", .{});
            }
        } else {
            try stdout.print("ERR: Unknown command '{}'. Available: SET, GET, DEL, QUIT\n> ", .{std.zig.fmtEscapes(command)});
        }
    }
}
