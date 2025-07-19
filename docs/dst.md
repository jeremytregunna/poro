# DST v2: Property-Based Testing Framework

## Overview

DST v2 is a comprehensive property-based testing framework for the Poro database that provides:
- Randomized operation sequence generation
- Probability-based failure injection across all system layers
- Automatic test case shrinking for minimal failure reproduction
- Whole-system testing with statistical verification
- Future-ready architecture for virtual time control

## Architecture

### Core Principles

1. **Property-Based Testing**: Generate random operation sequences and verify system invariants hold
2. **Whole-System Testing**: Test the complete database as a black box, not isolated components
3. **Probabilistic Failure Injection**: Control failure rates with statistical verification
4. **Automatic Shrinking**: Find minimal reproduction cases when failures occur
5. **Seed-Controlled Determinism**: Reproducible randomness for debugging
6. **Low Performance Impact**: Minimal instrumentation overhead
7. **Future Extensibility**: Ready for virtual time injection and advanced scenarios

### Framework Components

#### 1. Property Test Definition

```zig
pub const PropertyTest = struct {
    name: []const u8,
    generators: PropertyGenerators,
    failure_injectors: FailureInjectionConfig,
    invariants: []InvariantChecker,
    shrinking: ShrinkingConfig,
    execution: ExecutionConfig,
    stats: TestStatistics,
};
```

#### 2. Operation Generation

```zig
pub const PropertyGenerators = struct {
    // Operation distribution control
    operation_distribution: OperationDistribution,
    
    // Key generation strategies
    key_generators: KeyGenerationStrategy,
    
    // Value generation strategies  
    value_generators: ValueGenerationStrategy,
    
    // Sequence characteristics
    sequence_length: Range(usize),
    operation_timing: TimingStrategy,
    
    // Conditional generation (e.g., more deletes after sets)
    conditional_probabilities: []ConditionalProbability,
};

pub const OperationDistribution = struct {
    set_probability: f64,
    get_probability: f64,
    del_probability: f64,
    flush_probability: f64,
    restart_probability: f64,
};

pub const KeyGenerationStrategy = union(enum) {
    uniform_random: struct { min_length: usize, max_length: usize },
    zipf_distribution: struct { alpha: f64, max_rank: usize },
    collision_prone: struct { hash_collision_rate: f64 },
    sequential: struct { prefix: []const u8 },
    mixed: struct { strategies: []KeyGenerationStrategy, weights: []f64 },
};

pub const ValueGenerationStrategy = union(enum) {
    fixed_size: usize,
    variable_size: Range(usize),
    power_law: struct { min: usize, max: usize, alpha: f64 },
    compressible: struct { repetition_factor: f64 },
    random_binary: void,
};
```

#### 3. Failure Injection System

```zig
pub const FailureInjectionConfig = struct {
    // Base failure probabilities
    allocator_failure_probability: f64,
    filesystem_error_probability: f64,
    iouring_error_probability: f64,
    hash_collision_probability: f64,
    timing_variance_probability: f64,
    
    // Failure type distributions
    filesystem_error_distribution: FilesystemErrorDistribution,
    allocator_failure_distribution: AllocatorFailureDistribution,
    
    // Conditional probability multipliers
    conditional_multipliers: []ConditionalMultiplier,
    
    // Failure clustering (multiple failures in sequence)
    failure_clustering: ClusteringConfig,
    
    // Recovery from failures
    recovery_probabilities: RecoveryConfig,
};

pub const ConditionalMultiplier = struct {
    condition: SystemCondition,
    multiplier: f64,
    duration: Duration,
};

pub const SystemCondition = enum {
    during_recovery,
    under_memory_pressure,
    high_operation_rate,
    after_restart,
    during_flush,
    hash_table_resize,
};

pub const ClusteringConfig = struct {
    cluster_probability: f64,
    cluster_size_distribution: Range(u32),
    cluster_spacing: Range(u64), // operations between clusters
};
```

#### 4. Invariant Checking

```zig
pub const InvariantChecker = struct {
    name: []const u8,
    check_fn: *const fn(db: *Database, history: []Operation, stats: *SystemStats) bool,
    severity: InvariantSeverity,
    check_frequency: CheckFrequency,
};

pub const InvariantSeverity = enum {
    critical,    // Data corruption, crashes
    important,   // Performance degradation, resource leaks
    advisory,    // Suboptimal behavior
};

pub const CheckFrequency = union(enum) {
    every_operation,
    periodic: u32,  // every N operations
    on_condition: SystemCondition,
    at_end,
};

// Built-in invariant checkers
pub const builtin_invariants = [_]InvariantChecker{
    .{
        .name = "data_consistency",
        .check_fn = check_data_consistency,
        .severity = .critical,
        .check_frequency = .every_operation,
    },
    .{
        .name = "memory_balance", 
        .check_fn = check_memory_balance,
        .severity = .critical,
        .check_frequency = .periodic(100),
    },
    .{
        .name = "transaction_atomicity",
        .check_fn = check_transaction_atomicity,
        .severity = .critical,
        .check_frequency = .on_condition(.during_recovery),
    },
    .{
        .name = "hash_table_integrity",
        .check_fn = check_hash_table_integrity,
        .severity = .critical,
        .check_frequency = .on_condition(.hash_table_resize),
    },
    .{
        .name = "wal_consistency",
        .check_fn = check_wal_consistency,
        .severity = .critical,
        .check_frequency = .on_condition(.during_flush),
    },
};
```

