// ABOUTME: Filesystem abstraction layer for dependency injection and error simulation
// ABOUTME: Enables testing filesystem failures like disk full, permission errors, and IO failures
const std = @import("std");

pub const FilesystemError = error{
    DiskFull,
    PermissionDenied,
    IoError,
    FileNotFound,
    AccessDenied,
    DeviceBusy,
    NetworkError,
    CorruptedData,
};

pub const FileOperationType = enum {
    open,
    read,
    write,
    flush,
    sync,
    close,
    seek,
    truncate,
    get_size,
};

pub const FilesystemInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, path: []const u8, flags: OpenFlags) anyerror!FileHandle,
        close: *const fn (ctx: *anyopaque, handle: FileHandle) anyerror!void,
        read: *const fn (ctx: *anyopaque, handle: FileHandle, buffer: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, handle: FileHandle, data: []const u8) anyerror!usize,
        flush: *const fn (ctx: *anyopaque, handle: FileHandle) anyerror!void,
        sync: *const fn (ctx: *anyopaque, handle: FileHandle) anyerror!void,
        seek: *const fn (ctx: *anyopaque, handle: FileHandle, offset: u64) anyerror!void,
        get_size: *const fn (ctx: *anyopaque, handle: FileHandle) anyerror!u64,
        truncate: *const fn (ctx: *anyopaque, handle: FileHandle, size: u64) anyerror!void,
    };

    pub fn open(self: FilesystemInterface, path: []const u8, flags: OpenFlags) !FileHandle {
        return self.vtable.open(self.ptr, path, flags);
    }

    pub fn close(self: FilesystemInterface, handle: FileHandle) !void {
        return self.vtable.close(self.ptr, handle);
    }

    pub fn read(self: FilesystemInterface, handle: FileHandle, buffer: []u8) !usize {
        return self.vtable.read(self.ptr, handle, buffer);
    }

    pub fn write(self: FilesystemInterface, handle: FileHandle, data: []const u8) !usize {
        return self.vtable.write(self.ptr, handle, data);
    }

    pub fn flush(self: FilesystemInterface, handle: FileHandle) !void {
        return self.vtable.flush(self.ptr, handle);
    }

    pub fn sync(self: FilesystemInterface, handle: FileHandle) !void {
        return self.vtable.sync(self.ptr, handle);
    }

    pub fn seek(self: FilesystemInterface, handle: FileHandle, offset: u64) !void {
        return self.vtable.seek(self.ptr, handle, offset);
    }

    pub fn get_size(self: FilesystemInterface, handle: FileHandle) !u64 {
        return self.vtable.get_size(self.ptr, handle);
    }

    pub fn truncate(self: FilesystemInterface, handle: FileHandle, size: u64) !void {
        return self.vtable.truncate(self.ptr, handle, size);
    }
};

pub const FileHandle = struct {
    id: u64,
    path: []const u8,
};

pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
};

