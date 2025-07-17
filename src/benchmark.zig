//! ABOUTME: Performance testing suite for measuring key-value store insertion speed
//! ABOUTME: Benchmarks SET operations with various key/value sizes and quantities
const std = @import("std");
const allocator_mod = @import("allocator.zig");
const kvstore_mod = @import("kvstore.zig");

const BenchmarkConfig = struct {
    num_keys: u32,
    key_size: u32,
    value_size: u32,
    batch_size: u32 = 1000,
};

const BenchmarkResult = struct {
    config: BenchmarkConfig,
    total_time_ns: u64,
    keys_per_second: f64,
    avg_time_per_key_ns: u64,
    
    pub fn print(self: BenchmarkResult) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("Benchmark Results:\n", .{}) catch {};
        stdout.print("  Keys: {}, Key Size: {} bytes, Value Size: {} bytes\n", .{
            self.config.num_keys, self.config.key_size, self.config.value_size
        }) catch {};
        stdout.print("  Total Time: {d:.2} ms\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0}) catch {};
        stdout.print("  Keys/Second: {d:.0}\n", .{self.keys_per_second}) catch {};
        stdout.print("  Avg Time/Key: {d:.2} μs\n", .{@as(f64, @floatFromInt(self.avg_time_per_key_ns)) / 1000.0}) catch {};
        stdout.print("  Memory Usage: ~{d:.1} MB\n", .{
            @as(f64, @floatFromInt(self.config.num_keys * (self.config.key_size + self.config.value_size))) / (1024.0 * 1024.0)
        }) catch {};
        stdout.print("\n", .{}) catch {};
    }
};

fn generate_key(allocator: std.mem.Allocator, index: u32, size: u32) ![]u8 {
    const key = try allocator.alloc(u8, size);
    
    // Create the base key in a temporary buffer first
    var temp_buf: [64]u8 = undefined;
    const base_key = try std.fmt.bufPrint(&temp_buf, "key_{d}", .{index});
    
    // Copy to the actual key buffer, truncating if necessary
    const copy_len = @min(base_key.len, size);
    @memcpy(key[0..copy_len], base_key[0..copy_len]);
    
    // Pad with zeros if needed
    if (copy_len < size) {
        @memset(key[copy_len..], '0');
    }
    
    return key;
}

fn generate_value(allocator: std.mem.Allocator, index: u32, size: u32) ![]u8 {
    const value = try allocator.alloc(u8, size);
    
    // Create the base value in a temporary buffer first
    var temp_buf: [64]u8 = undefined;
    const base_value = try std.fmt.bufPrint(&temp_buf, "value_data_{d}", .{index});
    
    // Copy to the actual value buffer, truncating if necessary
    const copy_len = @min(base_value.len, size);
    @memcpy(value[0..copy_len], base_value[0..copy_len]);
    
    // Fill rest with pattern
    if (copy_len < size) {
        var i: u32 = @intCast(copy_len);
        while (i < size) : (i += 1) {
            value[i] = @intCast(('A' + (i % 26)));
        }
    }
    
    return value;
}

fn run_benchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    const stdout = std.io.getStdOut().writer();
    
    // Clean up any existing WAL file
    const wal_file = "/tmp/benchmark.wal";
    std.fs.deleteFileAbsolute(wal_file) catch {};
    defer std.fs.deleteFileAbsolute(wal_file) catch {};
    
    var store = try kvstore_mod.KVStore.init(allocator, wal_file);
    defer store.deinit();
    
    try stdout.print("Starting benchmark: {} keys, key_size={}, value_size={}\n", .{
        config.num_keys, config.key_size, config.value_size
    });
    
    const start_time = std.time.nanoTimestamp();
    
    // Insert keys in batches with progress reporting
    var inserted: u32 = 0;
    while (inserted < config.num_keys) {
        const batch_end = @min(inserted + config.batch_size, config.num_keys);
        
        for (inserted..batch_end) |i| {
            const key = try generate_key(allocator, @intCast(i), config.key_size);
            defer allocator.free(key);
            
            const value = try generate_value(allocator, @intCast(i), config.value_size);
            defer allocator.free(value);
            
            try store.set(key, value);
        }
        
        inserted = batch_end;
        
        // Progress update
        const progress = (@as(f64, @floatFromInt(inserted)) / @as(f64, @floatFromInt(config.num_keys))) * 100.0;
        try stdout.print("Progress: {d:.1}% ({}/{})\r", .{ progress, inserted, config.num_keys });
    }
    
    // Flush WAL to ensure all data is written
    try store.flush_wal();
    
    const end_time = std.time.nanoTimestamp();
    const total_time_ns: u64 = @intCast(end_time - start_time);
    
    try stdout.print("\nCompleted!\n", .{});
    
    return BenchmarkResult{
        .config = config,
        .total_time_ns = total_time_ns,
        .keys_per_second = @as(f64, @floatFromInt(config.num_keys)) / (@as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0),
        .avg_time_per_key_ns = total_time_ns / config.num_keys,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    
    var static_alloc = allocator_mod.StaticAllocator.init(arena.allocator());
    defer static_alloc.deinit();
    
    const allocator = static_alloc.allocator();
    
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Poro Database Performance Benchmark\n", .{});
    try stdout.print("====================================\n\n", .{});
    
    // Different benchmark configurations
    const benchmarks = [_]BenchmarkConfig{
        // Small keys/values, various quantities
        .{ .num_keys = 1000, .key_size = 8, .value_size = 16 },
        .{ .num_keys = 10000, .key_size = 8, .value_size = 16 },
        .{ .num_keys = 100000, .key_size = 8, .value_size = 16 },
        
        // Medium keys/values
        .{ .num_keys = 10000, .key_size = 32, .value_size = 128 },
        .{ .num_keys = 50000, .key_size = 32, .value_size = 128 },
        
        // Large values
        .{ .num_keys = 1000, .key_size = 16, .value_size = 1024 },
        .{ .num_keys = 10000, .key_size = 16, .value_size = 1024 },
    };
    
    for (benchmarks) |config| {
        const result = try run_benchmark(allocator, config);
        result.print();
    }
    
    try stdout.print("Benchmark suite completed!\n", .{});
}