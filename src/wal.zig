// ABOUTME: Write-ahead logging implementation with dual rings for intent and completion tracking
// ABOUTME: Provides crash recovery capabilities with verification of successful operations
const std = @import("std");
const linux = std.os.linux;
const io_uring = linux.IoUring;
const Allocator = std.mem.Allocator;

const WAL_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_ENTRIES = 256;

pub const WALEntry = struct {
    timestamp: i64,
    operation: Operation,
    key_len: u32,
    value_len: u32,
    // key and value data follows immediately after this struct

    pub const Operation = enum(u8) {
        set = 0,
        del = 1,
    };

    pub fn total_size(self: WALEntry) u32 {
        return @sizeOf(WALEntry) + self.key_len + self.value_len;
    }
};

pub const CompletionEntry = struct {
    intent_offset: u32,
    timestamp: i64,
    status: Status,
    checksum: u32,

    pub const Status = enum(u8) {
        success = 0,
        io_error = 1,
        checksum_error = 2,
    };
};

pub const WAL = struct {
    intent_ring: io_uring,
    completion_ring: io_uring,
    intent_file_fd: std.posix.fd_t,
    completion_file_fd: std.posix.fd_t,
    intent_buffer: []u8,
    completion_buffer: []u8,
    intent_write_offset: u32,
    intent_read_offset: u32,
    completion_write_offset: u32,
    completion_read_offset: u32,
    allocator: Allocator,
    is_full: bool,

    pub fn init(allocator: Allocator, intent_file_path: []const u8, completion_file_path: []const u8) !WAL {
        var intent_ring = try io_uring.init(MAX_ENTRIES, 0);
        errdefer intent_ring.deinit();

        var completion_ring = try io_uring.init(MAX_ENTRIES, 0);
        errdefer completion_ring.deinit();

        const intent_file_fd = try std.posix.openat(std.posix.AT.FDCWD, intent_file_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        errdefer std.posix.close(intent_file_fd);

        const completion_file_fd = try std.posix.openat(std.posix.AT.FDCWD, completion_file_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
        errdefer std.posix.close(completion_file_fd);

        const page_size = 4096; // Standard page size on most systems
        const intent_buffer = try allocator.alignedAlloc(u8, page_size, WAL_SIZE);
        errdefer allocator.free(intent_buffer);

        const completion_buffer = try allocator.alignedAlloc(u8, page_size, WAL_SIZE);
        errdefer allocator.free(completion_buffer);

        return WAL{
            .intent_ring = intent_ring,
            .completion_ring = completion_ring,
            .intent_file_fd = intent_file_fd,
            .completion_file_fd = completion_file_fd,
            .intent_buffer = intent_buffer,
            .completion_buffer = completion_buffer,
            .intent_write_offset = 0,
            .intent_read_offset = 0,
            .completion_write_offset = 0,
            .completion_read_offset = 0,
            .allocator = allocator,
            .is_full = false,
        };
    }

    pub fn deinit(self: *WAL) void {
        self.intent_ring.deinit();
        self.completion_ring.deinit();
        std.posix.close(self.intent_file_fd);
        std.posix.close(self.completion_file_fd);
        self.allocator.free(self.intent_buffer);
        self.allocator.free(self.completion_buffer);
    }

    pub fn append_entry(self: *WAL, operation: WALEntry.Operation, key: []const u8, value: []const u8) !u32 {
        const entry = WALEntry{
            .timestamp = std.time.timestamp(),
            .operation = operation,
            .key_len = @intCast(key.len),
            .value_len = @intCast(value.len),
        };

        const total_size = entry.total_size();
        const intent_offset = self.intent_write_offset;

        // Check if we have space in the intent ring buffer
        if (self.intent_write_offset + total_size > WAL_SIZE) {
            if (self.intent_read_offset >= total_size) {
                // Wrap around - there's enough space at the beginning
                self.intent_write_offset = 0;
            } else {
                // Not enough space to wrap around, need to flush
                try self.flush_intent();
                self.intent_write_offset = 0;
                self.intent_read_offset = 0;
                self.is_full = false;
            }
        }

        // Write entry header
        std.mem.copyForwards(u8, self.intent_buffer[self.intent_write_offset..], std.mem.asBytes(&entry));
        self.intent_write_offset += @sizeOf(WALEntry);

        // Write key
        std.mem.copyForwards(u8, self.intent_buffer[self.intent_write_offset..], key);
        self.intent_write_offset += entry.key_len;

        // Write value
        std.mem.copyForwards(u8, self.intent_buffer[self.intent_write_offset..], value);
        self.intent_write_offset += entry.value_len;

        // Check if buffer is getting full (75% threshold)
        if (self.intent_write_offset > (WAL_SIZE * 3) / 4) {
            try self.flush_intent_async();
        }

        return intent_offset;
    }

    pub fn append_completion(self: *WAL, intent_offset: u32, status: CompletionEntry.Status, checksum: u32) !void {
        const completion = CompletionEntry{
            .intent_offset = intent_offset,
            .timestamp = std.time.timestamp(),
            .status = status,
            .checksum = checksum,
        };

        const completion_size = @sizeOf(CompletionEntry);

        // Check if we have space in the completion ring buffer
        if (self.completion_write_offset + completion_size > WAL_SIZE) {
            if (self.completion_read_offset > 0) {
                // Wrap around
                self.completion_write_offset = 0;
            } else {
                // Buffer is full, need to flush
                try self.flush_completion();
                self.completion_write_offset = 0;
                self.completion_read_offset = 0;
            }
        }

        // Write completion entry
        std.mem.copyForwards(u8, self.completion_buffer[self.completion_write_offset..], std.mem.asBytes(&completion));
        self.completion_write_offset += completion_size;

        // Check if buffer is getting full (75% threshold)
        if (self.completion_write_offset > (WAL_SIZE * 3) / 4) {
            try self.flush_completion_async();
        }
    }

    fn flush_intent_async(self: *WAL) !void {
        const write_sqe = try self.intent_ring.write(0, self.intent_file_fd, self.intent_buffer[self.intent_read_offset..self.intent_write_offset], 0);
        _ = write_sqe;

        const submitted = try self.intent_ring.submit();
        _ = submitted;

        // Don't wait for completion in async mode
    }

    fn flush_completion_async(self: *WAL) !void {
        const write_sqe = try self.completion_ring.write(0, self.completion_file_fd, self.completion_buffer[self.completion_read_offset..self.completion_write_offset], 0);
        _ = write_sqe;

        const submitted = try self.completion_ring.submit();
        _ = submitted;

        // Don't wait for completion in async mode
    }

    pub fn flush_intent(self: *WAL) !void {
        if (self.intent_write_offset == self.intent_read_offset) return;

        const write_sqe = try self.intent_ring.write(0, self.intent_file_fd, self.intent_buffer[self.intent_read_offset..self.intent_write_offset], 0);
        _ = write_sqe;

        const submitted = try self.intent_ring.submit();
        _ = submitted;

        // Wait for completion
        var cqe: linux.io_uring_cqe = try self.intent_ring.copy_cqe();
        defer self.intent_ring.cqe_seen(&cqe);

        if (cqe.res < 0) {
            return std.posix.unexpectedErrno(@enumFromInt(@as(u32, @bitCast(-cqe.res))));
        }

        self.intent_read_offset = self.intent_write_offset;
    }

    pub fn flush_completion(self: *WAL) !void {
        if (self.completion_write_offset == self.completion_read_offset) return;

        const write_sqe = try self.completion_ring.write(0, self.completion_file_fd, self.completion_buffer[self.completion_read_offset..self.completion_write_offset], 0);
        _ = write_sqe;

        const submitted = try self.completion_ring.submit();
        _ = submitted;

        // Wait for completion
        var cqe: linux.io_uring_cqe = try self.completion_ring.copy_cqe();
        defer self.completion_ring.cqe_seen(&cqe);

        if (cqe.res < 0) {
            return std.posix.unexpectedErrno(@enumFromInt(@as(u32, @bitCast(-cqe.res))));
        }

        self.completion_read_offset = self.completion_write_offset;
    }

    pub fn flush(self: *WAL) !void {
        try self.flush_intent();
        try self.flush_completion();
    }

    pub fn recovery_read(self: *WAL, callback: fn (operation: WALEntry.Operation, key: []const u8, value: []const u8, completed: bool) void) !u64 {
        // Read the intent file
        const intent_file = std.fs.File{ .handle = self.intent_file_fd };
        const intent_file_size = try intent_file.getEndPos();
        try intent_file.seekTo(0);

        if (intent_file_size == 0) return 0;

        const intent_buffer = try self.allocator.alloc(u8, @intCast(intent_file_size));
        defer self.allocator.free(intent_buffer);

        _ = try std.posix.read(self.intent_file_fd, intent_buffer);

        // Read the completion file
        const completion_file = std.fs.File{ .handle = self.completion_file_fd };
        const completion_file_size = try completion_file.getEndPos();
        try completion_file.seekTo(0);

        var completion_map = std.HashMap(u32, CompletionEntry, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer completion_map.deinit();

        if (completion_file_size > 0) {
            const completion_buffer = try self.allocator.alloc(u8, @intCast(completion_file_size));
            defer self.allocator.free(completion_buffer);

            _ = try std.posix.read(self.completion_file_fd, completion_buffer);

            // Build completion map
            var completion_offset: usize = 0;
            while (completion_offset + @sizeOf(CompletionEntry) <= completion_buffer.len) {
                // Read completion entry by copying bytes (no alignment assumptions)
                var completion: CompletionEntry = undefined;
                std.mem.copyForwards(u8, std.mem.asBytes(&completion), completion_buffer[completion_offset..completion_offset + @sizeOf(CompletionEntry)]);
                
                // Validate completion entry - if the intent_offset is suspiciously large, skip this entry
                if (completion.intent_offset < @as(u32, @intCast(intent_file_size))) {
                    try completion_map.put(completion.intent_offset, completion);
                }
                completion_offset += @sizeOf(CompletionEntry);
            }
        }

        // Process intent entries and check completion status
        var intent_offset: usize = 0;
        var corruption_count: u64 = 0;
        while (intent_offset < intent_buffer.len) {
            if (intent_offset + @sizeOf(WALEntry) > intent_buffer.len) break;

            // Read entry header by copying bytes (no alignment assumptions)
            var entry: WALEntry = undefined;
            std.mem.copyForwards(u8, std.mem.asBytes(&entry), intent_buffer[intent_offset..intent_offset + @sizeOf(WALEntry)]);
            const entry_start_offset = intent_offset;
            intent_offset += @sizeOf(WALEntry);

            // Validate entry fields for sanity
            const operation_raw = @intFromEnum(entry.operation);
            const max_reasonable_size = 1024 * 1024; // 1MB max for key or value
            
            if (operation_raw != 0 and operation_raw != 1) {
                // WAL corruption detected - count and stop parsing
                corruption_count += 1;
                break;
            }
            
            if (entry.key_len > max_reasonable_size or entry.value_len > max_reasonable_size) {
                // WAL corruption detected - count and stop parsing
                corruption_count += 1;
                break;
            }
            
            if (entry.timestamp < 0) {
                // WAL corruption detected - count and stop parsing
                corruption_count += 1;
                break;
            }

            if (intent_offset + entry.key_len + entry.value_len > intent_buffer.len) break;

            const key = intent_buffer[intent_offset .. intent_offset + entry.key_len];
            intent_offset += entry.key_len;

            const value = intent_buffer[intent_offset .. intent_offset + entry.value_len];
            intent_offset += entry.value_len;

            // Check if this operation was completed successfully
            const completed = if (completion_map.get(@intCast(entry_start_offset))) |completion|
                completion.status == .success
            else
                false;

            callback(entry.operation, key, value, completed);
        }
        
        return corruption_count;
    }

    pub fn calculate_checksum(key: []const u8, value: []const u8) u32 {
        var hasher = std.hash.Crc32.init();
        hasher.update(key);
        hasher.update(value);
        return hasher.final();
    }
};

test "WAL basic operations" {
    const test_intent_file = "/tmp/test_wal_intent.log";
    const test_completion_file = "/tmp/test_wal_completion.log";
    std.fs.deleteFileAbsolute(test_intent_file) catch {};
    std.fs.deleteFileAbsolute(test_completion_file) catch {};

    var wal = try WAL.init(std.testing.allocator, test_intent_file, test_completion_file);
    defer wal.deinit();
    defer std.fs.deleteFileAbsolute(test_intent_file) catch {};
    defer std.fs.deleteFileAbsolute(test_completion_file) catch {};

    const offset1 = try wal.append_entry(.set, "key1", "value1");
    const offset2 = try wal.append_entry(.set, "key2", "value2");
    const offset3 = try wal.append_entry(.del, "key1", "");

    try wal.flush();

    // Mark some operations as completed
    const checksum1 = WAL.calculate_checksum("key1", "value1");
    const checksum2 = WAL.calculate_checksum("key2", "value2");
    try wal.append_completion(offset1, .success, checksum1);
    try wal.append_completion(offset2, .success, checksum2);
    // Demonstrate incomplete operation - offset3 is not marked as completed
    // This simulates a crash between intent logging and completion logging
    const incomplete_offset = offset3;

    try wal.flush();

    // Test recovery
    const TestState = struct {
        var recovered_entries: u32 = 0;
        var completed_entries: u32 = 0;
        var last_operation: WALEntry.Operation = .set;
        var last_key: [64]u8 = undefined;
        var last_value: [64]u8 = undefined;
        var last_key_len: usize = 0;
        var last_value_len: usize = 0;
        var last_completed: bool = false;

        fn callback(operation: WALEntry.Operation, key: []const u8, value: []const u8, completed: bool) void {
            recovered_entries += 1;
            if (completed) completed_entries += 1;
            last_operation = operation;
            last_key_len = @min(key.len, last_key.len);
            last_value_len = @min(value.len, last_value.len);
            last_completed = completed;
            std.mem.copyForwards(u8, last_key[0..last_key_len], key[0..last_key_len]);
            std.mem.copyForwards(u8, last_value[0..last_value_len], value[0..last_value_len]);
        }
    };

    TestState.recovered_entries = 0;
    TestState.completed_entries = 0;
    const corruption_count = try wal.recovery_read(TestState.callback);
    try std.testing.expect(corruption_count == 0); // Should be no corruption in this test
    try std.testing.expect(TestState.recovered_entries == 3);
    try std.testing.expect(TestState.completed_entries == 2); // Only first two operations were completed
    try std.testing.expect(TestState.last_operation == .del);
    try std.testing.expect(TestState.last_completed == false); // Last operation was not completed
    try std.testing.expectEqualStrings("key1", TestState.last_key[0..TestState.last_key_len]);

    // Verify the incomplete operation offset is what we expect
    try std.testing.expect(incomplete_offset > 0);
}
