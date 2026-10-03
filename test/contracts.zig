const std = @import("std");
const TrueType = @import("TrueType");
const original = @embedFile("StandardSymbolsPS.otf");

test "checked metrics retain unsigned advances and widen vertical range" {
    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    var font = try TrueType.load(bytes);
    const hmtx = font.table_offsets[@backingInt(TrueType.TableId.hmtx)];
    const hhea = font.table_offsets[@backingInt(TrueType.TableId.hhea)];
    std.mem.writeInt(u16, bytes[hmtx..][0..2], 65535, .big);
    std.mem.writeInt(i16, bytes[hhea + 4 ..][0..2], 32767, .big);
    std.mem.writeInt(i16, bytes[hhea + 6 ..][0..2], -32768, .big);
    try std.testing.expectEqual(@as(u16, 65535), (try font.glyphHMetricsChecked(.notdef)).advance_width);
    try std.testing.expectEqual(@as(f32, 1), try font.scaleForPixelHeightChecked(65535));
    const invalid: TrueType.GlyphIndex = @fromBackingInt(@as(u16, @intCast(font.glyphs_len)));
    try std.testing.expectError(error.InvalidFontData, font.glyphHMetricsChecked(invalid));
    try std.testing.expectEqual(@as(u16, 0), font.glyphHMetrics(invalid).advance_width);
    font.table_lengths[@backingInt(TrueType.TableId.hmtx)] = 1;
    try std.testing.expectError(error.EndOfStream, font.glyphHMetricsChecked(.notdef));
    font.table_lengths[@backingInt(TrueType.TableId.hhea)] = 5;
    try std.testing.expectError(error.EndOfStream, font.verticalMetricsChecked());
    try std.testing.expectEqual(@as(f32, 0), font.scaleForPixelHeight(12));
}

test "render parameter errors preserve pixels and workspace reuse" {
    const font = try TrueType.load(original);
    const glyph = font.codepointGlyphIndex('A');
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(std.testing.allocator);
    try pixels.appendSlice(std.testing.allocator, &.{ 17, 23 });
    var workspace: TrueType.RasterizerWorkspace = .init(std.testing.allocator);
    defer workspace.deinit();
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        try std.testing.expectError(error.InvalidRenderParameters, font.scaleForPixelHeightChecked(invalid));
        for ([_][4]f32{ .{ invalid, 1, 0, 0 }, .{ 1, invalid, 0, 0 } }) |args| {
            try std.testing.expectError(error.InvalidRenderParameters, font.glyphBitmapSubpixelWithWorkspace(std.testing.allocator, &pixels, &workspace, glyph, args[0], args[1], args[2], args[3]));
            try std.testing.expectError(error.InvalidRenderParameters, font.glyphBitmapBoxSubpixelChecked(glyph, args[0], args[1], args[2], args[3]));
        }
    }
    for ([_]f32{ std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        try std.testing.expectError(error.InvalidRenderParameters, font.glyphBitmapSubpixelWithWorkspace(std.testing.allocator, &pixels, &workspace, glyph, 1, 1, invalid, 0));
        try std.testing.expectError(error.InvalidRenderParameters, font.glyphBitmapSubpixelWithWorkspace(std.testing.allocator, &pixels, &workspace, glyph, 1, 1, 0, invalid));
    }
    for ([_][4]f32{ .{ 1e30, 1, 0, 0 }, .{ 1000, 1000, 0, 0 }, .{ 1, 1, 40000, 0 }, .{ 1, 1, 0, -40000 } }) |args| {
        try std.testing.expectError(error.BitmapTooLarge, font.glyphBitmapSubpixelWithWorkspace(std.testing.allocator, &pixels, &workspace, glyph, args[0], args[1], args[2], args[3]));
    }
    try std.testing.expectEqualSlices(u8, &.{ 17, 23 }, pixels.items);
    const scale = try font.scaleForPixelHeightChecked(12);
    _ = try font.glyphBitmapWithWorkspace(std.testing.allocator, &pixels, &workspace, glyph, scale, scale);
    try std.testing.expect(pixels.items.len > 2);
    try std.testing.expectEqualSlices(u8, &.{ 17, 23 }, pixels.items[0..2]);
}

test "checked bounds distinguish malformed CFF and empty outlines" {
    var storage: [128]u8 = undefined;
    const empty = try @import("cff.zig").programFont(&storage, &.{14});
    try std.testing.expectEqual(@as(?TrueType.BitmapBox, null), try empty.glyphBoxChecked(.notdef));
    const bad = try @import("cff.zig").programFont(&storage, &.{ 139, 139, 21, 5, 14 });
    try std.testing.expectError(error.RLineToStack, bad.glyphBoxChecked(.notdef));
    try std.testing.expectEqual(@as(?TrueType.BitmapBox, null), bad.glyphBox(.notdef));
    try std.testing.expectError(error.RLineToStack, bad.glyphBitmapBoxChecked(.notdef, 1, 1));
}
