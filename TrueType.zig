const std = @import("std");
const readInt = std.mem.readInt;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

const TrueType = @This();
const rasterizer = @import("rasterizer.zig");
const cff = @import("cff.zig");
const cmap = @import("cmap.zig");
const CffData = cff.CffData;
const sfnt = @import("sfnt.zig");
const Reader = @import("reader.zig");
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
    return if (tt.cff_data.cff.size != 0)
        cff.glyphShapeWithLimits(&tt.cff_data, gpa, glyph, tt.limits)
    else
        tt.glyphShapeTT(gpa, glyph);
}

const OutlinePoint = struct {
    x: f32,
    y: f32,

    fn transform(p: OutlinePoint, m: [6]f32) OutlinePoint {
        return .{ .x = m[0] * p.x + m[2] * p.y + m[4], .y = m[1] * p.x + m[3] * p.y + m[5] };
    }
};

fn glyphShapeTT(tt: *const TrueType, gpa: Allocator, glyph: GlyphIndex) GlyphBitmapError![]Vertex {
    var budget: OutlineBudget = .{ .vertices = tt.limits.max_outline_vertices, .components = tt.limits.max_components };
    return glyphShapeTTInner(tt, gpa, glyph, null, 0, &budget);
}

const OutlineBudget = struct { vertices: u32, components: u32 };

