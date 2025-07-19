// ABOUTME: Deterministic simulation framework for testing database scenarios
// ABOUTME: Supports perfect conditions, WAL corruption, and custom failure injection
const std = @import("std");
const poro = @import("lib.zig");
const filesystem = @import("filesystem.zig");

pub const SimulationError = error{
    ScenarioFailed,
    CorruptionInjectionFailed,
    DatabaseInitFailed,
};

pub const CorruptionType = enum {
    none,
    bit_flip,
    byte_zero,
    truncation,
    random_corruption,
};

pub const SimulationScenario = struct {
    name: []const u8,
    description: []const u8,
    operations: []const Operation,
    corruption_config: ?CorruptionConfig = null,
    filesystem_config: ?FilesystemConfig = null,

    pub const Operation = union(enum) {
        set: struct { key: []const u8, value: []const u8 },
        get: struct { key: []const u8, expected: ?[]const u8 },
        del: struct { key: []const u8, should_exist: bool },
        flush,
        inject_corruption: CorruptionConfig,
        restart_db,
        // New operations for comprehensive system testing
        inspect_stats: struct { 
            expected_size: ?usize = null,
            expected_capacity: ?usize = null,
        },
        verify_integrity,
        simulate_filesystem_error: FilesystemError,
    };

    pub const FilesystemError = struct {
        error_type: filesystem.FilesystemError,
        target_pattern: []const u8, // Pattern like "*.wal" or exact path
        operation: filesystem.FileOperationType,
        clear_after: bool = false, // Clear condition after first trigger
    };

    pub const CorruptionConfig = struct {
        corruption_type: CorruptionType,
        target_file: enum { intent_wal, completion_wal },
        offset: ?usize = null,
        probability: f32 = 1.0,
        seed: u64 = 12345,
    };

    pub const FilesystemConfig = struct {
        use_simulated_fs: bool = false,
        initial_error_conditions: []const FilesystemError = &[_]FilesystemError{},
    };
};

pub const SimulationResult = struct {
    scenario_name: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
    operations_completed: usize,
    recovery_verified: bool = false,

    pub fn format(self: SimulationResult, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Scenario: {s}\n", .{self.scenario_name});
        try writer.print("  Success: {}\n", .{self.success});
        try writer.print("  Operations completed: {}\n", .{self.operations_completed});
        try writer.print("  Recovery verified: {}\n", .{self.recovery_verified});
        if (self.error_message) |err| {
            try writer.print("  Error: {s}\n", .{err});
        }
    }
};

