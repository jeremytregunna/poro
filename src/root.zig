//! ABOUTME: Root module for Poro key-value database library
//! ABOUTME: Exports all core components for external use
const std = @import("std");
const testing = std.testing;

pub const allocator = @import("allocator.zig");
pub const wal = @import("wal.zig");
pub const kvstore = @import("kvstore.zig");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