fn glyphShapeTTInner(
    tt: *const TrueType,
    gpa: Allocator,
    glyph: GlyphIndex,
    outline_points: ?*ArrayList(OutlinePoint),
    depth: u32,
    budget: *OutlineBudget,
) GlyphBitmapError![]Vertex {
    try Limits.consume(&budget.components, 1);
    if (depth >= 64) return error.RecursionLimit;
    if (@backingInt(glyph) >= tt.glyphs_len) return error.InvalidCompositeGlyph;
    const source = try glyphData(tt, glyph);
    const bytes = source.bytes;
    if (bytes.len == 0) return &.{};
    const g: u32 = 0;
    var vertices: ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    const n_contours_signed = try source.read(i16, 0);
    if (n_contours_signed < -1) return error.InvalidFontData;

    if (n_contours_signed > 0) {
        const n_contours: u16 = @intCast(n_contours_signed);
        const contours_end_pts: u32 = g + 10;
        _ = try source.records(contours_end_pts, n_contours, 2);
        var previous: ?u16 = null;
        for (0..n_contours) |contour| {
            const end = try source.read(u16, contours_end_pts + contour * 2);
            if (previous) |last| if (end <= last) return error.InvalidFontData;
            previous = end;
        }
        const instruction_offset: u32 = contours_end_pts + @as(u32, n_contours) * 2;
        const instructions = try source.read(u16, instruction_offset);
        _ = try source.span(instruction_offset + 2, instructions);
        var points: u32 = instruction_offset + 2 + instructions;
        const n: u32 = @as(u32, previous.?) + 1;

        // A loose bound on how many vertices we might need.
        const m: u32 = n + 2 * n_contours;
        try Limits.consume(&budget.vertices, m);
        try vertices.resize(gpa, m);

        var next_move: i32 = 0;
        var flagcount: u8 = 0;

        // in first pass, we load uninterpreted data into the allocated array
        // above, shifted to the end of the array so we won't overwrite it when
        // we create our final data starting from the front

        // Starting offset for uninterpreted data, regardless of how m ends up being calculated.
        const off: u32 = m - n;

        // first load flags
        {
            var flags: u8 = 0;
            for (0..n) |i| {
                if (flagcount == 0) {
                    flags = try source.read(u8, points);
                    points += 1;
                    if ((flags & 8) != 0) {
                        flagcount = try source.read(u8, points);
                        if (flagcount >= n - i) return error.InvalidFontData;
                        points += 1;
                    }
                } else {
                    flagcount -= 1;
                }
                vertices.items[off + i].type = @fromBackingInt(@intCast(flags));
            }
        }

        // now load x coordinates
        var x: i32 = 0;
        for (0..n) |i| {
            const flags = @backingInt(vertices.items[off + i].type);
            if ((flags & 2) != 0) {
                const dx: i16 = try source.read(u8, points);
                points += 1;
                x += if ((flags & 16) != 0) dx else -dx;
            } else {
                if ((flags & 16) == 0) {
                    x += try source.read(i16, points);
                    points += 2;
                }
            }
            vertices.items[off + i].x = std.math.cast(i16, x) orelse return error.CoordinateOutOfRange;
        }

        // now load y coordinates
        var y: i32 = 0;
        for (0..n) |i| {
            const flags = @backingInt(vertices.items[off + i].type);
            if ((flags & 4) != 0) {
                const dy: i16 = try source.read(u8, points);
                points += 1;
                y += if ((flags & 32) != 0) dy else -dy;
            } else {
                if ((flags & 32) == 0) {
                    y += try source.read(i16, points);
                    points += 2;
                }
            }
            vertices.items[off + i].y = std.math.cast(i16, y) orelse return error.CoordinateOutOfRange;
        }

        // Keep the original on- and off-curve point order for composite
        // attachments, before inserting implied points or closing contours.
        if (outline_points) |out| {
            const raw = try out.addManyAsSlice(gpa, n);
            for (raw, vertices.items[off..][0..n]) |*point, vertex| {
                point.* = .{ .x = @floatFromInt(vertex.x), .y = @floatFromInt(vertex.y) };
            }
        }

        // now convert them to our format
        var num_vertices: u32 = 0;
        var sx: i32 = 0;
        var sy: i32 = 0;
        var cx: i32 = 0;
        var cy: i32 = 0;
        var scx: i32 = 0;
        var scy: i32 = 0;
        var i: u32 = 0;
        var j: u32 = 0;
        var start_off: bool = false;
        var was_off: bool = false;
        while (i < n) : (i += 1) {
            const flags = @backingInt(vertices.items[off + i].type);
            x = @intCast(vertices.items[off + i].x);
            y = @intCast(vertices.items[off + i].y);

            if (next_move == i) {
                if (i != 0)
                    num_vertices = closeShape(vertices.items, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);

                // now start the new one
                start_off = (flags & 1) == 0;
                if (start_off) {
                    // if we start off with an off-curve point, then when we need to find a point on the curve
                    // where we can start, and we need to save some state for when we wraparound.
                    scx = x;
                    scy = y;
                    const contour_end = try source.read(u16, contours_end_pts + j * 2);
                    if (i == contour_end) {
                        // A one-point off-curve contour must not read the next contour.
                        sx = x;
                        sy = y;
                    } else if ((@backingInt(vertices.items[off + i + 1].type) & 1) == 0) {
                        // next point is also a curve point, so interpolate an on-point curve
                        sx = (x + vertices.items[off + i + 1].x) >> 1;
                        sy = (y + vertices.items[off + i + 1].y) >> 1;
                    } else {
                        // otherwise just use the next point as our start point
                        sx = vertices.items[off + i + 1].x;
                        sy = vertices.items[off + i + 1].y;
                        i += 1; // we're using point i+1 as the starting point, so skip it
                    }
                } else {
                    sx = x;
                    sy = y;
                }
                vertices.items[num_vertices].set(.vmove, sx, sy, 0, 0);
                num_vertices += 1;
                was_off = false;
                next_move = 1 + try source.read(u16, contours_end_pts + j * 2);
                j += 1;
            } else {
                if ((flags & 1) == 0) { // if it's a curve
                    if (was_off) {
                        // two off-curve control points in a row means interpolate an on-curve midpoint
                        vertices.items[num_vertices].set(.vcurve, (cx + x) >> 1, (cy + y) >> 1, cx, cy);
                        num_vertices += 1;
                    }
                    cx = x;
                    cy = y;
                    was_off = true;
                } else {
                    if (was_off)
                        vertices.items[num_vertices].set(.vcurve, x, y, cx, cy)
                    else
                        vertices.items[num_vertices].set(.vline, x, y, 0, 0);
                    num_vertices += 1;
                    was_off = false;
                }
            }
        }
        num_vertices = closeShape(vertices.items, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);
        vertices.shrinkRetainingCapacity(num_vertices);
    } else if (n_contours_signed < 0) {
        // Point numbers span all previously incorporated components.
        var parent_points: ArrayList(OutlinePoint) = .empty;
        defer parent_points.deinit(gpa);
        var more = true;
        var have_instructions = false;
        var comp = g + 10;
        while (more) {
            var mtx: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

            const flags = try readCursor(u16, bytes, &comp);
            if (@popCount(flags & 0xc8) > 1 or flags & 0x1800 == 0x1800) return error.InvalidCompositeGlyph;
            have_instructions = have_instructions or flags & 0x100 != 0;
            const gidx: GlyphIndex = @fromBackingInt(@intCast(try readCursor(u16, bytes, &comp)));

            var parent_point: u16 = 0;
            var child_point: u16 = 0;
            const xy_values = (flags & 2) != 0;
            if (xy_values) { // XY values
                if ((flags & 1) != 0) { // shorts
                    mtx[4] = @floatFromInt(try readCursor(i16, bytes, &comp));
                    mtx[5] = @floatFromInt(try readCursor(i16, bytes, &comp));
                } else {
                    mtx[4] = @floatFromInt(try readCursor(i8, bytes, &comp));
                    mtx[5] = @floatFromInt(try readCursor(i8, bytes, &comp));
                }
            } else {
                // Point indices are unsigned, unlike XY offsets.
                parent_point = if (flags & 1 != 0) try readCursor(u16, bytes, &comp) else try readCursor(u8, bytes, &comp);
                child_point = if (flags & 1 != 0) try readCursor(u16, bytes, &comp) else try readCursor(u8, bytes, &comp);
            }
            if ((flags & (1 << 3)) != 0) { // WE_HAVE_A_SCALE
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = mtx[0];
            } else if ((flags & (1 << 6)) != 0) { // WE_HAVE_AN_X_AND_YSCALE
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
            } else if ((flags & (1 << 7)) != 0) { // WE_HAVE_A_TWO_BY_TWO
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[2] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[3] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
            }

            var child_points: ArrayList(OutlinePoint) = .empty;
            defer child_points.deinit(gpa);
            const comp_verts = try glyphShapeTTInner(tt, gpa, gidx, &child_points, depth + 1, budget);
            defer gpa.free(comp_verts);

            if (xy_values) {
                // The default offset is in parent coordinates. Only an explicit
                // SCALED_COMPONENT_OFFSET applies the matrix to the offset too.
                if (flags & 0x1800 == 0x0800) {
                    const dx = mtx[4];
                    const dy = mtx[5];
                    mtx[4] = mtx[0] * dx + mtx[2] * dy;
                    mtx[5] = mtx[1] * dx + mtx[3] * dy;
                }
            } else {
                if (parent_point >= parent_points.items.len or child_point >= child_points.items.len)
                    return error.InvalidCompositeGlyph;
                const anchor = child_points.items[child_point].transform(mtx);
                mtx[4] = parent_points.items[parent_point].x - anchor.x;
                mtx[5] = parent_points.items[parent_point].y - anchor.y;
            }

            for (comp_verts) |*v| {
                const end = (OutlinePoint{ .x = @floatFromInt(v.x), .y = @floatFromInt(v.y) }).transform(mtx);
                const control = (OutlinePoint{ .x = @floatFromInt(v.cx), .y = @floatFromInt(v.cy) }).transform(mtx);
                v.x = try vertexCoordinate(end.x);
                v.y = try vertexCoordinate(end.y);
                if (v.type == .vcurve) {
                    v.cx = try vertexCoordinate(control.x);
                    v.cy = try vertexCoordinate(control.y);
                }
            }
            try Limits.consume(&budget.vertices, comp_verts.len + child_points.items.len);
            try vertices.appendSlice(gpa, comp_verts);
            for (child_points.items) |point| try parent_points.append(gpa, point.transform(mtx));
            more = (flags & (1 << 5)) != 0;
        }
        if (have_instructions) {
            const length = try readCursor(u16, bytes, &comp);
            _ = try source.span(comp, length);
        }
        if (outline_points) |out| try out.appendSlice(gpa, parent_points.items);
    }
    return vertices.toOwnedSlice(gpa);
}