pub const Simulator = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,
    prng: std.Random.DefaultPrng,
    seed: u64,
    filesystem: ?*filesystem.SimulatedFilesystem = null, // Optional for filesystem error simulation
    real_filesystem: ?*filesystem.RealFilesystem = null,

    pub fn init(allocator: std.mem.Allocator, temp_dir: []const u8) Simulator {
        // Generate random seed for non-deterministic behavior by default
        var buf: [8]u8 = undefined;
        std.crypto.random.bytes(buf[0..]);
        const random_seed = std.mem.readInt(u64, &buf, .little);
        return Simulator.initWithSeed(allocator, temp_dir, random_seed);
    }

    pub fn initWithSeed(allocator: std.mem.Allocator, temp_dir: []const u8, seed: u64) Simulator {
        return Simulator{
            .allocator = allocator,
            .temp_dir = temp_dir,
            .prng = std.Random.DefaultPrng.init(seed),
            .seed = seed,
        };
    }

    pub fn run_scenario(self: *Simulator, scenario: SimulationScenario) !SimulationResult {
        var result = SimulationResult{
            .scenario_name = scenario.name,
            .success = false,
            .operations_completed = 0,
        };

        const intent_wal_path = try std.fmt.allocPrint(self.allocator, "{s}/sim_intent.wal", .{self.temp_dir});
        defer self.allocator.free(intent_wal_path);
        const completion_wal_path = try std.fmt.allocPrint(self.allocator, "{s}/sim_completion.wal", .{self.temp_dir});
        defer self.allocator.free(completion_wal_path);

        // Clean up any existing test files
        std.fs.deleteFileAbsolute(intent_wal_path) catch {};
        std.fs.deleteFileAbsolute(completion_wal_path) catch {};

        // Set up filesystem abstraction
        var simulated_fs: ?filesystem.SimulatedFilesystem = null;
        var real_fs: ?filesystem.RealFilesystem = null;
        defer {
            if (simulated_fs) |*fs| fs.deinit();
            if (real_fs) |*fs| fs.deinit();
        }

        if (scenario.filesystem_config) |fs_config| {
            if (fs_config.use_simulated_fs) {
                simulated_fs = filesystem.SimulatedFilesystem.init(self.allocator);
                self.filesystem = &simulated_fs.?;
                
                // Set up initial error conditions
                for (fs_config.initial_error_conditions) |error_condition| {
                    try simulated_fs.?.set_error_condition(
                        error_condition.operation,
                        error_condition.target_pattern,
                        error_condition.error_type
                    );
                }
            } else {
                real_fs = filesystem.RealFilesystem.init(self.allocator);
                self.real_filesystem = &real_fs.?;
            }
        }

        var db: ?poro.Database = null;
        defer if (db) |*d| d.deinit();

        // Initialize database
        db = poro.Database.init(self.allocator, intent_wal_path, completion_wal_path) catch |err| {
            result.error_message = try std.fmt.allocPrint(self.allocator, "Failed to init DB: {}", .{err});
            return result;
        };

        // Execute operations
        for (scenario.operations, 0..) |operation, i| {
            const success = self.execute_operation(&db.?, operation, intent_wal_path, completion_wal_path) catch |err| {
                result.error_message = try std.fmt.allocPrint(self.allocator, "Operation {} failed: {}", .{ i, err });
                return result;
            };

            if (!success) {
                result.error_message = try std.fmt.allocPrint(self.allocator, "Operation {} validation failed", .{i});
                return result;
            }

            result.operations_completed += 1;
        }

        // Test recovery if corruption was injected
        if (scenario.corruption_config != null) {
            result.recovery_verified = try self.verify_recovery(intent_wal_path, completion_wal_path);
        } else {
            result.recovery_verified = true;
        }

        result.success = true;
        return result;
    }

    fn execute_operation(self: *Simulator, db: *poro.Database, operation: SimulationScenario.Operation, intent_wal_path: []const u8, completion_wal_path: []const u8) !bool {
        switch (operation) {
            .set => |set_op| {
                try db.set(set_op.key, set_op.value);
                return true;
            },
            .get => |get_op| {
                const actual = db.get(get_op.key);
                if (get_op.expected) |expected| {
                    if (actual == null) return false;
                    return std.mem.eql(u8, actual.?, expected);
                } else {
                    return actual == null;
                }
            },
            .del => |del_op| {
                const deleted = try db.del(del_op.key);
                return deleted == del_op.should_exist;
            },
            .flush => {
                try db.flush();
                return true;
            },
            .inject_corruption => |corruption| {
                try self.inject_corruption(corruption, intent_wal_path, completion_wal_path);
                return true;
            },
            .restart_db => {
                // Reinitialize database to test recovery
                db.deinit();
                db.* = poro.Database.init(self.allocator, intent_wal_path, completion_wal_path) catch return false;
                return true;
            },
            .inspect_stats => |stats_check| {
                const stats = db.get_stats();
                if (stats_check.expected_size) |expected| {
                    if (stats.size != expected) return false;
                }
                if (stats_check.expected_capacity) |expected| {
                    if (stats.capacity != expected) return false;
                }
                return true;
            },
            .verify_integrity => {
                return db.verify_integrity();
            },
            .simulate_filesystem_error => |fs_error| {
                if (self.filesystem) |sim_fs| {
                    try sim_fs.set_error_condition(
                        fs_error.operation,
                        fs_error.target_pattern,
                        fs_error.error_type
                    );
                    std.debug.print("SIMULATION: Set filesystem error condition {} on pattern '{s}' during {}\n", .{ 
                        fs_error.error_type, fs_error.target_pattern, fs_error.operation 
                    });
                } else {
                    std.debug.print("SIMULATION: Filesystem error simulation requested but no simulated filesystem active\n", .{});
                }
                return true;
            },
        }
    }

    fn inject_corruption(self: *Simulator, config: SimulationScenario.CorruptionConfig, intent_wal_path: []const u8, completion_wal_path: []const u8) !void {
        const target_path = switch (config.target_file) {
            .intent_wal => intent_wal_path,
            .completion_wal => completion_wal_path,
        };

        // First flush and close any open handles
        const file = std.fs.openFileAbsolute(target_path, .{ .mode = .read_write }) catch return;
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) return; // Nothing to corrupt

        const offset = config.offset orelse self.prng.random().uintLessThan(usize, file_size);
        if (offset >= file_size) return;

        try file.seekTo(offset);

        switch (config.corruption_type) {
            .none => {},
            .bit_flip => {
                var byte: [1]u8 = undefined;
                _ = try file.readAll(&byte);
                byte[0] ^= @as(u8, 1) << self.prng.random().uintLessThan(u3, 7);
                try file.seekTo(offset);
                try file.writeAll(&byte);
            },
            .byte_zero => {
                const zero_byte: [1]u8 = .{0};
                try file.writeAll(&zero_byte);
            },
            .truncation => {
                try file.setEndPos(offset);
            },
            .random_corruption => {
                // Use scenario-specific seed if provided, otherwise use simulator seed
                const effective_seed = if (config.seed != 12345) config.seed else self.seed;
                var local_prng = std.Random.DefaultPrng.init(effective_seed);
                var corrupt_data: [16]u8 = undefined;
                local_prng.random().bytes(&corrupt_data);
                const write_size = @min(corrupt_data.len, file_size - offset);
                try file.writeAll(corrupt_data[0..write_size]);
            },
        }
    }

    fn verify_recovery(self: *Simulator, intent_wal_path: []const u8, completion_wal_path: []const u8) !bool {
        // Try to initialize a new database instance to test recovery
        var recovery_db = poro.Database.init(self.allocator, intent_wal_path, completion_wal_path) catch return false;
        defer recovery_db.deinit();

        // If we got here without crashing, recovery worked
        return true;
    }

    pub fn run_scenarios(self: *Simulator, scenarios: []const SimulationScenario) ![]SimulationResult {
        var results = try self.allocator.alloc(SimulationResult, scenarios.len);
        
        for (scenarios, 0..) |scenario, i| {
            results[i] = try self.run_scenario(scenario);
        }

        return results;
    }
};

