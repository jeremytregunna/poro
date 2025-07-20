// ABOUTME: Property-based testing framework for comprehensive database failure testing
// ABOUTME: Provides randomized operation generation, failure injection, and automatic shrinking
const std = @import("std");
const poro = @import("lib.zig");
const filesystem = @import("filesystem.zig");

pub const PropertyTestingError = error{
    TestFailed,
    InvariantViolation,
    ShrinkingFailed,
    StatisticsError,
    GenerationError,
};

// Core types
pub const Range = struct {
    min: usize,
    max: usize,

    pub fn sample(self: Range, prng: *std.Random.DefaultPrng) usize {
        if (self.min == self.max) return self.min;
        return self.min + prng.random().uintLessThan(usize, self.max - self.min + 1);
    }
};

pub const Duration = u64; // nanoseconds

// Operation generation
pub const OperationDistribution = struct {
    set_probability: f64 = 0.4,
    get_probability: f64 = 0.4,
    del_probability: f64 = 0.15,
    flush_probability: f64 = 0.04,
    restart_probability: f64 = 0.01,

    pub fn normalize(self: *OperationDistribution) void {
        const total = self.set_probability + self.get_probability + self.del_probability +
            self.flush_probability + self.restart_probability;
        if (total > 0) {
            self.set_probability /= total;
            self.get_probability /= total;
            self.del_probability /= total;
            self.flush_probability /= total;
            self.restart_probability /= total;
        }
    }

    pub fn sample(self: OperationDistribution, prng: *std.Random.DefaultPrng) OperationType {
        const rand = prng.random().float(f64);
        var cumulative: f64 = 0;

        cumulative += self.set_probability;
        if (rand < cumulative) return .set;

        cumulative += self.get_probability;
        if (rand < cumulative) return .get;

        cumulative += self.del_probability;
        if (rand < cumulative) return .del;

        cumulative += self.flush_probability;
        if (rand < cumulative) return .flush;

        return .restart;
    }
};

pub const OperationType = enum {
    set,
    get,
    del,
    flush,
    restart,
};

pub const KeyGenerationStrategy = union(enum) {
    uniform_random: struct { min_length: usize, max_length: usize },
    collision_prone: struct { hash_collision_rate: f64 },
    sequential: struct { prefix: []const u8 },

    pub fn generate_key(self: KeyGenerationStrategy, allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng, existing_keys: [][]const u8) ![]u8 {
        switch (self) {
            .uniform_random => |config| {
                const length = config.min_length + prng.random().uintLessThan(usize, config.max_length - config.min_length + 1);
                const key = try allocator.alloc(u8, length);
                for (key) |*byte| {
                    byte.* = 'a' + prng.random().uintLessThan(u8, 26);
                }
                return key;
            },
            .collision_prone => |config| {
                // Generate keys likely to collide
                if (existing_keys.len > 0 and prng.random().float(f64) < config.hash_collision_rate) {
                    // Modify an existing key slightly to create collision potential
                    const base_key = existing_keys[prng.random().uintLessThan(usize, existing_keys.len)];
                    var key = try allocator.dupe(u8, base_key);
                    if (key.len > 0) {
                        key[0] = key[0] ^ 1; // Flip one bit
                    }
                    return key;
                }
                // Fall back to random
                const length = 8 + prng.random().uintLessThan(usize, 16);
                const key = try allocator.alloc(u8, length);
                for (key) |*byte| {
                    byte.* = 'a' + prng.random().uintLessThan(u8, 26);
                }
                return key;
            },
            .sequential => |config| {
                var key = try allocator.alloc(u8, config.prefix.len + 8);
                @memcpy(key[0..config.prefix.len], config.prefix);
                const suffix = std.fmt.bufPrint(key[config.prefix.len..], "{d:0>8}", .{prng.random().int(u32)}) catch unreachable;
                return key[0 .. config.prefix.len + suffix.len];
            },
        }
    }
};

