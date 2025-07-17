//! ABOUTME: Write-Ahead Log implementation using io_uring for high-performance disk I/O
//! ABOUTME: Manages a 10MB ring buffer that persists operations to disk asynchronously
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

pub const WAL = struct {
    ring: io_uring,
    file_fd: std.posix.fd_t,
    buffer: []u8,
    write_offset: u32,
    read_offset: u32,
    allocator: Allocator,
    is_full: bool,
    
    pub fn init(allocator: Allocator, file_path: []const u8) !WAL {
        var ring = try io_uring.init(MAX_ENTRIES, 0);
        errdefer ring.deinit();
        
        const file_fd = try std.posix.openat(
            std.posix.AT.FDCWD,
            file_path,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            0o644
        );
        errdefer std.posix.close(file_fd);
        
        const page_size = 4096; // Standard page size on most systems
        const buffer = try allocator.alignedAlloc(u8, page_size, WAL_SIZE);
        errdefer allocator.free(buffer);
        
        return WAL{
            .ring = ring,
            .file_fd = file_fd,
            .buffer = buffer,
            .write_offset = 0,
            .read_offset = 0,
            .allocator = allocator,
            .is_full = false,
        };
    }
    
    pub fn deinit(self: *WAL) void {
        self.ring.deinit();
        std.posix.close(self.file_fd);
        self.allocator.free(self.buffer);
    }
    
    pub fn append_entry(self: *WAL, operation: WALEntry.Operation, key: []const u8, value: []const u8) !void {
        const entry = WALEntry{
            .timestamp = std.time.timestamp(),
            .operation = operation,
            .key_len = @intCast(key.len),
            .value_len = @intCast(value.len),
        };
        
        const total_size = entry.total_size();
        
        // Check if we have space in the ring buffer
        if (self.write_offset + total_size > WAL_SIZE) {
            if (self.read_offset > 0) {
                // Wrap around
                self.write_offset = 0;
            } else {
                // Buffer is full, need to flush
                try self.flush();
                self.write_offset = 0;
                self.read_offset = 0;
                self.is_full = false;
            }
        }
        
        // Write entry header
        std.mem.copyForwards(u8, self.buffer[self.write_offset..], std.mem.asBytes(&entry));
        self.write_offset += @sizeOf(WALEntry);
        
        // Write key
        std.mem.copyForwards(u8, self.buffer[self.write_offset..], key);
        self.write_offset += entry.key_len;
        
        // Write value
        std.mem.copyForwards(u8, self.buffer[self.write_offset..], value);
        self.write_offset += entry.value_len;
        
        // Check if buffer is getting full (75% threshold)
        if (self.write_offset > (WAL_SIZE * 3) / 4) {
            try self.flush_async();
        }
    }
    
    fn flush_async(self: *WAL) !void {
        const write_sqe = try self.ring.write(0, self.file_fd, self.buffer[self.read_offset..self.write_offset], 0);
        _ = write_sqe;
        
        const submitted = try self.ring.submit();
        _ = submitted;
        
        // Don't wait for completion in async mode
    }
    
    pub fn flush(self: *WAL) !void {
        if (self.write_offset == self.read_offset) return;
        
        const write_sqe = try self.ring.write(0, self.file_fd, self.buffer[self.read_offset..self.write_offset], 0);
        _ = write_sqe;
        
        const submitted = try self.ring.submit();
        _ = submitted;
        
        // Wait for completion
        var cqe: linux.io_uring_cqe = try self.ring.copy_cqe();
        defer self.ring.cqe_seen(&cqe);
        
        if (cqe.res < 0) {
            return std.posix.unexpectedErrno(@enumFromInt(@as(u32, @bitCast(-cqe.res))));
        }
        
        self.read_offset = self.write_offset;
    }
    
    pub fn recovery_read(self: *WAL, callback: fn(operation: WALEntry.Operation, key: []const u8, value: []const u8) void) !void {
        // Read the entire WAL file for recovery
        const file = std.fs.File{ .handle = self.file_fd };
        const file_size = try file.getEndPos();
        try file.seekTo(0);
        
        if (file_size == 0) return;
        
        const read_buffer = try self.allocator.alloc(u8, @intCast(file_size));
        defer self.allocator.free(read_buffer);
        
        _ = try std.posix.read(self.file_fd, read_buffer);
        
        var offset: usize = 0;
        while (offset < read_buffer.len) {
            if (offset + @sizeOf(WALEntry) > read_buffer.len) break;
            
            const entry_ptr: *const WALEntry = @ptrCast(@alignCast(&read_buffer[offset]));
            offset += @sizeOf(WALEntry);
            
            if (offset + entry_ptr.key_len + entry_ptr.value_len > read_buffer.len) break;
            
            const key = read_buffer[offset..offset + entry_ptr.key_len];
            offset += entry_ptr.key_len;
            
            const value = read_buffer[offset..offset + entry_ptr.value_len];
            offset += entry_ptr.value_len;
            
            callback(entry_ptr.operation, key, value);
        }
    }
};

test "WAL basic operations" {
    const test_file = "/tmp/test_wal.log";
    std.fs.deleteFileAbsolute(test_file) catch {};
    
    var wal = try WAL.init(std.testing.allocator, test_file);
    defer wal.deinit();
    defer std.fs.deleteFileAbsolute(test_file) catch {};
    
    try wal.append_entry(.set, "key1", "value1");
    try wal.append_entry(.set, "key2", "value2");
    try wal.append_entry(.del, "key1", "");
    
    try wal.flush();
    
    // Test recovery
    const TestState = struct {
        var recovered_entries: u32 = 0;
        var last_operation: WALEntry.Operation = .set;
        var last_key: [64]u8 = undefined;
        var last_value: [64]u8 = undefined;
        var last_key_len: usize = 0;
        var last_value_len: usize = 0;
        
        fn callback(operation: WALEntry.Operation, key: []const u8, value: []const u8) void {
            recovered_entries += 1;
            last_operation = operation;
            last_key_len = @min(key.len, last_key.len);
            last_value_len = @min(value.len, last_value.len);
            std.mem.copyForwards(u8, last_key[0..last_key_len], key[0..last_key_len]);
            std.mem.copyForwards(u8, last_value[0..last_value_len], value[0..last_value_len]);
        }
    };
    
    TestState.recovered_entries = 0;
    try wal.recovery_read(TestState.callback);
    try std.testing.expect(TestState.recovered_entries == 3);
    try std.testing.expect(TestState.last_operation == .del);
    try std.testing.expectEqualStrings("key1", TestState.last_key[0..TestState.last_key_len]);
}