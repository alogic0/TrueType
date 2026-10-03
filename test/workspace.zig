const std = @import("std");
const TrueType = @import("TrueType");
const gpa = std.testing.allocator;
const fonts = [_][]const u8{ @embedFile("GoNotoCurrent-Regular.ttf"), @embedFile("StandardSymbolsPS.otf") };

test "workspace reuses temporary storage without backing allocations after warmup" {
    for (fonts) |data| {
        const tt = try TrueType.load(data);
        var counter: std.testing.FailingAllocator = .init(gpa, .{});
        const counted = counter.allocator();
        var workspace: TrueType.RasterizerWorkspace = .init(counted);
        defer workspace.deinit();
        var pixels: std.ArrayList(u8) = .empty;
        defer pixels.deinit(counted);
        // Exercise varying glyph complexity and scanline widths before disabling
        // all backing allocation and resizing, including pixel-buffer growth.
        for (0..2) |_| {
            for (0..8) |i| {
                pixels.clearRetainingCapacity();
                const scale = tt.scaleForPixelHeight(if (i % 2 == 0) 64 else 24);
                _ = try tt.glyphBitmapSubpixelWithWorkspace(counted, &pixels, &workspace, @fromBackingInt(@as(u16, @intCast(i * 17))), scale, scale, 0.25, -0.125);
            }
        }
        const allocations = counter.alloc_index;
        const resizes = counter.resize_index;
        counter.fail_index = allocations;
        counter.resize_fail_index = resizes;
        for (0..4) |_| {
            for (0..8) |i| {
                pixels.clearRetainingCapacity();
                const scale = tt.scaleForPixelHeight(if (i % 2 == 0) 64 else 24);
                const glyph: TrueType.GlyphIndex = @fromBackingInt(@as(u16, @intCast(i * 17)));
                const actual = try tt.glyphBitmapSubpixelWithWorkspace(counted, &pixels, &workspace, glyph, scale, scale, 0.25, -0.125);
                var expected_pixels: std.ArrayList(u8) = .empty;
                defer expected_pixels.deinit(gpa);
                const expected = try tt.glyphBitmapSubpixel(gpa, &expected_pixels, glyph, scale, scale, 0.25, -0.125);
                try std.testing.expectEqualDeep(expected, actual);
                try std.testing.expectEqualSlices(u8, expected_pixels.items, pixels.items);
            }
        }
        try std.testing.expect(allocations > 0);
        try std.testing.expectEqual(allocations, counter.alloc_index);
        try std.testing.expectEqual(resizes, counter.resize_index);
        try std.testing.expect(!counter.has_induced_failure);
    }
}

test "workspace pixels survive reuse and release" {
    const tt = try TrueType.load(fonts[0]);
    var workspace: TrueType.RasterizerWorkspace = .init(gpa);
    defer workspace.deinit();
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(gpa);
    try pixels.appendSlice(gpa, &.{ 11, 22, 33 });
    const scale = tt.scaleForPixelHeight(32);
    const glyph = tt.codepointGlyphIndex('A');
    _ = try tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, glyph, scale, scale);
    const saved = try gpa.dupe(u8, pixels.items);
    defer gpa.free(saved);
    _ = try tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, tt.codepointGlyphIndex('B'), scale, scale);
    workspace.release();
    try std.testing.expectEqualSlices(u8, saved, pixels.items[0..saved.len]);
    _ = try tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, glyph, scale, scale);
    try std.testing.expectEqualSlices(u8, saved, pixels.items[0..saved.len]);
    const len = pixels.items.len;
    const empty = try tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, tt.codepointGlyphIndex(' '), scale, scale);
    try std.testing.expectEqualDeep(TrueType.GlyphBitmap.empty, empty);
    try std.testing.expectEqual(len, pixels.items.len);
}

fn renderWithFailure(tt: *const TrueType, fail_index: usize) !usize {
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
    var workspace: TrueType.RasterizerWorkspace = .init(failing.allocator());
    defer workspace.deinit();
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(gpa);
    const prefix = [_]u8{ 11, 22, 33 };
    try pixels.appendSlice(gpa, &prefix);
    const scale = tt.scaleForPixelHeight(64);
    const glyph: TrueType.GlyphIndex = @fromBackingInt(50);
    if (tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, glyph, scale, scale)) |_| {
        // Cache consolidation is optional; an allocation failure there must not
        // discard a successfully rendered bitmap.
        try std.testing.expect(pixels.items.len > prefix.len);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqualSlices(u8, &prefix, pixels.items);
    }
    const allocations = failing.alloc_index;
    failing.fail_index = std.math.maxInt(usize);
    pixels.clearRetainingCapacity();
    _ = try tt.glyphBitmapWithWorkspace(gpa, &pixels, &workspace, glyph, scale, scale);
    try std.testing.expect(pixels.items.len > 0);
    workspace.release();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    return allocations;
}

test "workspace allocation failures preserve output and allow recovery" {
    for (fonts) |data| {
        const tt = try TrueType.load(data);
        const count = try renderWithFailure(&tt, std.math.maxInt(usize));
        for (0..count) |fail_index| _ = try renderWithFailure(&tt, fail_index);
    }
}

test "workspace output allocation failure leaves previous pixels intact" {
    const tt = try TrueType.load(fonts[0]);
    var workspace: TrueType.RasterizerWorkspace = .init(gpa);
    defer workspace.deinit();
    var output_allocator: std.testing.FailingAllocator = .init(gpa, .{});
    const output = output_allocator.allocator();
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(output);
    try pixels.appendSlice(output, &.{ 11, 22, 33 });
    const scale = tt.scaleForPixelHeight(64);
    const glyph = tt.codepointGlyphIndex('A');
    output_allocator.fail_index = output_allocator.alloc_index;
    output_allocator.resize_fail_index = output_allocator.resize_index;
    try std.testing.expectError(error.OutOfMemory, tt.glyphBitmapWithWorkspace(output, &pixels, &workspace, glyph, scale, scale));
    try std.testing.expectEqualSlices(u8, &.{ 11, 22, 33 }, pixels.items);
    output_allocator.fail_index = std.math.maxInt(usize);
    output_allocator.resize_fail_index = std.math.maxInt(usize);
    _ = try tt.glyphBitmapWithWorkspace(output, &pixels, &workspace, glyph, scale, scale);
    try std.testing.expect(pixels.items.len > 3);
}