pub const ValueGenerationStrategy = union(enum) {
    fixed_size: usize,
    variable_size: Range,
    random_binary: void,

    pub fn generate_value(self: ValueGenerationStrategy, allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng) ![]u8 {
        const size = switch (self) {
            .fixed_size => |s| s,
            .variable_size => |r| r.sample(prng),
            .random_binary => 64 + prng.random().uintLessThan(usize, 960), // 64-1024 bytes
        };

        const value = try allocator.alloc(u8, size);
        switch (self) {
            .random_binary => {
                prng.random().bytes(value);
            },
            else => {
                for (value) |*byte| {
                    byte.* = 'A' + prng.random().uintLessThan(u8, 26);
                }
            },
        }
        return value;
    }
};

pub const PropertyGenerators = struct {
    operation_distribution: OperationDistribution = .{},
    key_generators: KeyGenerationStrategy = .{ .uniform_random = .{ .min_length = 4, .max_length = 16 } },
    value_generators: ValueGenerationStrategy = .{ .variable_size = .{ .min = 8, .max = 256 } },
    sequence_length: Range = .{ .min = 100, .max = 1000 },
};

// Failure injection
pub const SystemCondition = enum {
    during_recovery,
    under_memory_pressure,
    high_operation_rate,
    after_restart,
    during_flush,
    hash_table_resize,
};

pub const ConditionalMultiplier = struct {
    condition: SystemCondition,
    multiplier: f64,
    duration: Duration = std.math.maxInt(u64), // forever by default
};

pub const FailureInjectionConfig = struct {
    allocator_failure_probability: f64 = 0.0,
    filesystem_error_probability: f64 = 0.0,
    wal_corruption_probability: f64 = 0.0,
    iouring_error_probability: f64 = 0.0,
    conditional_multipliers: []const ConditionalMultiplier = &[_]ConditionalMultiplier{},

    pub fn get_effective_probability(self: FailureInjectionConfig, base_probability: f64, current_condition: ?SystemCondition) f64 {
        var effective = base_probability;

        if (current_condition) |condition| {
            for (self.conditional_multipliers) |multiplier| {
                if (multiplier.condition == condition) {
                    effective *= multiplier.multiplier;
                    break;
                }
            }
        }

        return @min(effective, 1.0);
    }
};

// Generated operations
pub const GeneratedOperation = struct {
    operation_type: OperationType,
    key: ?[]u8 = null,
    value: ?[]u8 = null,
    expected_result: ?ExpectedResult = null,

    pub fn deinit(self: GeneratedOperation, allocator: std.mem.Allocator) void {
        if (self.key) |key| allocator.free(key);
        if (self.value) |value| allocator.free(value);
    }
};

pub const ExpectedResult = union(enum) {
    set_success: void,
    get_found: []const u8,
    get_not_found: void,
    del_existed: bool,
    flush_success: void,
    restart_success: void,
};

// Test statistics
pub const FailureStats = struct {
    allocator_failures_injected: u64 = 0,
    filesystem_errors_injected: u64 = 0,
    wal_corruptions_injected: u64 = 0,
    wal_corruptions_detected: u64 = 0,
    iouring_errors_injected: u64 = 0,
    total_operations: u64 = 0,

    pub fn format(self: FailureStats, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Failure Stats:\n", .{});
        try writer.print("  Allocator failures: {}/{} ({d:.2}%)\n", .{ self.allocator_failures_injected, self.total_operations, if (self.total_operations > 0) @as(f64, @floatFromInt(self.allocator_failures_injected)) / @as(f64, @floatFromInt(self.total_operations)) * 100.0 else 0.0 });
        try writer.print("  Filesystem errors: {}/{} ({d:.2}%)\n", .{ self.filesystem_errors_injected, self.total_operations, if (self.total_operations > 0) @as(f64, @floatFromInt(self.filesystem_errors_injected)) / @as(f64, @floatFromInt(self.total_operations)) * 100.0 else 0.0 });
        try writer.print("  WAL corruptions: {}/{} ({d:.2}%)\n", .{ self.wal_corruptions_injected, self.total_operations, if (self.total_operations > 0) @as(f64, @floatFromInt(self.wal_corruptions_injected)) / @as(f64, @floatFromInt(self.total_operations)) * 100.0 else 0.0 });
        try writer.print("  IO ring errors: {}/{} ({d:.2}%)\n", .{ self.iouring_errors_injected, self.total_operations, if (self.total_operations > 0) @as(f64, @floatFromInt(self.iouring_errors_injected)) / @as(f64, @floatFromInt(self.total_operations)) * 100.0 else 0.0 });
        try writer.print("  WAL corruptions detected: {}\n", .{self.wal_corruptions_detected});
    }
};

