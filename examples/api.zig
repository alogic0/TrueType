//! One-shot rendering, workspace reuse, variation fallback, and error recovery.
const std = @import("std");
const TrueType = @import("TrueType");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2) return error.ExpectedFontPath;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(32 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const font = try TrueType.load(bytes);
    try demonstrate(&font, init.gpa);
}

fn demonstrate(font: *const TrueType, allocator: std.mem.Allocator) !void {
    const glyph = try font.codepointVariationGlyphIndexChecked('A', 0xfe0f) orelse try font.codepointGlyphIndexChecked('A');
    const scale = try font.scaleForPixelHeightChecked(24);
    const metrics = try font.glyphHMetricsChecked(glyph);
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(allocator);
    const one_shot = try font.glyphBitmap(allocator, &pixels, glyph, scale, scale);
    const saved = try allocator.dupe(u8, pixels.items);
    defer allocator.free(saved);
    var workspace: TrueType.RasterizerWorkspace = .init(allocator);
    defer workspace.deinit();
    pixels.clearRetainingCapacity();
    const reused = try font.glyphBitmapWithWorkspace(allocator, &pixels, &workspace, glyph, scale, scale);
    if (!std.meta.eql(one_shot, reused) or !std.mem.eql(u8, saved, pixels.items)) return error.BitmapMismatch;

    // Failed renders preserve output and leave the workspace usable.
    if (font.glyphBitmapWithWorkspace(allocator, &pixels, &workspace, glyph, 0, scale)) |_| {
        return error.ExpectedInvalidScale;
    } else |err| if (err != error.InvalidRenderParameters) return err;
    if (!std.mem.eql(u8, saved, pixels.items)) return error.OutputChangedOnFailure;
    pixels.clearRetainingCapacity();
    _ = try font.glyphBitmapWithWorkspace(allocator, &pixels, &workspace, glyph, scale, scale);
    std.log.info("glyph={d}, bitmap={d}x{d}, advance={d} font units", .{ @backingInt(glyph), reused.width, reused.height, metrics.advance_width });
}
