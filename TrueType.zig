const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

const TrueType = @This();
const rasterizer = @import("rasterizer.zig");
const cff = @import("cff.zig");
const cmap = @import("cmap.zig");
const CffData = cff.CffData;
const sfnt = @import("sfnt.zig");
const Reader = @import("reader.zig");
const OutlineFont = @import("truetype_outline.zig");
const metrics = @import("metrics.zig");
const kerning = @import("kerning.zig");

table_offsets: [sfnt.table_count]u32,
table_lengths: [sfnt.table_count]u32 = @splat(0),
ttf_bytes: []const u8,
index_map: u32,
variation_map: u32 = 0,
index_to_loc_format: u16,
glyphs_len: u32,
cff_data: CffData,
limits: Limits = .{},

pub const Limits = @import("limits.zig");

/// Copies this borrowed font view with per-operation resource budgets.
pub fn withLimits(tt: TrueType, limits: Limits) TrueType {
    var result = tt;
    result.limits = limits;
    return result;
}

pub const GlyphIndex = @import("glyph.zig").GlyphIndex;

pub const TableId = sfnt.TableId;

const PlatformId = enum(u16) {
    unicode = 0,
    mac = 1,
    iso = 2,
    microsoft = 3,
};

const MicrosoftEncodingId = enum(u16) {
    symbol = 0,
    unicode_bmp = 1,
    shiftjis = 2,
    unicode_full = 10,
};

pub const LoadError = error{
    /// The font file unexpectedly ended when more data was expected.
    EndOfStream,
    MissingRequiredTable,
    IndexMapMissing,
} || CffData.InitError || sfnt.Error;

pub fn load(bytes: []const u8) LoadError!TrueType {
    const directory = try sfnt.Directory.init(bytes);
    const metadata = try directory.metadata();
    const table_offsets = directory.offsets;
    var cff_data: CffData = .empty;
    if (table_offsets[@backingInt(TableId.glyf)] == 0) {
        cff_data = try .init(bytes[directory.cff_offset..][0..directory.cff_length]);
        if (try cff_data.charstrings.cffIndexCount() != metadata.glyphs) return error.InvalidFontData;
    }
    const glyphs_len = metadata.glyphs;
    const cmap_table = try directory.table(.cmap);
    if (try cmap_table.read(u16, 0) != 0) return error.UnsupportedFontVersion;
    const cmap_tables_len = try cmap_table.read(u16, 2);
    _ = try cmap_table.records(4, cmap_tables_len, 8);
    const cmap_offset = table_offsets[@backingInt(TableId.cmap)];
    var index_map: u32 = 0;
    var variation_map: u32 = 0;
    // Preserve the last suitable base map, including record zero. A variation
    // subtable supplements the base map and must never replace it.
    for (0..cmap_tables_len) |i| {
        const record = 4 + 8 * i;
        const platform = try cmap_table.read(u16, record);
        const encoding = try cmap_table.read(u16, record + 2);
        const relative = try cmap_table.read(u32, record + 4);
        const format = try cmap_table.read(u16, relative);
        const offset = cmap_offset + relative;
        if (platform == @backingInt(PlatformId.unicode) and encoding == 5 and format == 14) {
            variation_map = offset;
            continue;
        }
        const supported_platform = platform == @backingInt(PlatformId.unicode) or
            (platform == @backingInt(PlatformId.microsoft) and
                (encoding == @backingInt(MicrosoftEncodingId.unicode_bmp) or encoding == @backingInt(MicrosoftEncodingId.unicode_full)));
        if (!supported_platform) continue;
        switch (format) {
            0, 2, 4, 6, 8, 10, 12, 13 => {
                index_map = offset;
            },
            else => {},
        }
    }
    if (index_map == 0) return error.IndexMapMissing;
    try cmap.validate(cmap_table.bytes, index_map - cmap_offset);
    if (variation_map != 0) try cmap.validate(cmap_table.bytes, variation_map - cmap_offset);

    const index_to_loc_format = metadata.location_format;

    return .{
        .table_offsets = table_offsets,
        .table_lengths = directory.lengths,
        .ttf_bytes = bytes,
        .index_map = index_map,
        .variation_map = variation_map,
        .index_to_loc_format = index_to_loc_format,
        .glyphs_len = glyphs_len,
        .cff_data = cff_data,
    };
}

pub fn codepointGlyphIndex(tt: *const TrueType, codepoint: u21) GlyphIndex {
    return tt.codepointGlyphIndexChecked(codepoint) catch .notdef;
}

