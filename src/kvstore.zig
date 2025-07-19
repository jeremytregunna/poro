const std = @import("std");
const allocator_mod = @import("allocator.zig");
const wal_mod = @import("wal.zig");
const Allocator = std.mem.Allocator;

const INITIAL_CAPACITY = 1024;
const LOAD_FACTOR_THRESHOLD = 0.75;

pub const KVEntry = struct {
    key: []u8,
    value: []u8,
    hash: u64,
    is_deleted: bool,

    pub fn init(allocator: Allocator, key: []const u8, value: []const u8) !KVEntry {
        const key_copy = try allocator.dupe(u8, key);
        const value_copy = try allocator.dupe(u8, value);
        return KVEntry{
            .key = key_copy,
            .value = value_copy,
            .hash = hash_key(key),
            .is_deleted = false,
        };
    }

    pub fn deinit(self: *KVEntry, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const KVStore = struct {
    entries: []?KVEntry,
    capacity: usize,
    size: usize,
    allocator: Allocator,
    wal: wal_mod.WAL,

    pub const InitResult = struct {
        store: KVStore,
        corruption_count: u64,
    };

    pub fn init(allocator: Allocator, wal_intent_path: []const u8, wal_completion_path: []const u8) !KVStore {
        const result = try init_with_corruption_stats(allocator, wal_intent_path, wal_completion_path);
        return result.store;
    }

    pub fn init_with_corruption_stats(allocator: Allocator, wal_intent_path: []const u8, wal_completion_path: []const u8) !InitResult {
        const entries = try allocator.alloc(?KVEntry, INITIAL_CAPACITY);
        for (entries) |*entry| {
            entry.* = null;
        }

        var wal = try wal_mod.WAL.init(allocator, wal_intent_path, wal_completion_path);
        errdefer wal.deinit();

        var store = KVStore{
            .entries = entries,
            .capacity = INITIAL_CAPACITY,
            .size = 0,
            .allocator = allocator,
            .wal = wal,
        };

        // Recover from WAL - if this fails, errdefer will clean up WAL
        const corruption_count = store.recover_from_wal() catch |err| {
            allocator.free(entries);
            return err;
        };

        return InitResult{
            .store = store,
            .corruption_count = corruption_count,
        };
    }

    pub fn deinit(self: *KVStore) void {
        for (self.entries) |*entry| {
            if (entry.*) |*kv| {
                kv.deinit(self.allocator);
            }
        }
        self.allocator.free(self.entries);
        self.wal.deinit();
    }

    pub fn set(self: *KVStore, key: []const u8, value: []const u8) !void {
        // Log intent to WAL first
        const intent_offset = try self.wal.append_entry(.set, key, value);

        const hash = hash_key(key);
        
        // Try to find a slot, with one resize attempt if needed
        const index = self.find_slot(hash, key) catch |err| switch (err) {
            error.HashTableFull => blk: {
                // Try to resize once, if it fails we can't proceed
                try self.resize();
                // Try find_slot again after resize
                break :blk try self.find_slot(hash, key);
            },
        };

        if (self.entries[index]) |*existing| {
            // Update existing entry
            self.allocator.free(existing.value);
            existing.value = try self.allocator.dupe(u8, value);
            existing.is_deleted = false;
        } else {
            // New entry
            self.entries[index] = try KVEntry.init(self.allocator, key, value);
            self.size += 1;

            // Check if we need to resize
            if (@as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.capacity)) > LOAD_FACTOR_THRESHOLD) {
                try self.resize();
            }
        }

        // Log completion after successful write
        const checksum = wal_mod.WAL.calculate_checksum(key, value);
        try self.wal.append_completion(intent_offset, .success, checksum);
    }

    pub fn get(self: *KVStore, key: []const u8) ?[]const u8 {
        const hash = hash_key(key);
        const index = self.find_slot(hash, key) catch {
            // If hash table is full and can't find the key, it doesn't exist
            return null;
        };

        if (self.entries[index]) |*entry| {
            if (!entry.is_deleted and std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn del(self: *KVStore, key: []const u8) !bool {
        // Log intent to WAL first
        const intent_offset = try self.wal.append_entry(.del, key, "");

        const hash = hash_key(key);
        const index = self.find_slot(hash, key) catch {
            // If hash table is full and can't find the key, it doesn't exist
            const checksum = wal_mod.WAL.calculate_checksum(key, "");
            try self.wal.append_completion(intent_offset, .success, checksum);
            return false;
        };

        var deleted = false;
        if (self.entries[index]) |*entry| {
            if (!entry.is_deleted and std.mem.eql(u8, entry.key, key)) {
                entry.is_deleted = true;
                self.size -= 1;
                deleted = true;
            }
        }

        // Log completion after operation
        const checksum = wal_mod.WAL.calculate_checksum(key, "");
        try self.wal.append_completion(intent_offset, .success, checksum);

        return deleted;
    }

    pub fn flush_wal(self: *KVStore) !void {
        try self.wal.flush();
    }

    fn find_slot(self: *KVStore, hash: u64, key: []const u8) !usize {
        var index = hash % self.capacity;
        var attempts: usize = 0;
        
        while (attempts < self.capacity) {
            if (self.entries[index]) |*entry| {
                if (!entry.is_deleted and std.mem.eql(u8, entry.key, key)) {
                    return index;
                }
            } else {
                return index;
            }
            index = (index + 1) % self.capacity;
            attempts += 1;
        }
        
        // Hash table is full - this should trigger a resize
        return error.HashTableFull;
    }

    fn resize(self: *KVStore) !void {
        const old_entries = self.entries;

        self.capacity *= 2;
        self.entries = try self.allocator.alloc(?KVEntry, self.capacity);
        for (self.entries) |*entry| {
            entry.* = null;
        }
        self.size = 0;

        // Rehash all entries
        for (old_entries) |entry| {
            if (entry) |kv| {
                if (!kv.is_deleted) {
                    const index = self.find_slot(kv.hash, kv.key) catch {
                        // This should never happen after resize, but just in case
                        continue;
                    };
                    self.entries[index] = kv;
                    self.size += 1;
                }
            }
        }

        self.allocator.free(old_entries);
    }

    fn recover_from_wal(self: *KVStore) !u64 {
        const RecoveryState = struct {
            var store_ptr: ?*KVStore = null;

            fn callback(operation: wal_mod.WALEntry.Operation, key: []const u8, value: []const u8, completed: bool) void {
                if (store_ptr) |store| {
                    // Only apply operations that were completed successfully
                    if (completed) {
                        switch (operation) {
                            .set => store.set_without_wal(key, value) catch {},
                            .del => _ = store.del_without_wal(key) catch {},
                        }
                    }
                }
            }
        };

        RecoveryState.store_ptr = self;
        const corruption_count = try self.wal.recovery_read(RecoveryState.callback);
        RecoveryState.store_ptr = null;
        
        return corruption_count;
    }

    fn set_without_wal(self: *KVStore, key: []const u8, value: []const u8) !void {
        const hash = hash_key(key);
        const index = self.find_slot(hash, key) catch {
            // During recovery, if hash table is full, just ignore this entry
            return;
        };

        if (self.entries[index]) |*existing| {
            self.allocator.free(existing.value);
            existing.value = try self.allocator.dupe(u8, value);
            existing.is_deleted = false;
        } else {
            self.entries[index] = try KVEntry.init(self.allocator, key, value);
            self.size += 1;

            if (@as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.capacity)) > LOAD_FACTOR_THRESHOLD) {
                try self.resize();
            }
        }
    }

    fn del_without_wal(self: *KVStore, key: []const u8) !bool {
        const hash = hash_key(key);
        const index = self.find_slot(hash, key) catch {
            // During recovery, if hash table is full, just ignore this deletion
            return false;
        };

        if (self.entries[index]) |*entry| {
            if (!entry.is_deleted and std.mem.eql(u8, entry.key, key)) {
                entry.is_deleted = true;
                self.size -= 1;
                return true;
            }
        }
        return false;
    }
};

fn hash_key(key: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(key);
    return hasher.final();
}

test "KVStore basic operations" {
    const test_wal_intent = "/tmp/test_kvstore_intent.wal";
    const test_wal_completion = "/tmp/test_kvstore_completion.wal";
    std.fs.deleteFileAbsolute(test_wal_intent) catch {};
    std.fs.deleteFileAbsolute(test_wal_completion) catch {};
    defer std.fs.deleteFileAbsolute(test_wal_intent) catch {};
    defer std.fs.deleteFileAbsolute(test_wal_completion) catch {};

    var store = try KVStore.init(std.testing.allocator, test_wal_intent, test_wal_completion);
    defer store.deinit();

    // Test SET and GET
    try store.set("key1", "value1");
    const result1 = store.get("key1");
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("value1", result1.?);

    // Test overwrite
    try store.set("key1", "new_value1");
    const result2 = store.get("key1");
    try std.testing.expectEqualStrings("new_value1", result2.?);

    // Test DEL
    const deleted = try store.del("key1");
    try std.testing.expect(deleted);
    const result3 = store.get("key1");
    try std.testing.expect(result3 == null);

    // Test non-existent key
    const result4 = store.get("nonexistent");
    try std.testing.expect(result4 == null);
}