// Real filesystem implementation
pub const RealFilesystem = struct {
    allocator: std.mem.Allocator,
    next_handle_id: u64 = 1,
    open_files: std.HashMap(u64, std.fs.File, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) RealFilesystem {
        return RealFilesystem{
            .allocator = allocator,
            .open_files = std.HashMap(u64, std.fs.File, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *RealFilesystem) void {
        // Close any remaining open files
        var iterator = self.open_files.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.close();
        }
        self.open_files.deinit();
    }

    pub fn interface(self: *RealFilesystem) FilesystemInterface {
        return FilesystemInterface{
            .ptr = self,
            .vtable = &.{
                .open = open,
                .close = close,
                .read = read,
                .write = write,
                .flush = flush,
                .sync = sync,
                .seek = seek,
                .get_size = get_size,
                .truncate = truncate,
            },
        };
    }

    fn open(ctx: *anyopaque, path: []const u8, flags: OpenFlags) anyerror!FileHandle {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        var open_flags: std.fs.File.OpenFlags = .{};
        if (flags.read and flags.write) {
            open_flags.mode = .read_write;
        } else if (flags.write) {
            open_flags.mode = .write_only;
        } else {
            open_flags.mode = .read_only;
        }

        const file = if (flags.create) 
            std.fs.createFileAbsolute(path, .{
                .read = flags.read,
                .truncate = flags.truncate,
            }) catch |err| switch (err) {
                error.AccessDenied => return FilesystemError.PermissionDenied,
                error.DeviceBusy => return FilesystemError.DeviceBusy,
                else => return err,
            }
        else
            std.fs.openFileAbsolute(path, open_flags) catch |err| switch (err) {
                error.FileNotFound => return FilesystemError.FileNotFound,
                error.AccessDenied => return FilesystemError.PermissionDenied,
                error.DeviceBusy => return FilesystemError.DeviceBusy,
                else => return err,
            };

        const handle_id = self.next_handle_id;
        self.next_handle_id += 1;

        try self.open_files.put(handle_id, file);

        return FileHandle{
            .id = handle_id,
            const duplicated_path = try self.allocator.dupe(u8, path);
            defer if (handle_id == undefined) self.allocator.free(duplicated_path);
            .path = duplicated_path,
        };
    }

    fn close(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.open_files.fetchRemove(handle.id)) |entry| {
            entry.value.close();
            self.allocator.free(handle.path);
        }
    }

    fn read(ctx: *anyopaque, handle: FileHandle, buffer: []u8) anyerror!usize {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        return file.readAll(buffer) catch |err| switch (err) {
            error.InputOutput => return FilesystemError.IoError,
            error.AccessDenied => return FilesystemError.PermissionDenied,
            else => return err,
        };
    }

    fn write(ctx: *anyopaque, handle: FileHandle, data: []const u8) anyerror!usize {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        file.writeAll(data) catch |err| switch (err) {
            error.NoSpaceLeft => return FilesystemError.DiskFull,
            error.InputOutput => return FilesystemError.IoError,
            error.AccessDenied => return FilesystemError.PermissionDenied,
            else => return err,
        };
        return data.len;
    }

    fn flush(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        file.sync() catch |err| switch (err) {
            else => return err,
        };
    }

    fn sync(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        return flush(ctx, handle);
    }

    fn seek(ctx: *anyopaque, handle: FileHandle, offset: u64) anyerror!void {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        file.seekTo(offset) catch |err| switch (err) {
            else => return err,
        };
    }

    fn get_size(ctx: *anyopaque, handle: FileHandle) anyerror!u64 {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        return file.getEndPos() catch |err| switch (err) {
            else => return err,
        };
    }

    fn truncate(ctx: *anyopaque, handle: FileHandle, size: u64) anyerror!void {
        const self: *RealFilesystem = @ptrCast(@alignCast(ctx));
        
        const file = self.open_files.get(handle.id) orelse return FilesystemError.FileNotFound;
        file.setEndPos(size) catch |err| switch (err) {
            error.AccessDenied => return FilesystemError.PermissionDenied,
            else => return err,
        };
    }
};

