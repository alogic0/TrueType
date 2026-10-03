const std = @import("std");
const TrueType = @import("TrueType");
pub const max_input = 64 * 1024;
pub const Stage = enum { load, query, outline, bitmap };

pub fn exercise(bytes: []const u8, stage: Stage) void {
    if (bytes.len > max_input) return;
    const parsed = TrueType.load(bytes) catch return;
    const font = parsed.withLimits(.{
        .max_charstring_instructions = 4096,
        .max_outline_vertices = 4096,
        .max_components = 64,
        .max_flattened_points = 8192,
        .max_bitmap_pixels = 65536,
        .max_raster_work = 2_000_000,
    });
    if (stage == .load) return;
    _ = font.verticalMetricsChecked() catch {};
    _ = font.scaleForPixelHeightChecked(24) catch {};
    var memory: [2 * 1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    const candidates = [_]TrueType.GlyphIndex{
        .notdef,
        @fromBackingInt(1),
        @fromBackingInt(@as(u16, @intCast(font.glyphs_len - 1))),
        font.codepointGlyphIndex('A'),
        @fromBackingInt(65535),
    };
    for ([_]u21{ 0, 'A', 0xffff, 0x1f600, 0x10ffff }) |cp| {
        _ = font.codepointGlyphIndexChecked(cp) catch {};
        _ = font.codepointVariationGlyphIndexChecked(cp, 0xfe0f) catch {};
    }
    for (candidates) |glyph| {
        _ = font.glyphHMetricsChecked(glyph) catch {};
        _ = font.glyphKernAdvanceChecked(glyph, candidates[3]) catch {};
        _ = font.glyphBoxChecked(glyph) catch {};
        if (stage == .query) continue;
        fixed.reset();
        if (font.glyphShape(allocator, glyph)) |vertices| allocator.free(vertices) else |_| {}
        if (stage == .outline) continue;
        fixed.reset();
        var pixels: std.ArrayList(u8) = .empty;
        defer pixels.deinit(allocator);
        const scale = font.scaleForPixelHeight(24);
        _ = font.glyphBitmapSubpixel(allocator, &pixels, glyph, scale, scale * 0.75, 0.25, -0.125) catch {};
    }
}