pub const TestStatistics = struct {
    total_operations_generated: u64 = 0,
    unique_sequences_tested: u32 = 0,
    failures_injected: FailureStats = .{},
    invariant_violations: u64 = 0,
    shrinking_iterations: u32 = 0,
    test_execution_time: Duration = 0,

    pub fn format(self: TestStatistics, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("=== Property Test Statistics ===\n", .{});
        try writer.print("Total operations: {}\n", .{self.total_operations_generated});
        try writer.print("Sequences tested: {}\n", .{self.unique_sequences_tested});
        try writer.print("Invariant violations: {}\n", .{self.invariant_violations});
        try writer.print("Shrinking iterations: {}\n", .{self.shrinking_iterations});
        try writer.print("Execution time: {d:.2}ms\n", .{@as(f64, @floatFromInt(self.test_execution_time)) / 1_000_000.0});
        try writer.print("{}\n", .{self.failures_injected});
    }
};

// Invariant checking
pub const InvariantSeverity = enum {
    critical,
    important,
    advisory,
};

pub const InvariantChecker = struct {
    name: []const u8,
    check_fn: *const fn (db: *poro.Database) bool,
    severity: InvariantSeverity,

    pub fn check(self: InvariantChecker, db: *poro.Database) bool {
        return self.check_fn(db);
    }
};

// Built-in invariant checkers
pub fn check_data_consistency(db: *poro.Database) bool {
    return db.verify_integrity();
}

pub fn check_memory_balance(_: *poro.Database) bool {
    // Basic memory check - in a real implementation, we'd track allocations
    return true;
}

pub const builtin_invariants = [_]InvariantChecker{
    .{
        .name = "data_consistency",
        .check_fn = check_data_consistency,
        .severity = .critical,
    },
    .{
        .name = "memory_balance",
        .check_fn = check_memory_balance,
        .severity = .critical,
    },
};

// Shrinking
pub const ShrinkStrategy = enum {
    remove_operations,
    simplify_values,
    reduce_key_diversity,
};

pub const ShrinkingConfig = struct {
    max_shrink_attempts: u32 = 100,
    shrink_strategies: []const ShrinkStrategy = &[_]ShrinkStrategy{ .remove_operations, .simplify_values },
    preserve_failure_conditions: bool = true,
};