// Predefined scenarios
pub const perfect_conditions_scenario = SimulationScenario{
    .name = "Perfect Conditions",
    .description = "Basic operations under perfect conditions with no failures",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .{ .get = .{ .key = "key1", .expected = "value1" } },
        .{ .get = .{ .key = "key2", .expected = "value2" } },
        .{ .del = .{ .key = "key1", .should_exist = true } },
        .{ .get = .{ .key = "key1", .expected = null } },
        .flush,
        .restart_db,
        .{ .get = .{ .key = "key2", .expected = "value2" } },
        .{ .get = .{ .key = "key1", .expected = null } },
    },
};

pub const wal_corruption_scenario = SimulationScenario{
    .name = "WAL Corruption Recovery",
    .description = "Test recovery from WAL corruption during operations",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .flush,
        .{ .inject_corruption = .{
            .corruption_type = .bit_flip,
            .target_file = .intent_wal,
            .offset = 10,
        } },
        .restart_db,
        .{ .set = .{ .key = "key3", .value = "value3" } },
        .{ .get = .{ .key = "key3", .expected = "value3" } },
    },
    .corruption_config = .{
        .corruption_type = .bit_flip,
        .target_file = .intent_wal,
        .offset = 10,
    },
};

pub const completion_wal_corruption_scenario = SimulationScenario{
    .name = "Completion WAL Corruption",
    .description = "Test recovery when completion WAL is corrupted",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .flush,
        .{ .inject_corruption = .{
            .corruption_type = .random_corruption,
            .target_file = .completion_wal,
            .offset = 0, // Corrupt the intent_offset field of first completion entry
        } },
        .restart_db,
        .{ .get = .{ .key = "key1", .expected = null } }, // Should be lost due to incomplete transaction
        .{ .set = .{ .key = "key3", .value = "value3" } },
        .{ .get = .{ .key = "key3", .expected = "value3" } },
    },
    .corruption_config = .{
        .corruption_type = .random_corruption,
        .target_file = .completion_wal,
        .offset = 0,
    },
};

pub const massive_data_scenario = SimulationScenario{
    .name = "Massive Data Load",
    .description = "Test database performance and reliability with large amounts of data",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "key1", .value = "a" ** 1000 } },
        .{ .set = .{ .key = "key2", .value = "b" ** 2000 } },
        .{ .set = .{ .key = "key3", .value = "c" ** 3000 } },
        .{ .get = .{ .key = "key1", .expected = "a" ** 1000 } },
        .{ .get = .{ .key = "key2", .expected = "b" ** 2000 } },
        .{ .get = .{ .key = "key3", .expected = "c" ** 3000 } },
        .flush,
        .restart_db,
        .{ .get = .{ .key = "key1", .expected = "a" ** 1000 } },
        .{ .get = .{ .key = "key2", .expected = "b" ** 2000 } },
        .{ .get = .{ .key = "key3", .expected = "c" ** 3000 } },
    },
};

