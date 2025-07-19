# Deterministic Simulation Testing (DST) Framework

The Poro database includes a comprehensive deterministic simulation testing framework designed to test database behavior under controlled failure conditions, including scenarios that simulate real-world issues like hardware failures, cosmic ray corruption, and system crashes.

## Overview

The DST framework provides:
- **Deterministic corruption injection** with reproducible results
- **Scenario-based testing** covering various failure modes
- **Recovery verification** to ensure data integrity
- **Seed-based randomness** for consistent test outcomes

## Architecture

### Core Components

#### Simulator (`src/simulation.zig`)
The main orchestrator that runs test scenarios and manages corruption injection.

```zig
pub const Simulator = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,
    prng: std.Random.DefaultPrng,  // Deterministic PRNG
    seed: u64,                     // Controls randomness
}
```

#### Simulation Scenarios
Pre-defined test scenarios that describe sequences of database operations and failure conditions.

```zig
pub const SimulationScenario = struct {
    name: []const u8,
    description: []const u8,
    operations: []const Operation,
    corruption_config: ?CorruptionConfig = null,
}
```

#### Operations
Atomic operations that can be performed during a scenario:
- `set` - Store key-value pair
- `get` - Retrieve and validate value
- `del` - Delete key and verify
- `flush` - Force WAL flush
- `inject_corruption` - Corrupt WAL files
- `restart_db` - Simulate database restart/recovery

## Deterministic Seed System

### How Seeds Work

The DST framework uses a pseudorandom number generator (PRNG) initialized with a seed to ensure **deterministic randomness**. This means:

1. **Same seed = Same results**: Running the same scenario with the same seed will always produce identical corruption patterns
2. **Different seeds = Different patterns**: Different seeds explore different failure scenarios
3. **Reproducible debugging**: Failed tests can be reproduced exactly using the same seed

### Seed Usage

Seeds affect the following random operations:

#### Random Corruption Content
```zig
.random_corruption => {
    var local_prng = std.Random.DefaultPrng.init(seed);
    var corrupt_data: [16]u8 = undefined;
    local_prng.random().bytes(&corrupt_data);  // Deterministic "random" bytes
}
```

#### Random Offset Selection
```zig
// When no specific offset is provided in corruption config
const offset = config.offset orelse self.prng.random().uintLessThan(usize, file_size);
```

#### Bit Flip Position
```zig
.bit_flip => {
    // Random bit position (0-6) determined by seed
    byte[0] ^= @as(u8, 1) << self.prng.random().uintLessThan(u3, 7);
}
```

### Seed Priority

1. **Scenario-specific seed**: If corruption config specifies `seed` field
2. **Simulator seed**: Provided via `--seed` argument or `initWithSeed()`
3. **Random seed**: Cryptographically secure random seed if no seed specified

## Available Scenarios

### 1. Perfect Conditions
**Purpose**: Baseline test under normal operating conditions  
**Operations**: SET, GET, DEL, flush, restart, verify recovery  
**Corruption**: None  
**Validates**: Basic functionality and recovery without failures

### 2. WAL Corruption Recovery
**Purpose**: Test recovery from intent WAL corruption  
**Corruption**: Bit flip in intent WAL at offset 10  
**Validates**: Database continues operating after WAL corruption

### 3. Completion WAL Corruption
**Purpose**: Test incomplete transaction handling  
**Corruption**: Random corruption at completion WAL offset 0  
**Validates**: Incomplete transactions are not applied during recovery

### 4. Massive Data Load
**Purpose**: Test performance and reliability with large data  
**Operations**: Large values (1KB-3KB), restart, verify  
**Validates**: Large data handling and recovery

### 5. Random Corruption (Cosmic Ray Simulation)
**Purpose**: Simulate cosmic ray-like random bit flips  
**Corruption**: Random corruption in intent WAL  
**Validates**: Graceful degradation under random failures

### 6. WAL Truncation
**Purpose**: Test recovery from partial WAL truncation  
**Corruption**: Truncate intent WAL at offset 50  
**Validates**: Recovery handles incomplete WAL files

## Usage

### Command Line Interface

#### Run All Scenarios
```bash
# Random seed (different corruption patterns each run)
./zig-out/bin/sim_runner

# Specific seed for deterministic results
./zig-out/bin/sim_runner --seed 42
```

#### Run Specific Scenario
```bash
# Single scenario with random seed
./zig-out/bin/sim_runner --scenario perfect

# Single scenario with specific seed
./zig-out/bin/sim_runner --seed 999 --scenario completion_corruption
```

#### Available Scenarios
- `perfect` - Perfect Conditions
- `corruption` - WAL Corruption Recovery
- `completion_corruption` - Completion WAL Corruption
- `massive` - Massive Data Load
- `random` - Random Corruption
- `truncation` - WAL Truncation

### Programmatic Usage