#### 5. Shrinking Framework

```zig
pub const ShrinkingConfig = struct {
    max_shrink_attempts: u32,
    shrink_strategies: []ShrinkStrategy,
    preserve_failure_conditions: bool,
    shrink_timeout: Duration,
};

pub const ShrinkStrategy = enum {
    remove_operations,           // Remove operations from sequence
    simplify_values,            // Use smaller, simpler values
    reduce_key_diversity,       // Use fewer unique keys
    eliminate_redundancy,       // Remove duplicate operations
    focus_around_failure,       // Keep operations near failure point
    preserve_failure_pattern,   // Maintain failure injection sequence
};

pub const ShrinkResult = struct {
    original_sequence_length: usize,
    shrunk_sequence_length: usize,
    shrink_iterations: u32,
    shrinking_time: Duration,
    minimal_reproduction: []Operation,
    failure_preserved: bool,
};
```

#### 6. Statistics and Reporting

```zig
pub const TestStatistics = struct {
    // Execution statistics
    total_operations_generated: u64,
    unique_sequences_tested: u32,
    test_execution_time: Duration,
    
    // Failure injection statistics
    failures_injected: FailureStats,
    probability_hit_rates: ProbabilityStats,
    failure_clustering_achieved: ClusteringStats,
    
    // Invariant violation statistics
    invariant_violations: InvariantViolationStats,
    
    // Coverage metrics
    coverage_metrics: CoverageMetrics,
    
    // Shrinking statistics
    shrinking_stats: ShrinkingStats,
    
    // Performance impact
    overhead_measurements: OverheadStats,
};

pub const FailureStats = struct {
    allocator_failures: FailureTypeStats,
    filesystem_errors: FailureTypeStats,
    iouring_errors: FailureTypeStats,
    hash_collisions: FailureTypeStats,
    timing_variances: FailureTypeStats,
    
    total_failures_injected: u64,
    failure_sequences: u32,
    clustered_failures: u32,
};

pub const ProbabilityStats = struct {
    target_probabilities: []f64,
    achieved_probabilities: []f64,
    statistical_significance: []f64,
    confidence_intervals: []ConfidenceInterval,
};

pub const CoverageMetrics = struct {
    // Code path coverage
    functions_exercised: FunctionCoverage,
    branches_taken: BranchCoverage,
    
    // State space coverage
    hash_table_states: StateSpaceCoverage,
    wal_states: StateSpaceCoverage,
    allocator_states: StateSpaceCoverage,
    
    // Error path coverage
    error_paths_exercised: ErrorPathCoverage,
    recovery_scenarios_tested: RecoveryScenarioCoverage,
};
```

#### 7. Future Time Control Interface

```zig
// Future extension point for virtual time control
pub const TimeController = struct {
    virtual_time_enabled: bool = false,
    current_virtual_time: VirtualTime = 0,
    time_acceleration_factor: f64 = 1.0,
    
    // Time injection points (future implementation)
    time_injection_points: []TimeInjectionPoint,
    
    // Clock skew simulation (future implementation)  
    clock_skew_enabled: bool = false,
    clock_skew_parameters: ClockSkewConfig,
    
    // Interface for future virtual time
    pub fn advance_time(self: *TimeController, duration: Duration) void {
        if (self.virtual_time_enabled) {
            self.current_virtual_time += @intCast(duration * self.time_acceleration_factor);
        }
    }
    
    pub fn inject_timing_variance(self: *TimeController, base_duration: Duration) Duration {
        // Future: complex timing variance injection
        return base_duration;
    }
};

// Future virtual time types
pub const VirtualTime = u64; // nanoseconds in virtual time
pub const TimeInjectionPoint = struct {
    location: InjectionLocation,
    variance_type: TimingVarianceType,
    parameters: TimingParameters,
};
```

### Implementation Strategy

#### Phase 1: Core Framework
1. **Property test definition and execution engine** (`src/property_testing.zig`)
2. **Basic operation generation** with simple distributions
3. **Minimal failure injection** at filesystem boundary
4. **Simple shrinking algorithm** (remove operations strategy)
5. **Basic statistics collection**

