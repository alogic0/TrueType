const std = @import("std");
const harness = @import("fuzz/harness.zig");
const seeds = @import("fuzz/seeds.zig");

fn encoded(comptime seed: []const u8) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(100000);
        var result: [seed.len + 4]u8 = undefined;
        std.mem.writeInt(u32, result[0..4], seed.len, .little);
        @memcpy(result[4..], seed);
        const copy = result;
        break :blk &copy;
    };
}

fn testInput(stage: harness.Stage, smith: *std.testing.Smith) !void {
    var bytes: [harness.max_input]u8 = undefined;
    const len = smith.slice(&bytes);
    harness.exercise(bytes[0..len], stage);
}

fn run(stage: harness.Stage) !void {
    try std.testing.fuzz(stage, testInput, .{ .corpus = &.{ encoded(&seeds.tt), encoded(seeds.cff) } });
}

test "fuzz loader" {
    try run(.load);
}
test "fuzz queries" {
    try run(.query);
}
test "fuzz outlines" {
    try run(.outline);
}
test "fuzz bitmaps" {
    try run(.bitmap);
}

test "authored fuzz seed loads and renders a triangle" {
    const TrueType = @import("TrueType");
    const font = try TrueType.load(&seeds.tt);
    try std.testing.expectEqual(@as(u16, 1), @backingInt(font.codepointGlyphIndex('A')));
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(std.testing.allocator);
    const bitmap = try font.glyphBitmap(std.testing.allocator, &pixels, @fromBackingInt(1), 0.1, 0.1);
    try std.testing.expectEqual(@as(u16, 10), bitmap.width);
    try std.testing.expectEqual(@as(u16, 10), bitmap.height);
}