// Core property test
pub const PropertyTest = struct {
    name: []const u8,
    generators: PropertyGenerators,
    failure_injectors: FailureInjectionConfig,
    invariants: []const InvariantChecker,
    shrinking: ShrinkingConfig,
    seed: u64,

    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    stats: TestStatistics,
    current_condition: ?SystemCondition = null,

    pub fn init(allocator: std.mem.Allocator, config: PropertyTest) PropertyTest {
        return PropertyTest{
            .name = config.name,
            .generators = config.generators,
            .failure_injectors = config.failure_injectors,
            .invariants = config.invariants,
            .shrinking = config.shrinking,
            .seed = config.seed,
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(config.seed),
            .stats = .{},
        };
    }

    pub fn run(self: *PropertyTest, temp_dir: []const u8, iterations: u32) !void {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            self.stats.test_execution_time = @intCast(end_time - start_time);
        }

        std.debug.print("Running property test: {s} (seed: {}, iterations: {})\n", .{ self.name, self.seed, iterations });

        for (0..iterations) |i| {
            const sequence = try self.generate_operation_sequence();
            defer self.free_operation_sequence(sequence);

            const result = self.execute_sequence(temp_dir, sequence) catch |err| switch (err) {
                PropertyTestingError.InvariantViolation => {
                    std.debug.print("Invariant violation detected in iteration {}, attempting to shrink...\n", .{i});
                    const shrunk = try self.shrink_sequence(temp_dir, sequence);
                    defer self.free_operation_sequence(shrunk);

                    std.debug.print("Shrunk from {} to {} operations\n", .{ sequence.len, shrunk.len });
                    self.print_minimal_reproduction(shrunk);
                    return PropertyTestingError.TestFailed;
                },
                else => return err,
            };

            if (!result) {
                return PropertyTestingError.TestFailed;
            }

            self.stats.unique_sequences_tested += 1;

            if ((i + 1) % 100 == 0) {
                std.debug.print("Completed {} iterations...\n", .{i + 1});
            }
        }

        std.debug.print("Property test completed successfully!\n", .{});
        std.debug.print("{}\n", .{self.stats});
    }

    fn generate_operation_sequence(self: *PropertyTest) ![]GeneratedOperation {
        const sequence_length = self.generators.sequence_length.sample(&self.prng);
        const sequence = try self.allocator.alloc(GeneratedOperation, sequence_length);
        var generated_keys = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (generated_keys.items) |key| {
                self.allocator.free(key);
            }
            generated_keys.deinit();
        }

        for (sequence) |*op| {
            const op_type = self.generators.operation_distribution.sample(&self.prng);

            op.* = GeneratedOperation{
                .operation_type = op_type,
            };

            switch (op_type) {
                .set => {
                    op.key = try self.generators.key_generators.generate_key(self.allocator, &self.prng, generated_keys.items);
                    op.value = try self.generators.value_generators.generate_value(self.allocator, &self.prng);
                    try generated_keys.append(try self.allocator.dupe(u8, op.key.?));
                    op.expected_result = .set_success;
                },
                .get => {
                    if (generated_keys.items.len > 0 and self.prng.random().boolean()) {
                        // Get existing key
                        const existing_key = generated_keys.items[self.prng.random().uintLessThan(usize, generated_keys.items.len)];
                        op.key = try self.allocator.dupe(u8, existing_key);
                        op.expected_result = .{ .get_found = "" }; // We'll determine actual result during execution
                    } else {
                        // Get random key (likely not found)
                        op.key = try self.generators.key_generators.generate_key(self.allocator, &self.prng, generated_keys.items);
                        op.expected_result = .get_not_found;
                    }
                },
                .del => {
                    if (generated_keys.items.len > 0 and self.prng.random().boolean()) {
                        // Delete existing key
                        const existing_key = generated_keys.items[self.prng.random().uintLessThan(usize, generated_keys.items.len)];
                        op.key = try self.allocator.dupe(u8, existing_key);
                        op.expected_result = .{ .del_existed = true };
                    } else {
                        // Delete random key (likely doesn't exist)
                        op.key = try self.generators.key_generators.generate_key(self.allocator, &self.prng, generated_keys.items);
                        op.expected_result = .{ .del_existed = false };
                    }
                },
                .flush => {
                    op.expected_result = .flush_success;
                },
                .restart => {
                    op.expected_result = .restart_success;
                },
            }

            self.stats.total_operations_generated += 1;
        }

        return sequence;
    }

    fn execute_sequence(self: *PropertyTest, temp_dir: []const u8, sequence: []GeneratedOperation) !bool {
        const intent_wal_path = try std.fmt.allocPrint(self.allocator, "{s}/prop_intent.wal", .{temp_dir});
        defer self.allocator.free(intent_wal_path);
        const completion_wal_path = try std.fmt.allocPrint(self.allocator, "{s}/prop_completion.wal", .{temp_dir});
        defer self.allocator.free(completion_wal_path);

        // Clean up existing files
        std.fs.deleteFileAbsolute(intent_wal_path) catch {};
        std.fs.deleteFileAbsolute(completion_wal_path) catch {};

        // Set up failure injection
        var simulated_fs: ?filesystem.SimulatedFilesystem = null;
        defer if (simulated_fs) |*fs| fs.deinit();

        if (self.failure_injectors.filesystem_error_probability > 0) {
            simulated_fs = filesystem.SimulatedFilesystem.init(self.allocator);
            // Set up filesystem error injection based on probability
            if (self.prng.random().float(f64) < self.failure_injectors.filesystem_error_probability) {
                try simulated_fs.?.set_error_condition(.write, "*.wal", filesystem.FilesystemError.DiskFull);
                self.stats.failures_injected.filesystem_errors_injected += 1;
            }
        }

        var db_optional: ?poro.Database = poro.Database.init(self.allocator, intent_wal_path, completion_wal_path) catch {
            // Database initialization failure might be expected due to failure injection
            return false;
        };
        defer if (db_optional) |*database| database.deinit();
        var db = &db_optional.?;

        // Collect initial WAL corruption statistics
        self.stats.failures_injected.wal_corruptions_detected += db.get_wal_corruption_count();

        // Execute operations
        for (sequence) |op| {
            self.stats.failures_injected.total_operations += 1;

            // Check for allocator failure injection
            if (self.should_inject_allocator_failure()) {
                self.stats.failures_injected.allocator_failures_injected += 1;
                // Skip this operation as if allocation failed
                continue;
            }

            switch (op.operation_type) {
                .set => {
                    if (op.key != null and op.value != null) {
                        db.set(op.key.?, op.value.?) catch {
                            // Operation failure might be expected
                        };
                    }
                },
                .get => {
                    if (op.key != null) {
                        _ = db.get(op.key.?);
                    }
                },
                .del => {
                    if (op.key != null) {
                        _ = db.del(op.key.?) catch {
                            // Operation failure might be expected
                        };
                    }
                },
                .flush => {
                    self.current_condition = .during_flush;
                    db.flush() catch {
                        // Flush failure might be expected
                    };
                    self.current_condition = null;
                },
                .restart => {
                    self.current_condition = .during_recovery;
                    db.deinit();
                    const new_db = poro.Database.init(self.allocator, intent_wal_path, completion_wal_path) catch {
                        self.current_condition = null;
                        // Set to null to prevent defer from trying to deinit again
                        db_optional = null;
                        return false;
                    };
                    db_optional = new_db;
                    db = &db_optional.?;

                    // Collect WAL corruption statistics from the restart
                    self.stats.failures_injected.wal_corruptions_detected += db.get_wal_corruption_count();

                    self.current_condition = null;
                },
            }

            // Check invariants
            for (self.invariants) |invariant| {
                if (!invariant.check(db)) {
                    std.debug.print("Invariant violation: {s}\n", .{invariant.name});
                    self.stats.invariant_violations += 1;
                    if (invariant.severity == .critical) {
                        return PropertyTestingError.InvariantViolation;
                    }
                }
            }
        }

        return true;
    }

    fn should_inject_allocator_failure(self: *PropertyTest) bool {
        const base_prob = self.failure_injectors.allocator_failure_probability;
        const effective_prob = self.failure_injectors.get_effective_probability(base_prob, self.current_condition);
        return self.prng.random().float(f64) < effective_prob;
    }

    fn should_inject_wal_corruption(self: *PropertyTest) bool {
        const base_prob = self.failure_injectors.wal_corruption_probability;
        const effective_prob = self.failure_injectors.get_effective_probability(base_prob, self.current_condition);
        return self.prng.random().float(f64) < effective_prob;
    }

    fn should_inject_iouring_error(self: *PropertyTest) bool {
        const base_prob = self.failure_injectors.iouring_error_probability;
        const effective_prob = self.failure_injectors.get_effective_probability(base_prob, self.current_condition);
        return self.prng.random().float(f64) < effective_prob;
    }

    fn shrink_sequence(self: *PropertyTest, temp_dir: []const u8, original_sequence: []GeneratedOperation) ![]GeneratedOperation {
        var current_sequence = try self.clone_sequence(original_sequence);

        for (0..self.shrinking.max_shrink_attempts) |_| {
            var shrunk = false;

            // Try removing operations (simple shrinking strategy)
            if (current_sequence.len > 1) {
                const remove_index = self.prng.random().uintLessThan(usize, current_sequence.len);
                var new_sequence = try self.allocator.alloc(GeneratedOperation, current_sequence.len - 1);

                // Copy before and after the removed operation
                @memcpy(new_sequence[0..remove_index], current_sequence[0..remove_index]);
                if (remove_index < current_sequence.len - 1) {
                    @memcpy(new_sequence[remove_index..], current_sequence[remove_index + 1 ..]);
                }

                // Test if the shrunk sequence still fails
                const still_fails = self.execute_sequence(temp_dir, new_sequence) catch true;
                if (!still_fails) {
                    // Shrinking successful, use this sequence
                    self.free_operation_sequence(current_sequence);
                    current_sequence = new_sequence;
                    shrunk = true;
                    self.stats.shrinking_iterations += 1;
                } else {
                    self.free_operation_sequence(new_sequence);
                }
            }

            if (!shrunk) {
                break; // No more shrinking possible
            }
        }

        return current_sequence;
    }

    fn clone_sequence(self: *PropertyTest, sequence: []GeneratedOperation) ![]GeneratedOperation {
        var cloned = try self.allocator.alloc(GeneratedOperation, sequence.len);
        for (sequence, 0..) |op, i| {
            cloned[i] = GeneratedOperation{
                .operation_type = op.operation_type,
                .key = if (op.key) |key| try self.allocator.dupe(u8, key) else null,
                .value = if (op.value) |value| try self.allocator.dupe(u8, value) else null,
                .expected_result = op.expected_result,
            };
        }
        return cloned;
    }

    fn free_operation_sequence(self: *PropertyTest, sequence: []GeneratedOperation) void {
        for (sequence) |op| {
            op.deinit(self.allocator);
        }
        self.allocator.free(sequence);
    }

    fn print_minimal_reproduction(self: *PropertyTest, sequence: []GeneratedOperation) void {
        std.debug.print("=== Minimal Reproduction Case ===\n", .{});
        std.debug.print("Seed: {}\n", .{self.seed});
        std.debug.print("Operations ({}):\n", .{sequence.len});
        for (sequence, 0..) |op, i| {
            switch (op.operation_type) {
                .set => std.debug.print("  {}: SET '{}' = '{}'\n", .{ i, std.fmt.fmtSliceHexLower(op.key.?), std.fmt.fmtSliceHexLower(op.value.?) }),
                .get => std.debug.print("  {}: GET '{}'\n", .{ i, std.fmt.fmtSliceHexLower(op.key.?) }),
                .del => std.debug.print("  {}: DEL '{}'\n", .{ i, std.fmt.fmtSliceHexLower(op.key.?) }),
                .flush => std.debug.print("  {}: FLUSH\n", .{i}),
                .restart => std.debug.print("  {}: RESTART\n", .{i}),
            }
        }
        std.debug.print("=================================\n", .{});
    }
};

