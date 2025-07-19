// ABOUTME: Main library exports for the Poro key-value database
// ABOUTME: Provides KVStore, WAL, and allocator functionality as a reusable library
const std = @import("std");

pub const KVStore = @import("kvstore.zig").KVStore;
pub const WAL = @import("wal.zig").WAL;
pub const StaticAllocator = @import("allocator.zig").StaticAllocator;

pub const Database = struct {
    allocator: std.mem.Allocator,
    store: KVStore,

    pub fn init(allocator: std.mem.Allocator, intent_wal_path: []const u8, completion_wal_path: []const u8) !Database {
        const store = try KVStore.init(allocator, intent_wal_path, completion_wal_path);

        return Database{
            .allocator = allocator,
            .store = store,
        };
    }

    pub fn deinit(self: *Database) void {
        self.store.deinit();
    }

    pub fn set(self: *Database, key: []const u8, value: []const u8) !void {
        return self.store.set(key, value);
    }

    pub fn get(self: *Database, key: []const u8) ?[]const u8 {
        return self.store.get(key);
    }

    pub fn del(self: *Database, key: []const u8) !bool {
        return self.store.del(key);
    }

    pub fn flush(self: *Database) !void {
        return self.store.flush_wal();
    }
};

test "Database basic operations" {
    const test_intent_wal = "/tmp/test_db_intent.wal";
    const test_completion_wal = "/tmp/test_db_completion.wal";
    std.fs.deleteFileAbsolute(test_intent_wal) catch {};
    std.fs.deleteFileAbsolute(test_completion_wal) catch {};
    defer std.fs.deleteFileAbsolute(test_intent_wal) catch {};
    defer std.fs.deleteFileAbsolute(test_completion_wal) catch {};

    var db = try Database.init(std.testing.allocator, test_intent_wal, test_completion_wal);
    defer db.deinit();

    try db.set("test_key", "test_value");
    const result = db.get("test_key");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test_value", result.?);

    const deleted = try db.del("test_key");
    try std.testing.expect(deleted);
    const result2 = db.get("test_key");
    try std.testing.expect(result2 == null);
}