// Simulated filesystem with controllable failures
pub const SimulatedFilesystem = struct {
    allocator: std.mem.Allocator,
    real_fs: RealFilesystem,
    error_conditions: std.HashMap(ErrorConditionKey, FilesystemError, ErrorConditionContext, std.hash_map.default_max_load_percentage),
    operation_count: std.HashMap(ErrorConditionKey, u32, ErrorConditionContext, std.hash_map.default_max_load_percentage),

    const ErrorConditionKey = struct {
        operation: FileOperationType,
        path_pattern: []const u8, // Simple glob pattern like "*.wal" or exact path
    };

    const ErrorConditionContext = struct {
        pub fn hash(self: @This(), key: ErrorConditionKey) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.operation));
            hasher.update(key.path_pattern);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: ErrorConditionKey, b: ErrorConditionKey) bool {
            _ = self;
            return a.operation == b.operation and std.mem.eql(u8, a.path_pattern, b.path_pattern);
        }
    };

    pub fn init(allocator: std.mem.Allocator) SimulatedFilesystem {
        return SimulatedFilesystem{
            .allocator = allocator,
            .real_fs = RealFilesystem.init(allocator),
            .error_conditions = std.HashMap(ErrorConditionKey, FilesystemError, ErrorConditionContext, std.hash_map.default_max_load_percentage).init(allocator),
            .operation_count = std.HashMap(ErrorConditionKey, u32, ErrorConditionContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *SimulatedFilesystem) void {
        self.clear_error_conditions();
        self.real_fs.deinit();
    }

    pub fn interface(self: *SimulatedFilesystem) FilesystemInterface {
        return FilesystemInterface{
            .ptr = self,
            .vtable = &.{
                .open = sim_open,
                .close = sim_close,
                .read = sim_read,
                .write = sim_write,
                .flush = sim_flush,
                .sync = sim_sync,
                .seek = sim_seek,
                .get_size = sim_get_size,
                .truncate = sim_truncate,
            },
        };
    }

    pub fn set_error_condition(self: *SimulatedFilesystem, operation: FileOperationType, path_pattern: []const u8, error_type: FilesystemError) !void {
        const key = ErrorConditionKey{
            .operation = operation,
            .path_pattern = try self.allocator.dupe(u8, path_pattern),
        };
        try self.error_conditions.put(key, error_type);
    }

    pub fn clear_error_conditions(self: *SimulatedFilesystem) void {
        var iterator = self.error_conditions.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.path_pattern);
        }
        self.error_conditions.clearAndFree();
        self.operation_count.clearAndFree();
    }

    fn check_for_error(self: *SimulatedFilesystem, operation: FileOperationType, path: []const u8) ?FilesystemError {
        var iterator = self.error_conditions.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr;
            const error_type = entry.value_ptr.*;

            if (key.operation == operation) {
                // Simple pattern matching - exact match or *.extension
                const matches = if (std.mem.startsWith(u8, key.path_pattern, "*.")) blk: {
                    const extension = key.path_pattern[1..]; // Remove "*"
                    break :blk std.mem.endsWith(u8, path, extension);
                } else std.mem.eql(u8, key.path_pattern, path);

                if (matches) {
                    // Track operation count for this condition
                    const count = self.operation_count.get(key.*) orelse 0;
                    self.operation_count.put(key.*, count + 1) catch {};
                    return error_type;
                }
            }
        }
        return null;
    }

    fn sim_open(ctx: *anyopaque, path: []const u8, flags: OpenFlags) anyerror!FileHandle {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.open, path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().open(path, flags);
    }

    fn sim_close(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.close, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().close(handle);
    }

    fn sim_read(ctx: *anyopaque, handle: FileHandle, buffer: []u8) anyerror!usize {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.read, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().read(handle, buffer);
    }

    fn sim_write(ctx: *anyopaque, handle: FileHandle, data: []const u8) anyerror!usize {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.write, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().write(handle, data);
    }

    fn sim_flush(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.flush, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().flush(handle);
    }

    fn sim_sync(ctx: *anyopaque, handle: FileHandle) anyerror!void {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.sync, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().sync(handle);
    }

    fn sim_seek(ctx: *anyopaque, handle: FileHandle, offset: u64) anyerror!void {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.seek, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().seek(handle, offset);
    }

    fn sim_get_size(ctx: *anyopaque, handle: FileHandle) anyerror!u64 {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.get_size, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().get_size(handle);
    }

    fn sim_truncate(ctx: *anyopaque, handle: FileHandle, size: u64) anyerror!void {
        const self: *SimulatedFilesystem = @ptrCast(@alignCast(ctx));
        
        if (self.check_for_error(.truncate, handle.path)) |err| {
            return err;
        }
        
        return self.real_fs.interface().truncate(handle, size);
    }
};

test "Real filesystem basic operations" {
    var real_fs = RealFilesystem.init(std.testing.allocator);
    defer real_fs.deinit();

    const fs = real_fs.interface();
    const test_path = "/tmp/test_real_fs.txt";

    // Clean up any existing file
    std.fs.deleteFileAbsolute(test_path) catch {};
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    // Test create and write
    const handle = try fs.open(test_path, .{ .write = true, .create = true });
    defer fs.close(handle) catch {};

    const test_data = "Hello, World!";
    const bytes_written = try fs.write(handle, test_data);
    try std.testing.expect(bytes_written == test_data.len);

    try fs.flush(handle);
}

test "Simulated filesystem error injection" {
    var sim_fs = SimulatedFilesystem.init(std.testing.allocator);
    defer sim_fs.deinit();

    // Set up error condition: all writes to .wal files should fail with disk full
    try sim_fs.set_error_condition(.write, "*.wal", FilesystemError.DiskFull);

    const fs = sim_fs.interface();
    const test_path = "/tmp/test_sim_fs.wal";

    // Clean up any existing file
    std.fs.deleteFileAbsolute(test_path) catch {};
    defer std.fs.deleteFileAbsolute(test_path) catch {};

    // Open should succeed
    const handle = try fs.open(test_path, .{ .write = true, .create = true });
    defer fs.close(handle) catch {};

    // Write should fail with DiskFull error
    const test_data = "Hello, World!";
    const result = fs.write(handle, test_data);
    try std.testing.expectError(FilesystemError.DiskFull, result);
}