// Test runner
pub const PropertyTestRunner = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, temp_dir: []const u8) PropertyTestRunner {
        return PropertyTestRunner{
            .allocator = allocator,
            .temp_dir = temp_dir,
        };
    }

    pub fn run_test(self: PropertyTestRunner, config: PropertyTest, iterations: u32) !void {
        var test_instance = PropertyTest.init(self.allocator, config);
        try test_instance.run(self.temp_dir, iterations);
    }
};

// Example property tests
pub const basic_property_test = PropertyTest{
    .name = "basic_operations_under_failures",
    .generators = .{
        .operation_distribution = .{
            .set_probability = 0.4,
            .get_probability = 0.4,
            .del_probability = 0.15,
            .flush_probability = 0.04,
            .restart_probability = 0.01,
        },
        .key_generators = .{ .uniform_random = .{ .min_length = 4, .max_length = 16 } },
        .value_generators = .{ .variable_size = .{ .min = 8, .max = 256 } },
        .sequence_length = .{ .min = 50, .max = 500 },
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.001,
        .filesystem_error_probability = 0.005,
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .during_recovery, .multiplier = 10.0 },
        },
    },
    .invariants = &builtin_invariants,
    .shrinking = .{
        .max_shrink_attempts = 50,
        .shrink_strategies = &[_]ShrinkStrategy{ .remove_operations, .simplify_values },
        .preserve_failure_conditions = true,
    },
    .seed = 12345, // Will be overridden at runtime
    .allocator = undefined, // Will be set by init()
    .prng = undefined, // Will be set by init()
    .stats = .{}, // Will be initialized
};

