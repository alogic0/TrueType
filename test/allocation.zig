const std = @import("std");
const TrueType = @import("TrueType");

fn renderWithoutResize(allocator: std.mem.Allocator, data: []const u8) !void {
    // Force toOwnedSlice to copy when reducing capacity, so failure at the
    // second ownership transfer is observable even with an allocator that
    // normally accepts shrinking in place.
    var no_resize: std.testing.FailingAllocator = .init(allocator, .{ .resize_fail_index = 0 });
    const gpa = no_resize.allocator();
    const font = try TrueType.load(data);
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(gpa);
    try pixels.appendSlice(gpa, &.{ 11, 22, 33 });
    const scale = font.scaleForPixelHeight(32);
    _ = font.glyphBitmap(gpa, &pixels, @fromBackingInt(50), scale, scale) catch |err| {
        try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33 }, pixels.items);
        return err;
    };
}

test "one-shot rendering cleans up every allocation failure" {
    for ([_][]const u8{ @embedFile("GoNotoCurrent-Regular.ttf"), @embedFile("StandardSymbolsPS.otf") }) |data| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, renderWithoutResize, .{data});
    }
}