/// Returns null when the font does not support this variation sequence.
/// Default sequences use the base character map; explicit mappings may differ.
pub fn codepointVariationGlyphIndex(tt: *const TrueType, codepoint: u21, selector: u21) ?GlyphIndex {
    return tt.codepointVariationGlyphIndexChecked(codepoint, selector) catch null;
}

/// Checked lookup distinguishes malformed data from an unmapped codepoint.
pub fn codepointGlyphIndexChecked(tt: *const TrueType, codepoint: u21) Reader.Error!GlyphIndex {
    const source = try tt.tableReader(.cmap);
    const start = tt.table_offsets[@backingInt(TableId.cmap)];
    if (tt.index_map < start) return error.InvalidFontData;
    const result = try cmap.glyphIndex(source.bytes, tt.index_map - start, codepoint);
    if (@backingInt(result) >= tt.glyphs_len) return error.InvalidFontData;
    return result;
}

pub fn codepointVariationGlyphIndexChecked(tt: *const TrueType, codepoint: u21, selector: u21) Reader.Error!?GlyphIndex {
    if (tt.variation_map == 0) return null;
    const source = try tt.tableReader(.cmap);
    const start = tt.table_offsets[@backingInt(TableId.cmap)];
    if (tt.variation_map < start) return error.InvalidFontData;
    const result = try cmap.variationGlyphIndex(source.bytes, tt.variation_map - start, codepoint, selector, try tt.codepointGlyphIndexChecked(codepoint));
    if (result) |glyph| if (@backingInt(glyph) >= tt.glyphs_len) return error.InvalidFontData;
    return result;
}

pub const GlyphBitmap = struct {
    width: u16,
    height: u16,
    /// Offset in pixel space from the glyph origin to the left of the bitmap.
    off_x: i16,
    /// Offset in pixel space from the glyph origin to the top of the bitmap.
    off_y: i16,

    pub const empty: GlyphBitmap = .{
        .width = 0,
        .height = 0,
        .off_x = 0,
        .off_y = 0,
    };
};

pub const GlyphBitmapError = cff.GlyphShapeError || Reader.Error || Limits.Error || error{ InvalidCompositeGlyph, InvalidRenderParameters, BitmapTooLarge };
pub const CharstringCtx = cff.CharstringCtx;

pub const RasterizerWorkspace = rasterizer.Workspace;

/// Appends a bitmap to caller-owned pixels, reusing temporary workspace storage.
/// Both allocators must outlive their allocations. Do not use the workspace's
/// temporary allocator for pixels: its storage is reset after every render.
pub fn glyphBitmapWithWorkspace(
    tt: *const TrueType,
    gpa: Allocator,
    pixels: *ArrayList(u8),
    workspace: *RasterizerWorkspace,
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
) GlyphBitmapError!GlyphBitmap {
    return glyphBitmapSubpixelWithWorkspace(tt, gpa, pixels, workspace, glyph, scale_x, scale_y, 0, 0);
}

/// Subpixel variant of glyphBitmapWithWorkspace. Workspace storage is reset on
/// success and failure; a failed render leaves the pixel list length unchanged.
pub fn glyphBitmapSubpixelWithWorkspace(
    tt: *const TrueType,
    gpa: Allocator,
    pixels: *ArrayList(u8),
    workspace: *RasterizerWorkspace,
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
) GlyphBitmapError!GlyphBitmap {
    defer workspace.reset();
    return glyphBitmapSubpixelInner(tt, gpa, workspace.allocator(), pixels, glyph, scale_x, scale_y, shift_x, shift_y);
}

/// Caller owns returned memory.
pub fn glyphBitmap(
    tt: *const TrueType,
    gpa: Allocator,
    /// Appended to the list.
    /// Stored left-to-right, top-to-bottom. 8 bits per pixel. 0 is
    /// transparent, 255 is opaque.
    pixels: *std.ArrayListUnmanaged(u8),
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
) GlyphBitmapError!GlyphBitmap {
    return glyphBitmapSubpixel(tt, gpa, pixels, glyph, scale_x, scale_y, 0, 0);
}

/// Caller owns returned memory.
pub fn glyphBitmapSubpixel(
    tt: *const TrueType,
    gpa: Allocator,
    /// Appended to the list.
    /// Stored left-to-right, top-to-bottom. 8 bits per pixel. 0 is
    /// transparent, 255 is opaque.
    pixels: *std.ArrayListUnmanaged(u8),
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
) GlyphBitmapError!GlyphBitmap {
    return glyphBitmapSubpixelInner(tt, gpa, gpa, pixels, glyph, scale_x, scale_y, shift_x, shift_y);
}

