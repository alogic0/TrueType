const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// Counts requested live bytes, not allocator size classes or process RSS.
pub const CountingAllocator = struct {
    child: Allocator = std.heap.smp_allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn resetCounts(self: *CountingAllocator) void {
        self.alloc_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
        self.peak = self.live;
    }

    fn changed(self: *CountingAllocator, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        const result = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.changed(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        if (!self.child.rawResize(memory, alignment, len, ra)) return false;
        self.changed(memory.len, len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remap_calls += 1;
        const result = self.child.rawRemap(memory, alignment, len, ra) orelse return null;
        self.changed(memory.len, len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.child.rawFree(memory, alignment, ra);
        self.changed(memory.len, 0);
    }
};