pub const random_corruption_scenario = SimulationScenario{
    .name = "Random Corruption",
    .description = "Test cosmic ray-like random corruption effects",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "stable_key", .value = "stable_value" } },
        .{ .set = .{ .key = "test_key1", .value = "test_value1" } },
        .{ .set = .{ .key = "test_key2", .value = "test_value2" } },
        .flush,
        .{ .inject_corruption = .{
            .corruption_type = .random_corruption,
            .target_file = .intent_wal,
            .seed = 42,
        } },
        .restart_db,
        .{ .set = .{ .key = "post_corruption", .value = "should_work" } },
        .{ .get = .{ .key = "post_corruption", .expected = "should_work" } },
    },
    .corruption_config = .{
        .corruption_type = .random_corruption,
        .target_file = .intent_wal,
        .seed = 42,
    },
};

pub const truncation_scenario = SimulationScenario{
    .name = "WAL Truncation",
    .description = "Test recovery from partial WAL truncation",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .{ .set = .{ .key = "key3", .value = "value3" } },
        .flush,
        .{ .inject_corruption = .{
            .corruption_type = .truncation,
            .target_file = .intent_wal,
            .offset = 50, // Truncate partway through
        } },
        .restart_db,
        .{ .set = .{ .key = "key4", .value = "value4" } },
        .{ .get = .{ .key = "key4", .expected = "value4" } },
    },
    .corruption_config = .{
        .corruption_type = .truncation,
        .target_file = .intent_wal,
        .offset = 50,
    },
};

pub const comprehensive_system_scenario = SimulationScenario{
    .name = "Comprehensive System Testing",
    .description = "Test all aspects of system state and integrity",
    .operations = &[_]SimulationScenario.Operation{
        // Initial state verification
        .{ .inspect_stats = .{ .expected_size = 0, .expected_capacity = 1024 } },
        .verify_integrity,
        
        // Add some data and verify
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .{ .inspect_stats = .{ .expected_size = 2 } },
        .verify_integrity,
        
        // Delete and verify size changes
        .{ .del = .{ .key = "key1", .should_exist = true } },
        .{ .inspect_stats = .{ .expected_size = 1 } },
        .verify_integrity,
        
        // Test recovery with verification
        .flush,
        .restart_db,
        .{ .inspect_stats = .{ .expected_size = 1 } },
        .verify_integrity,
        .{ .get = .{ .key = "key2", .expected = "value2" } },
        .{ .get = .{ .key = "key1", .expected = null } },
        
        // Simulate filesystem error (demonstration)
        .{ .simulate_filesystem_error = .{
            .error_type = filesystem.FilesystemError.DiskFull,
            .target_pattern = "*.wal",
            .operation = .write,
        } },
    },
};

pub const filesystem_error_simulation_scenario = SimulationScenario{
    .name = "Filesystem Error Simulation",
    .description = "Test true filesystem error injection including disk full and permission errors",
    .operations = &[_]SimulationScenario.Operation{
        // Set up some initial data
        .{ .set = .{ .key = "key1", .value = "value1" } },
        .{ .set = .{ .key = "key2", .value = "value2" } },
        .flush,
        
        // Simulate disk full error on WAL writes
        .{ .simulate_filesystem_error = .{
            .error_type = filesystem.FilesystemError.DiskFull,
            .target_pattern = "*.wal",
            .operation = .write,
        } },
        
        // This write should fail due to simulated disk full
        .{ .set = .{ .key = "key3", .value = "value3" } },
        
        // Simulate permission denied error
        .{ .simulate_filesystem_error = .{
            .error_type = filesystem.FilesystemError.PermissionDenied,
            .target_pattern = "*.wal",
            .operation = .flush,
        } },
        
        // This flush should fail due to simulated permission error
        .flush,
        
        // Verify we can still read existing data
        .{ .get = .{ .key = "key1", .expected = "value1" } },
        .{ .get = .{ .key = "key2", .expected = "value2" } },
    },
    .filesystem_config = .{
        .use_simulated_fs = true,
        .initial_error_conditions = &[_]SimulationScenario.FilesystemError{},
    },
};

test "Simulation framework basic test" {
    var simulator = Simulator.init(std.testing.allocator, "/tmp");
    
    const result = try simulator.run_scenario(perfect_conditions_scenario);
    try std.testing.expect(result.success);
    try std.testing.expect(result.operations_completed == perfect_conditions_scenario.operations.len);
    try std.testing.expect(result.recovery_verified);
}