#### Basic Simulator
```zig
var simulator = simulation.Simulator.init(allocator, "/tmp/test");
const result = try simulator.run_scenario(simulation.perfect_conditions_scenario);
```

#### With Specific Seed
```zig
var simulator = simulation.Simulator.initWithSeed(allocator, "/tmp/test", 42);
const result = try simulator.run_scenario(simulation.random_corruption_scenario);
```

## Corruption Types

### Bit Flip
Single bit corruption simulating cosmic rays or memory errors:
```zig
.bit_flip => {
    byte[0] ^= @as(u8, 1) << random_bit_position;
}
```

### Byte Zero
Overwrite byte with zero, simulating certain hardware failures:
```zig
.byte_zero => {
    const zero_byte: [1]u8 = .{0};
    try file.writeAll(&zero_byte);
}
```

### Truncation
Simulate incomplete writes or filesystem issues:
```zig
.truncation => {
    try file.setEndPos(offset);  // Truncate file at offset
}
```

### Random Corruption
Comprehensive corruption with random data:
```zig
.random_corruption => {
    var corrupt_data: [16]u8 = undefined;
    prng.random().bytes(&corrupt_data);  // 16 bytes of random corruption
    try file.writeAll(corrupt_data[0..write_size]);
}
```

## Test Results and Verification

### SimulationResult Structure
```zig
pub const SimulationResult = struct {
    scenario_name: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
    operations_completed: usize,
    recovery_verified: bool = false,
}
```

### Success Criteria
A scenario passes when:
1. All operations complete successfully (`operations_completed == expected`)
2. Recovery verification passes (`recovery_verified == true`)
3. No errors occur during execution (`error_message == null`)

## Integration with CI/CD

### Deterministic Testing
```bash
# In CI pipeline - always same results
./zig-out/bin/sim_runner --seed 42
if [ $? -ne 0 ]; then
    echo "Simulation tests failed"
    exit 1
fi
```

### Multi-Seed Testing
```bash
# Test multiple corruption patterns
for seed in 42 999 12345 67890; do
    echo "Testing with seed $seed"
    ./zig-out/bin/sim_runner --seed $seed
done
```

### Build Integration
```bash
# Build target for simulation tests
zig build sim
```

## Creating Custom Scenarios

### Define Scenario
```zig
pub const my_custom_scenario = SimulationScenario{
    .name = "My Custom Test",
    .description = "Tests specific failure condition",
    .operations = &[_]SimulationScenario.Operation{
        .{ .set = .{ .key = "test_key", .value = "test_value" } },
        .flush,
        .{ .inject_corruption = .{
            .corruption_type = .bit_flip,
            .target_file = .intent_wal,
            .offset = 20,
            .seed = 54321,  // Optional: scenario-specific seed
        } },
        .restart_db,
        .{ .get = .{ .key = "test_key", .expected = "test_value" } },
    },
};
```

### Corruption Configuration
```zig
pub const CorruptionConfig = struct {
    corruption_type: CorruptionType,
    target_file: enum { intent_wal, completion_wal },
    offset: ?usize = null,        // Random if null
    probability: f32 = 1.0,       // Future: probabilistic corruption
    seed: u64 = 12345,           // Scenario-specific seed
};
```

## Best Practices

### For Development
1. **Use deterministic seeds** during development for reproducible debugging
2. **Test multiple seeds** to ensure robustness across different corruption patterns
3. **Validate recovery** in all scenarios involving corruption
4. **Keep scenarios focused** on specific failure modes

### For CI/CD
1. **Use fixed seeds** in CI for consistent results
2. **Test critical scenarios** with multiple seeds
3. **Monitor test execution time** for performance regressions
4. **Archive test results** with seed information for debugging

### For Debugging
1. **Use same seed** to reproduce failures exactly
2. **Add debug output** to understand corruption effects
3. **Test incremental changes** with known working seeds
4. **Document seed values** that expose specific bugs

## Future Enhancements

### Planned Features
- **Probabilistic corruption**: Specify probability of corruption occurring
- **Multi-file corruption**: Corrupt multiple WAL files simultaneously  
- **Network partition simulation**: Simulate distributed system failures
- **Performance benchmarking**: Measure impact of corruption on performance
- **Automated seed discovery**: Find seeds that trigger specific conditions

### Extension Points
- **Custom corruption types**: Add domain-specific corruption patterns
- **External validators**: Integrate with external consistency checkers
- **Metrics collection**: Gather detailed performance and reliability metrics
- **Scenario composition**: Combine multiple scenarios into test suites

## Conclusion

The Deterministic Simulation Testing framework provides comprehensive, reproducible testing of database reliability under adverse conditions. By using deterministic seeds and controlled corruption injection, it enables thorough validation of recovery mechanisms and helps ensure data integrity in production environments.

The framework serves as both a testing tool and a demonstration of robust database design principles, showing how proper WAL implementation and recovery logic can handle real-world failure scenarios gracefully.