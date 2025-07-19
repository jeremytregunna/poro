// ABOUTME: Property-based testing CLI runner for database failure exploration
// ABOUTME: Provides command-line interface for running property tests with customizable parameters
const std = @import("std");
const property_testing = @import("property_testing.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();

    // Create temporary directory for property test files
    const temp_dir = "/tmp/poro_prop_test";
    std.fs.makeDirAbsolute(temp_dir) catch {};

    // Parse command line arguments
    var seed: u64 = blk: {
        var buf: [8]u8 = undefined;
        std.crypto.random.bytes(buf[0..]);
        break :blk std.mem.readInt(u64, &buf, .little);
    };
    var iterations: u32 = 50;
    var test_name: ?[]const u8 = null;
    var arg_i: usize = 1;

    while (arg_i < args.len) {
        if (std.mem.eql(u8, args[arg_i], "--seed")) {
            if (arg_i + 1 >= args.len) {
                try stdout.print("Error: --seed requires a value\n", .{});
                return;
            }
            seed = std.fmt.parseInt(u64, args[arg_i + 1], 10) catch {
                try stdout.print("Error: Invalid seed value '{s}'\n", .{args[arg_i + 1]});
                return;
            };
            arg_i += 2;
        } else if (std.mem.eql(u8, args[arg_i], "--iterations")) {
            if (arg_i + 1 >= args.len) {
                try stdout.print("Error: --iterations requires a value\n", .{});
                return;
            }
            iterations = std.fmt.parseInt(u32, args[arg_i + 1], 10) catch {
                try stdout.print("Error: Invalid iterations value '{s}'\n", .{args[arg_i + 1]});
                return;
            };
            arg_i += 2;
        } else if (std.mem.eql(u8, args[arg_i], "--test")) {
            if (arg_i + 1 >= args.len) {
                try stdout.print("Error: --test requires a value\n", .{});
                return;
            }
            test_name = args[arg_i + 1];
            arg_i += 2;
        } else if (std.mem.eql(u8, args[arg_i], "--help") or std.mem.eql(u8, args[arg_i], "-h")) {
            try print_help(stdout);
            return;
        } else {
            try stdout.print("Unknown argument: {s}\n", .{args[arg_i]});
            try print_help(stdout);
            return;
        }
    }

    const runner = property_testing.PropertyTestRunner.init(allocator, temp_dir);

    try stdout.print("Property-Based Testing Framework\n", .{});
    try stdout.print("================================\n", .{});
    try stdout.print("Seed: {}\n", .{seed});
    try stdout.print("Iterations: {}\n", .{iterations});
    try stdout.print("Temp dir: {s}\n\n", .{temp_dir});

    if (test_name) |name| {
        // Run specific test
        const test_config = get_test_by_name(name, seed) orelse {
            try stdout.print("Unknown test: {s}\n", .{name});
            try print_available_tests(stdout);
            return;
        };

        try stdout.print("Running test: {s}\n", .{test_config.name});
        try runner.run_test(test_config, iterations);
    } else {
        // Run all tests
        const tests = get_all_tests(seed);
        
        try stdout.print("Running {} property tests...\n\n", .{tests.len});
        
        var passed: u32 = 0;
        var failed: u32 = 0;
        
        for (tests) |test_config| {
            try stdout.print("--- Running: {s} ---\n", .{test_config.name});
            
            const result = runner.run_test(test_config, iterations);
            result catch |err| {
                try stdout.print("❌ FAILED: {s} - {}\n\n", .{ test_config.name, err });
                failed += 1;
                continue;
            };
            
            try stdout.print("✅ PASSED: {s}\n\n", .{test_config.name});
            passed += 1;
        }
        
        try stdout.print("=== Property Test Summary ===\n", .{});
        try stdout.print("Passed: {}\n", .{passed});
        try stdout.print("Failed: {}\n", .{failed});
        try stdout.print("Total:  {}\n", .{tests.len});
        
        if (failed > 0) {
            std.process.exit(1);
        }
    }

    // Clean up temporary files
    std.fs.deleteTreeAbsolute(temp_dir) catch {};
}

fn print_help(writer: anytype) !void {
    try writer.print("Property-Based Testing Framework\n\n", .{});
    try writer.print("USAGE:\n", .{});
    try writer.print("    prop_runner [OPTIONS]\n\n", .{});
    try writer.print("OPTIONS:\n", .{});
    try writer.print("    --seed <number>        Set random seed for deterministic testing\n", .{});
    try writer.print("    --iterations <number>  Number of test iterations (default: 50)\n", .{});
    try writer.print("    --test <name>          Run specific test by name\n", .{});
    try writer.print("    --help, -h             Show this help message\n\n", .{});
    try writer.print("AVAILABLE TESTS:\n", .{});
    try print_available_tests(writer);
}

