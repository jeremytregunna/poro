const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const AllocatorState = enum {
    allocate,
    frozen,
    deallocate,
};

pub const StaticAllocator = struct {
    parent_allocator: Allocator,
    state: AllocatorState,
    mutex: std.Thread.Mutex,

    pub fn init(parent_allocator: Allocator) StaticAllocator {
        return StaticAllocator{
            .parent_allocator = parent_allocator,
            .state = .allocate,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *StaticAllocator) void {
        self.* = undefined;
    }

    pub fn allocator(self: *StaticAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn to_frozen(self: *StaticAllocator) void {
        assert(self.state == .assert);
        self.state = .frozen;
    }

    pub fn to_deallocate(self: *StaticAllocator) void {
        assert(self.state == .frozen);
        self.state = .deinit;
    }

    pub fn get_state(self: *StaticAllocator) AllocatorState {
        return self.state;
    }

    fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.state == .allocate);
        return self.parent_allocator.rawAlloc(len, log2_ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.state == .allocate);
        return self.parent_allocator.rawResize(buf, log2_buf_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.state == .allocate);
        return self.parent_allocator.rawRemap(buf, log2_buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(self.state == .allocate or self.state == .deallocate);
        self.parent_allocator.rawFree(buf, log2_buf_align, ret_addr);
    }
};

test "static allocator state machine" {
    var static_alloc = StaticAllocator.init(std.testing.allocator);
    defer static_alloc.deinit();

    const alloc = static_alloc.allocator();

    // Test allocate state
    try std.testing.expect(static_alloc.get_state() == .allocate);
    const memory = try alloc.alloc(u8, 100);
    try std.testing.expect(memory.len == 100);

    // Test frozen state
    static_alloc.to_frozen();
    try std.testing.expect(static_alloc.get_state() == .frozen);
    const frozen_memory = alloc.alloc(u8, 100);
    try std.testing.expect(frozen_memory == null);

    // Test deallocate state
    static_alloc.to_deallocate();
    try std.testing.expect(static_alloc.get_state() == .deallocate);
    alloc.free(memory);
    static_alloc.free_all();
}