#### Phase 2: Advanced Generation
1. **Sophisticated key/value generation strategies**
2. **Conditional probability support**
3. **Operation timing strategies**
4. **Complex failure injection patterns**

#### Phase 3: Comprehensive Analysis
1. **Full invariant checking framework**
2. **Advanced shrinking strategies**
3. **Coverage metrics collection**
4. **Statistical analysis and reporting**

#### Phase 4: Future Extensions
1. **Virtual time control implementation**
2. **Advanced timing variance injection**
3. **Distributed testing scenarios**
4. **Performance regression detection**

### Usage Examples

#### Basic Property Test

```zig
const basic_property_test = PropertyTest{
    .name = "basic_operations_under_failures",
    .generators = .{
        .operation_distribution = .{
            .set_probability = 0.4,
            .get_probability = 0.4,
            .del_probability = 0.15,
            .flush_probability = 0.04,
            .restart_probability = 0.01,
        },
        .key_generators = .{
            .uniform_random = .{ .min_length = 1, .max_length = 32 }
        },
        .value_generators = .{
            .variable_size = .{ .min = 1, .max = 1024 }
        },
        .sequence_length = .{ .min = 100, .max = 10000 },
    },
    .failure_injectors = .{
        .allocator_failure_probability = 0.001,
        .filesystem_error_probability = 0.005,
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .during_recovery, .multiplier = 10.0, .duration = .forever },
        },
    },
    .invariants = &builtin_invariants,
    .shrinking = .{
        .max_shrink_attempts = 1000,
        .shrink_strategies = &[_]ShrinkStrategy{
            .remove_operations,
            .simplify_values,
            .focus_around_failure,
        },
        .preserve_failure_conditions = true,
    },
};
```

#### Hash Collision Stress Test

```zig
const collision_stress_test = PropertyTest{
    .name = "hash_collision_exhaustion",
    .generators = .{
        .key_generators = .{
            .collision_prone = .{ .hash_collision_rate = 0.8 }
        },
        .sequence_length = .{ .min = 10000, .max = 100000 },
    },
    .failure_injectors = .{
        .hash_collision_probability = 0.9, // Force high collision rate
        .allocator_failure_probability = 0.01, // Test resize failures
    },
    .invariants = &[_]InvariantChecker{
        builtin_invariants[3], // hash_table_integrity
        builtin_invariants[0], // data_consistency
    },
};
```

#### Recovery Stress Test

```zig
const recovery_stress_test = PropertyTest{
    .name = "recovery_under_pressure",
    .generators = .{
        .operation_distribution = .{
            .restart_probability = 0.1, // Frequent restarts
        },
    },
    .failure_injectors = .{
        .conditional_multipliers = &[_]ConditionalMultiplier{
            .{ .condition = .during_recovery, .multiplier = 50.0 },
            .{ .condition = .under_memory_pressure, .multiplier = 20.0 },
        },
        .failure_clustering = .{
            .cluster_probability = 0.3,
            .cluster_size_distribution = .{ .min = 2, .max = 10 },
        },
    },
    .invariants = &[_]InvariantChecker{
        builtin_invariants[2], // transaction_atomicity
        builtin_invariants[4], // wal_consistency
    },
};
```

### Integration with Current Framework

The property-based testing framework will coexist with the current scenario-based testing:

- **Scenario Tests**: Continue to provide regression testing and basic functionality verification
- **Property Tests**: Provide comprehensive exploration of failure space and edge cases
- **Unified CLI**: Both testing approaches accessible through the simulation runner
- **Shared Infrastructure**: Leverage existing filesystem abstraction and dependency injection

### Statistical Requirements

Property tests must provide statistical validation:

1. **Probability Target Achievement**: Verify that failure injection rates match configured probabilities within confidence intervals
2. **Coverage Metrics**: Track which system states and error paths have been exercised
3. **Invariant Violation Rates**: Monitor frequency and types of invariant violations
4. **Shrinking Effectiveness**: Measure how well shrinking reduces failing test cases

### Success Criteria

A successful DST v2 implementation will:

1. **Discover Unknown Bugs**: Find edge cases and race conditions not covered by manual scenarios
2. **Provide Reproducible Failures**: Shrink complex failures to minimal reproduction cases
3. **Verify Statistical Properties**: Confirm system behavior under probabilistic failure injection
4. **Scale to Complex Scenarios**: Handle thousands of operations with multiple simultaneous failures
5. **Maintain Low Overhead**: <5% performance impact on database operations during testing
6. **Generate Actionable Reports**: Provide clear statistics and reproduction steps for failures

This framework positions Poro's testing infrastructure as a state-of-the-art example of property-based database testing with comprehensive failure injection and statistical validation.