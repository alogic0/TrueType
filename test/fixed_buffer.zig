const std = @import("std");
const TrueType = @import("TrueType");
const fonts = [_][]const u8{ @embedFile("StandardSymbolsPS.otf"), @embedFile("GoNotoCurrent-Regular.ttf") };

test "fixed buffers render mixed sizes with no heap fallback and stable warm usage" {
    for (fonts) |bytes| {
        const font = try TrueType.load(bytes);
        var scratch_memory: [256 * 1024]u8 = undefined;
        var output_memory: [64 * 1024]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&scratch_memory);
        var output = std.heap.FixedBufferAllocator.init(&output_memory);
        var workspace: TrueType.RasterizerWorkspace = .init(scratch.allocator());
        defer workspace.deinit();
        var pixels: std.ArrayList(u8) = .empty;
        defer pixels.deinit(output.allocator());
        var retained: usize = 0;
        for (0..4) |pass| {
            for ([_]f32{ 96, 12, 32 }) |size| {
                const scale = font.scaleForPixelHeight(size);
                for ([_]u21{ 'A', 'B', 'g', ' ', 0x3a9 }) |cp| {
                    pixels.clearRetainingCapacity();
                    const glyph = font.codepointGlyphIndex(cp);
                    const actual = try font.glyphBitmapWithWorkspace(output.allocator(), &pixels, &workspace, glyph, scale, scale);
                    var reference: std.ArrayList(u8) = .empty;
                    defer reference.deinit(std.testing.allocator);
                    const expected = try font.glyphBitmap(std.testing.allocator, &reference, glyph, scale, scale);
                    try std.testing.expectEqualDeep(expected, actual);
                    try std.testing.expectEqualSlices(u8, reference.items, pixels.items);
                }
            }
            const used = scratch.end_index + output.end_index;
            if (pass == 1) retained = used;
            if (pass > 1) try std.testing.expectEqual(retained, used);
        }
        workspace.release();
        // Arena chunks are returned to the backing allocator; output survives.
        try std.testing.expectEqual(@as(usize, 0), scratch.end_index);
        const scale = font.scaleForPixelHeight(12);
        pixels.clearRetainingCapacity();
        _ = try font.glyphBitmapWithWorkspace(output.allocator(), &pixels, &workspace, font.codepointGlyphIndex('A'), scale, scale);
    }
}

test "fixed scratch exhaustion preserves output and recovers after release" {
    const font = try TrueType.load(fonts[0]);
    var storage: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(storage[0..32]);
    var workspace: TrueType.RasterizerWorkspace = .init(fixed.allocator());
    defer workspace.deinit();
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(std.testing.allocator);
    try pixels.appendSlice(std.testing.allocator, &.{ 7, 9 });
    const scale = font.scaleForPixelHeight(32);
    try std.testing.expectError(error.OutOfMemory, font.glyphBitmapWithWorkspace(std.testing.allocator, &pixels, &workspace, font.codepointGlyphIndex('A'), scale, scale));
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, pixels.items);
    workspace.release();
    fixed = .init(&storage); // safe only after all scratch allocations are released
    _ = try font.glyphBitmapWithWorkspace(std.testing.allocator, &pixels, &workspace, font.codepointGlyphIndex('A'), scale, scale);
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, pixels.items[0..2]);
}

test "fixed output exhaustion preserves its prefix" {
    const font = try TrueType.load(fonts[0]);
    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var pixels: std.ArrayList(u8) = .initBuffer(&storage);
    try pixels.appendSlice(fixed.allocator(), &.{ 7, 9 });
    fixed.end_index = storage.len; // the list already owns this complete buffer
    const scale = font.scaleForPixelHeight(32);
    var workspace: TrueType.RasterizerWorkspace = .init(std.testing.allocator);
    defer workspace.deinit();
    try std.testing.expectError(error.OutOfMemory, font.glyphBitmapWithWorkspace(fixed.allocator(), &pixels, &workspace, font.codepointGlyphIndex('A'), scale, scale));
    try std.testing.expectEqualSlices(u8, &.{ 7, 9 }, pixels.items);
}