fn tableReader(tt: *const TrueType, id: TableId) Reader.Error!Reader {
    const i = @backingInt(id);
    return .{ .bytes = try (Reader{ .bytes = tt.ttf_bytes }).span(tt.table_offsets[i], tt.table_lengths[i]) };
}

fn glyphData(tt: *const TrueType, glyph: GlyphIndex) GlyphBitmapError!Reader {
    const index: usize = @backingInt(glyph);
    if (index >= tt.glyphs_len) return error.InvalidCompositeGlyph;
    if (tt.index_to_loc_format > 1) return error.InvalidFontData;
    const loca = try tt.tableReader(.loca);
    const glyf = try tt.tableReader(.glyf);
    const start: u32, const end: u32 = if (tt.index_to_loc_format == 0) .{
        @as(u32, try loca.read(u16, index * 2)) * 2,
        @as(u32, try loca.read(u16, index * 2 + 2)) * 2,
    } else .{
        try loca.read(u32, index * 4),
        try loca.read(u32, index * 4 + 4),
    };
    if (end < start) return error.InvalidFontData;
    const source: Reader = .{ .bytes = try glyf.span(start, end - start) };
    if (source.bytes.len != 0) {
        _ = try source.span(0, 10);
        if (try source.read(i16, 2) > try source.read(i16, 6) or
            try source.read(i16, 4) > try source.read(i16, 8)) return error.InvalidFontData;
    }
    return source;
}