fn glyphBitmapSubpixelInner(
    tt: *const TrueType,
    gpa: Allocator,
    scratch: Allocator,
    pixels: *ArrayList(u8),
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
) GlyphBitmapError!GlyphBitmap {
    try validateRenderParameters(scale_x, scale_y, shift_x, shift_y);
    const vertices = try glyphShape(tt, scratch, glyph);
    defer scratch.free(vertices);
    if (vertices.len == 0) return .empty;

    const box = try glyphBitmapBoxSubpixelChecked(tt, glyph, scale_x, scale_y, shift_x, shift_y);
    const wide_w = @as(i64, box.x1) - box.x0;
    const wide_h = @as(i64, box.y1) - box.y0;
    if (wide_w < 0 or wide_h < 0 or wide_w > 65535 or wide_h > 65535 or
        box.x0 < -32768 or box.x0 > 32767 or box.y0 < -32768 or box.y0 > 32767)
        return error.BitmapTooLarge;
    const w: u32 = @intCast(wide_w);
    const h: u32 = @intCast(wide_h);

    if (w == 0 or h == 0) return .empty;
    if (@as(u64, w) * h > tt.limits.max_bitmap_pixels) return error.ResourceLimitExceeded;

    var gbm: rasterizer.Bitmap = .{
        .w = w,
        .h = h,
        .stride = w,
        .pixels = try pixels.addManyAsSlice(gpa, w * h),
    };
    errdefer pixels.shrinkRetainingCapacity(pixels.items.len - gbm.pixels.len);

    try rasterizer.rasterizeWithLimits(tt.limits, scratch, &gbm, 0.35, vertices, scale_x, scale_y, shift_x, shift_y, box.x0, box.y0, true);

    return .{
        .width = @intCast(gbm.w),
        .height = @intCast(gbm.h),
        .off_x = @intCast(box.x0),
        .off_y = @intCast(box.y0),
    };
}

/// Returns zero for invalid height or malformed metrics; use the checked variant
/// to distinguish these conditions. Height must be finite and strictly positive.
pub fn scaleForPixelHeight(tt: *const TrueType, height: f32) f32 {
    return tt.scaleForPixelHeightChecked(height) catch 0;
}

pub fn scaleForPixelHeightChecked(tt: *const TrueType, height: f32) GlyphBitmapError!f32 {
    if (!std.math.isFinite(height) or height <= 0) return error.InvalidRenderParameters;
    const vm = try tt.verticalMetricsChecked();
    const fheight: f32 = @floatFromInt(@as(i32, vm.ascent) - vm.descent);
    const result = height / fheight;
    if (result == 0) return error.InvalidRenderParameters;
    return result;
}

pub const VerticalMetrics = metrics.Vertical;
pub const HMetrics = metrics.Horizontal;

/// Unscaled font units. Widen to i32 before subtracting ascent and descent.
/// Malformed data returns zero metrics; the checked variant reports the error.
pub fn verticalMetrics(tt: *const TrueType) VerticalMetrics {
    return tt.verticalMetricsChecked() catch .{ .ascent = 0, .descent = 0, .line_gap = 0 };
}

pub fn verticalMetricsChecked(tt: *const TrueType) Reader.Error!VerticalMetrics {
    return metrics.vertical(try tt.tableReader(.hhea));
}

pub fn glyphHMetrics(tt: *const TrueType, glyph: GlyphIndex) HMetrics {
    return tt.glyphHMetricsChecked(glyph) catch .{ .advance_width = 0, .left_side_bearing = 0 };
}

pub fn glyphHMetricsChecked(tt: *const TrueType, glyph: GlyphIndex) Reader.Error!HMetrics {
    return metrics.horizontal(try tt.tableReader(.hhea), try tt.tableReader(.hmtx), @backingInt(glyph), tt.glyphs_len);
}

/// An additional amount to advance the horizontal coordinate between the two
/// provided glyphs, in font units. For GPOS, returns the first matching pair's
/// base X advance for the first glyph. Placement, second-glyph adjustments, and
/// device/variation deltas are not applied.
pub fn glyphKernAdvance(tt: *const TrueType, a: GlyphIndex, b: GlyphIndex) i16 {
    return tt.glyphKernAdvanceChecked(a, b) catch 0;
}