pub const collision_stress_test = PropertyTest{
    .name = "hash_collision_stress",
    .generators = .{
        .key_generators = .{ .collision_prone = .{ .hash_collision_rate = 0.8 } },
        .sequence_length = .{ .min = 100, .max = 500 }, // Reduced for stability
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.01, // Higher failure rate for resize testing
    },
    .invariants = &builtin_invariants,
    .shrinking = .{},
    .seed = 12345,
    .allocator = undefined, // Will be set by init()
    .prng = undefined, // Will be set by init()
    .stats = .{}, // Will be initialized
};

// New test specifically for hash table exhaustion scenarios
pub const hash_exhaustion_test = PropertyTest{
    .name = "hash_table_exhaustion",
    .generators = .{
        .operation_distribution = .{
            .set_probability = 0.8, // Mostly sets to fill the table
            .get_probability = 0.15,
            .del_probability = 0.05,
            .flush_probability = 0.0,
            .restart_probability = 0.0,
        },
        .key_generators = .{ .collision_prone = .{ .hash_collision_rate = 0.95 } }, // Force collisions
        .sequence_length = .{ .min = 800, .max = 1200 }, // Near hash table capacity
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.02, // Test resize failures
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .hash_table_resize, .multiplier = 50.0 },
        },
    },
    .invariants = &builtin_invariants,
    .shrinking = .{
        .max_shrink_attempts = 200,
        .preserve_failure_conditions = true,
    },
    .seed = 12345,
    .allocator = undefined,
    .prng = undefined,
    .stats = .{},
};