fn print_available_tests(writer: anytype) !void {
    try writer.print("    basic               - Basic operations with failure injection\n", .{});
    try writer.print("    collision           - Hash collision stress testing\n", .{});
    try writer.print("    exhaustion          - Hash table exhaustion testing\n", .{});
    try writer.print("    wal_stress          - WAL corruption and io_uring stress testing\n", .{});
    try writer.print("    memory_exhaustion   - Memory allocation exhaustion testing\n", .{});
    try writer.print("    recovery            - Recovery process stress testing\n", .{});
    try writer.print("    memory_pressure     - Memory allocation failure testing\n", .{});
}

fn get_test_by_name(name: []const u8, seed: u64) ?property_testing.PropertyTest {
    if (std.mem.eql(u8, name, "basic")) {
        var test_config = property_testing.basic_property_test;
        test_config.seed = seed;
        return test_config;
    } else if (std.mem.eql(u8, name, "collision")) {
        var test_config = property_testing.collision_stress_test;
        test_config.seed = seed;
        return test_config;
    } else if (std.mem.eql(u8, name, "exhaustion")) {
        var test_config = property_testing.hash_exhaustion_test;
        test_config.seed = seed;
        return test_config;
    } else if (std.mem.eql(u8, name, "wal_stress")) {
        var test_config = property_testing.wal_stress_test;
        test_config.seed = seed;
        return test_config;
    } else if (std.mem.eql(u8, name, "memory_exhaustion")) {
        var test_config = property_testing.memory_exhaustion_test;
        test_config.seed = seed;
        return test_config;
    } else if (std.mem.eql(u8, name, "recovery")) {
        const test_config = create_recovery_stress_test(seed);
        return test_config;
    } else if (std.mem.eql(u8, name, "memory_pressure")) {
        const test_config = create_memory_pressure_test(seed);
        return test_config;
    }
    return null;
}

fn get_all_tests(seed: u64) []const property_testing.PropertyTest {
    // Use a static variable to avoid returning a dangling pointer
    const static = struct {
        var tests: [7]property_testing.PropertyTest = undefined;
    };
    
    static.tests[0] = blk: {
        var test_config = property_testing.basic_property_test;
        test_config.seed = seed;
        break :blk test_config;
    };
    static.tests[1] = blk: {
        var test_config = property_testing.collision_stress_test;
        test_config.seed = seed; // Use same seed for deterministic testing
        break :blk test_config;
    };
    static.tests[2] = blk: {
        var test_config = property_testing.hash_exhaustion_test;
        test_config.seed = seed; // Use same seed for deterministic testing
        break :blk test_config;
    };
    static.tests[3] = blk: {
        var test_config = property_testing.wal_stress_test;
        test_config.seed = seed; // Use same seed for deterministic testing
        break :blk test_config;
    };
    static.tests[4] = blk: {
        var test_config = property_testing.memory_exhaustion_test;
        test_config.seed = seed; // Use same seed for deterministic testing
        break :blk test_config;
    };
    static.tests[5] = create_recovery_stress_test(seed);
    static.tests[6] = create_memory_pressure_test(seed);
    
    return &static.tests;
}

fn create_recovery_stress_test(seed: u64) property_testing.PropertyTest {
    return property_testing.PropertyTest{
        .name = "recovery_stress",
        .generators = .{
            .operation_distribution = .{
                .set_probability = 0.3,
                .get_probability = 0.2,
                .del_probability = 0.1,
                .flush_probability = 0.2,
                .restart_probability = 0.2, // High restart frequency
            },
            .sequence_length = .{ .min = 100, .max = 1000 },
        },
        .failure_injectors = .{
            .allocator_failure_probability = 0.002,
            .filesystem_error_probability = 0.01,
            .conditional_multipliers = &[_]property_testing.ConditionalMultiplier{
                .{ .condition = .during_recovery, .multiplier = 20.0 },
                .{ .condition = .during_flush, .multiplier = 5.0 },
            },
        },
        .invariants = &property_testing.builtin_invariants,
        .shrinking = .{
            .max_shrink_attempts = 100,
            .preserve_failure_conditions = true,
        },
        .seed = seed,
        .allocator = undefined,
        .prng = undefined,
        .stats = .{},
    };
}

fn create_memory_pressure_test(seed: u64) property_testing.PropertyTest {
    return property_testing.PropertyTest{
        .name = "memory_pressure",
        .generators = .{
            .value_generators = .{ .variable_size = .{ .min = 512, .max = 4096 } }, // Larger values
            .sequence_length = .{ .min = 500, .max = 2000 },
        },
        .failure_injectors = .{
            .allocator_failure_probability = 0.05, // High allocation failure rate
            .conditional_multipliers = &[_]property_testing.ConditionalMultiplier{
                .{ .condition = .hash_table_resize, .multiplier = 50.0 },
            },
        },
        .invariants = &property_testing.builtin_invariants,
        .shrinking = .{
            .max_shrink_attempts = 200,
        },
        .seed = seed,
        .allocator = undefined,
        .prng = undefined,
        .stats = .{},
    };
}