fn vertexCoordinate(value: f32) error{CoordinateOutOfRange}!i16 {
    const rounded = @trunc(value);
    if (!std.math.isFinite(rounded) or rounded < -32768 or rounded > 32767) return error.CoordinateOutOfRange;
    return @intFromFloat(rounded);
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
    const source = try glyphData(tt, glyph);
    if (source.bytes.len == 0) return null;
    return .{
        .x0 = try source.read(i16, 2),
        .y0 = try source.read(i16, 4),
        .x1 = try source.read(i16, 6),
        .y1 = try source.read(i16, 8),
    };
}

fn closeShape(
    vertices: []Vertex,
    vertices_len_start: u32,
    was_off: bool,
    start_off: bool,
    sx: i32,
    sy: i32,
    scx: i32,
    scy: i32,
    cx: i32,
    cy: i32,
) u32 {
    var vertices_len = vertices_len_start;
    if (start_off) {
        if (was_off) {
            vertices[vertices_len].set(.vcurve, (cx + scx) >> 1, (cy + scy) >> 1, cx, cy);
            vertices_len += 1;
        }
        vertices[vertices_len].set(.vcurve, sx, sy, scx, scy);
        vertices_len += 1;
    } else {
        if (was_off) {
            vertices[vertices_len].set(.vcurve, sx, sy, cx, cy);
            vertices_len += 1;
        } else {
            vertices[vertices_len].set(.vline, sx, sy, 0, 0);
            vertices_len += 1;
        }
    }
    return vertices_len;
}

fn readCursor(comptime I: type, bytes: []const u8, cursor: *u32) Reader.Error!I {
    const start = cursor.*;
    const result = try (Reader{ .bytes = bytes }).read(I, start);
    cursor.* = start + @sizeOf(I);
    return result;
}