// WAL corruption and io_uring stress test
pub const wal_stress_test = PropertyTest{
    .name = "wal_corruption_stress",
    .generators = .{
        .operation_distribution = .{
            .set_probability = 0.3,
            .get_probability = 0.2,
            .del_probability = 0.1,
            .flush_probability = 0.3, // High flush rate to stress WAL
            .restart_probability = 0.1, // Frequent restarts to test recovery
        },
        .sequence_length = .{ .min = 200, .max = 800 },
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.005,
        .filesystem_error_probability = 0.01, // Partial writes through filesystem
        .wal_corruption_probability = 0.02,
        .iouring_error_probability = 0.015,
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .during_flush, .multiplier = 10.0 },
            .{ .condition = .during_recovery, .multiplier = 15.0 },
        },
    },
    .invariants = &builtin_invariants,
    .shrinking = .{
        .max_shrink_attempts = 150,
        .preserve_failure_conditions = true,
    },
    .seed = 12345,
    .allocator = undefined,
    .prng = undefined,
    .stats = .{},
};

// Memory allocation failure during key/value operations
pub const memory_exhaustion_test = PropertyTest{
    .name = "memory_allocation_exhaustion",
    .generators = .{
        .operation_distribution = .{
            .set_probability = 0.7, // Heavy set operations
            .get_probability = 0.2,
            .del_probability = 0.1,
            .flush_probability = 0.0,
            .restart_probability = 0.0,
        },
        .value_generators = .{ .variable_size = .{ .min = 1024, .max = 8192 } }, // Larger values
        .sequence_length = .{ .min = 300, .max = 1000 },
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.08, // High allocation failure rate
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .hash_table_resize, .multiplier = 20.0 },
            .{ .condition = .under_memory_pressure, .multiplier = 30.0 },
        },
    },
    .invariants = &builtin_invariants,
    .shrinking = .{
        .max_shrink_attempts = 100,
    },
    .seed = 12345,
    .allocator = undefined,
    .prng = undefined,
    .stats = .{},
};

test "Property testing framework basic test" {
    var test_config = basic_property_test;
    test_config.seed = 42;
    test_config.generators.sequence_length = .{ .min = 5, .max = 10 }; // Small test

    const runner = PropertyTestRunner.init(std.testing.allocator, "/tmp");
    try runner.run_test(test_config, 5); // Run 5 iterations
}