/// Reports malformed positioning data. Unsupported lookup kinds contribute zero.
pub fn glyphKernAdvanceChecked(tt: *const TrueType, a: GlyphIndex, b: GlyphIndex) Reader.Error!i16 {
    if (tt.table_offsets[@backingInt(TableId.GPOS)] != 0 and tt.table_lengths[@backingInt(TableId.GPOS)] != 0)
        return kerning.gpos(try tt.tableReader(.GPOS), a, b);
    if (tt.table_offsets[@backingInt(TableId.kern)] != 0 and tt.table_lengths[@backingInt(TableId.kern)] != 0)
        return kerning.kern(try tt.tableReader(.kern), a, b);
    return 0;
}

pub const Vertex = @import("glyph.zig").Vertex;

pub fn glyphShape(tt: *const TrueType, gpa: Allocator, glyph: GlyphIndex) GlyphBitmapError![]Vertex {
    if (tt.cff_data.cff.size != 0) return cff.glyphShapeWithLimits(&tt.cff_data, gpa, glyph, tt.limits);
    const view = try tt.outlineFont();
    return view.shape(gpa, glyph);
}

fn tableReader(tt: *const TrueType, id: TableId) Reader.Error!Reader {
    const i = @backingInt(id);
    return .{ .bytes = try (Reader{ .bytes = tt.ttf_bytes }).span(tt.table_offsets[i], tt.table_lengths[i]) };
}

pub const BitmapBox = @import("glyph.zig").BitmapBox;

pub fn glyphBitmapBoxSubpixel(
    tt: *const TrueType,
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
) BitmapBox {
    return tt.glyphBitmapBoxSubpixelChecked(glyph, scale_x, scale_y, shift_x, shift_y) catch .empty;
}

fn validateRenderParameters(sx: f32, sy: f32, dx: f32, dy: f32) error{InvalidRenderParameters}!void {
    if (!std.math.isFinite(sx) or !std.math.isFinite(sy) or sx <= 0 or sy <= 0 or
        !std.math.isFinite(dx) or !std.math.isFinite(dy)) return error.InvalidRenderParameters;
}

fn pixelCoordinate(value: f32) error{BitmapTooLarge}!i32 {
    // f32 cannot represent maxInt(i32) exactly. Compare after widening.
    if (!std.math.isFinite(value) or @as(f64, value) < -2147483648 or @as(f64, value) > 2147483647)
        return error.BitmapTooLarge;
    return @intFromFloat(value);
}

pub fn glyphBitmapBoxSubpixelChecked(
    tt: *const TrueType,
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
) GlyphBitmapError!BitmapBox {
    try validateRenderParameters(scale_x, scale_y, shift_x, shift_y);
    const box = try tt.glyphBoxChecked(glyph) orelse return .empty;
    return .{
        .x0 = try pixelCoordinate(@floor(@as(f32, @floatFromInt(box.x0)) * scale_x + shift_x)),
        .y0 = try pixelCoordinate(@floor(@as(f32, @floatFromInt(-box.y1)) * scale_y + shift_y)),
        .x1 = try pixelCoordinate(@ceil(@as(f32, @floatFromInt(box.x1)) * scale_x + shift_x)),
        .y1 = try pixelCoordinate(@ceil(@as(f32, @floatFromInt(-box.y0)) * scale_y + shift_y)),
    };
}

pub fn glyphBitmapBox(
    tt: *const TrueType,
    glyph: GlyphIndex,
    scale_x: f32,
    scale_y: f32,
) BitmapBox {
    return glyphBitmapBoxSubpixel(tt, glyph, scale_x, scale_y, 0, 0);
}

pub fn glyphBitmapBoxChecked(tt: *const TrueType, glyph: GlyphIndex, scale_x: f32, scale_y: f32) GlyphBitmapError!BitmapBox {
    return tt.glyphBitmapBoxSubpixelChecked(glyph, scale_x, scale_y, 0, 0);
}

pub fn glyphBox(tt: *const TrueType, glyph: GlyphIndex) ?BitmapBox {
    return tt.glyphBoxChecked(glyph) catch null;
}

/// Null denotes no outline; malformed data is an error.
pub fn glyphBoxChecked(tt: *const TrueType, glyph: GlyphIndex) GlyphBitmapError!?BitmapBox {
    if (tt.cff_data.cff.size != 0) return cff.glyphBoxWithLimits(&tt.cff_data, glyph, tt.limits);
    const view = try tt.outlineFont();
    return view.box(glyph);
}

fn outlineFont(tt: *const TrueType) Reader.Error!OutlineFont {
    return .{
        .loca = try tt.tableReader(.loca),
        .glyf = try tt.tableReader(.glyf),
        .glyphs_len = tt.glyphs_len,
        .index_to_loc_format = tt.index_to_loc_format,
        .limits = tt.limits,
    };
}
