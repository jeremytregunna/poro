// ABOUTME: Simulation runner executable for testing database scenarios
// ABOUTME: Provides command-line interface to run deterministic database simulations
const std = @import("std");
const simulation = @import("simulation.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();

    // Create temporary directory for simulation files
    const temp_dir = "/tmp/poro_sim";
    std.fs.makeDirAbsolute(temp_dir) catch {};

    // Parse seed if provided, otherwise use random seed
    var seed: u64 = blk: {
        var buf: [8]u8 = undefined;
        std.crypto.random.bytes(buf[0..]);
        break :blk std.mem.readInt(u64, &buf, .little);
    };
    var arg_offset: usize = 1;
    
    if (args.len > 2 and std.mem.eql(u8, args[1], "--seed")) {
        seed = std.fmt.parseInt(u64, args[2], 10) catch {
            try stdout.print("Error: Invalid seed value '{s}'\n", .{args[2]});
            return;
        };
        arg_offset = 3;
    }

    var simulator = simulation.Simulator.initWithSeed(allocator, temp_dir, seed);

    if (args.len > arg_offset and std.mem.eql(u8, args[arg_offset], "--scenario")) {
        if (args.len < arg_offset + 1) {
            try stdout.print("Usage: sim_runner [--seed <number>] --scenario <scenario_name>\n", .{});
            try stdout.print("Available scenarios: perfect, corruption, completion_corruption, massive, random, truncation, comprehensive, filesystem\n", .{});
            return;
        }

        const scenario_name = args[arg_offset + 1];
        const scenario = if (std.mem.eql(u8, scenario_name, "perfect"))
            simulation.perfect_conditions_scenario
        else if (std.mem.eql(u8, scenario_name, "corruption"))
            simulation.wal_corruption_scenario
        else if (std.mem.eql(u8, scenario_name, "completion_corruption"))
            simulation.completion_wal_corruption_scenario
        else if (std.mem.eql(u8, scenario_name, "massive"))
            simulation.massive_data_scenario
        else if (std.mem.eql(u8, scenario_name, "random"))
            simulation.random_corruption_scenario
        else if (std.mem.eql(u8, scenario_name, "truncation"))
            simulation.truncation_scenario
        else if (std.mem.eql(u8, scenario_name, "comprehensive"))
            simulation.comprehensive_system_scenario
        else if (std.mem.eql(u8, scenario_name, "filesystem"))
            simulation.filesystem_error_simulation_scenario
        else {
            try stdout.print("Unknown scenario: {s}\n", .{scenario_name});
            try stdout.print("Available scenarios: perfect, corruption, completion_corruption, massive, random, truncation, comprehensive, filesystem\n", .{});
            return;
        };

        try stdout.print("Running scenario: {s} (seed: {})\n", .{ scenario.name, seed });
        try stdout.print("Description: {s}\n\n", .{scenario.description});

        const result = try simulator.run_scenario(scenario);
        try stdout.print("{}\n", .{result});

        if (!result.success) {
            std.process.exit(1);
        }
    } else {
        // Run all predefined scenarios
        try stdout.print("Poro Database Simulation Runner (seed: {})\n", .{seed});
        try stdout.print("===============================\n\n", .{});

        const scenarios = [_]simulation.SimulationScenario{
            simulation.perfect_conditions_scenario,
            simulation.wal_corruption_scenario,
            simulation.completion_wal_corruption_scenario,
            simulation.massive_data_scenario,
            simulation.random_corruption_scenario,
            simulation.truncation_scenario,
            simulation.comprehensive_system_scenario,
            simulation.filesystem_error_simulation_scenario,
        };

        const results = try simulator.run_scenarios(&scenarios);
        defer allocator.free(results);

        var all_passed = true;
        for (results) |result| {
            try stdout.print("{}\n", .{result});
            if (!result.success) {
                all_passed = false;
            }
        }

        try stdout.print("\n=== Summary ===\n", .{});
        if (all_passed) {
            try stdout.print("All scenarios PASSED ✓\n", .{});
        } else {
            try stdout.print("Some scenarios FAILED ✗\n", .{});
            std.process.exit(1);
        }
    }

    // Clean up temporary files
    std.fs.deleteTreeAbsolute(temp_dir) catch {};
}