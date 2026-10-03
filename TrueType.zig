const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const std = @import("std");
const readInt = std.mem.readInt;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArrayList = std.ArrayListUnmanaged;

const TrueType = @This();
const rasterizer = @import("rasterizer.zig");
const cff = @import("cff.zig");
const CffData = cff.CffData;
const build_options = @import("build_options");
const debug_todo = build_options.debug_todo or builtin.is_test;

table_offsets: [@typeInfo(TableId).@"enum".field_names.len]u32,
ttf_bytes: []const u8,
index_map: u32,
index_to_loc_format: u16,
glyphs_len: u32,
cff_data: CffData,

pub const GlyphIndex = @import("glyph.zig").GlyphIndex;

pub const TableId = enum {
    cmap,
    loca,
    head,
    glyf,
    hhea,
    hmtx,
    kern,
    GPOS,
    maxp,

    fn asInt(id: TableId) u32 {
        const array4: [4]u8 = @tagName(id).*;
        return @bitCast(array4);
    }
};

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
} || CffData.InitError;

pub fn load(bytes: []const u8) LoadError!TrueType {
    // Find tables.
    var table_offsets: [@typeInfo(TableId).@"enum".field_names.len]u32 = @splat(0);
    if (bytes.len < 6) return error.EndOfStream;
    const tables_len = readInt(u16, bytes[4..][0..2], .big);
    if (12 + 16 * tables_len > bytes.len) return error.EndOfStream;
    var cff_offset: u32 = 0;
    var cff_length: u32 = 0;
    for (0..tables_len) |i| {
        const loc = 12 + 16 * i;
        const id: TableId = switch (readInt(u32, bytes[loc..][0..4], native_endian)) {
            TableId.cmap.asInt() => .cmap,
            TableId.loca.asInt() => .loca,
            TableId.head.asInt() => .head,
            TableId.glyf.asInt() => .glyf,
            TableId.hhea.asInt() => .hhea,
            TableId.hmtx.asInt() => .hmtx,
            TableId.kern.asInt() => .kern,
            TableId.GPOS.asInt() => .GPOS,
            TableId.maxp.asInt() => .maxp,
            readInt(u32, "CFF ", native_endian) => {
                cff_offset = readInt(u32, bytes[loc + 8 ..][0..4], .big);
                cff_length = readInt(u32, bytes[loc + 12 ..][0..4], .big);
                continue;
            },
            else => continue,
        };
        table_offsets[@backingInt(id)] = readInt(u32, bytes[loc + 8 ..][0..4], .big);
    }

    if (table_offsets[@backingInt(TableId.cmap)] == 0) return error.MissingRequiredTable;
    if (table_offsets[@backingInt(TableId.head)] == 0) return error.MissingRequiredTable;
    if (table_offsets[@backingInt(TableId.hhea)] == 0) return error.MissingRequiredTable;
    if (table_offsets[@backingInt(TableId.hmtx)] == 0) return error.MissingRequiredTable;

    var cff_data: CffData = .empty;

    if (table_offsets[@backingInt(TableId.glyf)] != 0) {
        if (table_offsets[@backingInt(TableId.loca)] == 0) return error.MissingRequiredTable;
    } else {
        if (cff_offset == 0) return error.MissingRequiredTable;
        if (cff_offset > bytes.len or cff_length > bytes.len - cff_offset) return error.EndOfStream;
        cff_data = try .init(bytes[cff_offset..][0..cff_length]);
    }

    const maxp = table_offsets[@backingInt(TableId.maxp)];
    const glyphs_len = if (maxp == 0) 0xffff else readInt(u16, bytes[maxp + 4 ..][0..2], .big);

    const cmap = table_offsets[@backingInt(TableId.cmap)];
    const cmap_tables_len = readInt(u16, bytes[cmap + 2 ..][0..2], .big);
    const index_map = im: {
        var i = cmap_tables_len;
        while (true) {
            i -= 1;
            if (i == 0) return error.IndexMapMissing;
            const encoding_record = cmap + 4 + 8 * i;
            const platform_id = readInt(u16, bytes[encoding_record..][0..2], .big);
            switch (platform_id) {
                @backingInt(PlatformId.microsoft) => switch (readInt(u16, bytes[encoding_record + 2 ..][0..2], .big)) {
                    @backingInt(MicrosoftEncodingId.unicode_bmp),
                    @backingInt(MicrosoftEncodingId.unicode_full),
                    => {
                        break :im cmap + readInt(u32, bytes[encoding_record + 4 ..][0..4], .big);
                    },
                    else => continue,
                },
                @backingInt(PlatformId.unicode) => {
                    break :im cmap + readInt(u32, bytes[encoding_record + 4 ..][0..4], .big);
                },
                else => continue,
            }
        }
    };

    const head = table_offsets[@backingInt(TableId.head)];
    const index_to_loc_format = readInt(u16, bytes[head + 50 ..][0..2], .big);

    return .{
        .table_offsets = table_offsets,
        .ttf_bytes = bytes,
        .index_map = index_map,
        .index_to_loc_format = index_to_loc_format,
        .glyphs_len = glyphs_len,
        .cff_data = cff_data,
    };
}

pub fn codepointGlyphIndex(tt: *const TrueType, codepoint: u21) GlyphIndex {
    const bytes = tt.ttf_bytes;
    const index_map = tt.index_map;
    const format = readInt(u16, bytes[index_map..][0..2], .big);
    switch (format) {
        0 => {
            const n = readInt(u16, bytes[index_map + 2 ..][0..2], .big);
            if (codepoint < n - 6)
                return @fromBackingInt(@intCast(bytes[index_map + 6 + codepoint]));

            return .notdef;
        },
        2 => {
            // https://codeberg.org/andrewrk/TrueType/issues/46
            if (debug_todo) @panic("TODO implement high-byte mapping for japanese/chinese/korean");
            return .notdef;
        },
        4 => {
            const seg_count = readInt(u16, bytes[index_map + 6 ..][0..2], .big) >> 1;
            var search_range = readInt(u16, bytes[index_map + 8 ..][0..2], .big) >> 1;
            var entry_selector = readInt(u16, bytes[index_map + 10 ..][0..2], .big);
            const range_shift = readInt(u16, bytes[index_map + 12 ..][0..2], .big) >> 1;

            // Do a binary search of the segments.
            const end_count = index_map + 14;
            var search = end_count;

            if (codepoint > 0xffff)
                return .notdef;

            // They lie from end_count .. end_count + seg_count but search_range
            // is the nearest power of two.
            if (codepoint >= readInt(u16, bytes[search + range_shift * 2 ..][0..2], .big))
                search += range_shift * 2;

            // Now decrement to bias correctly to find smallest.
            search -= 2;
            while (entry_selector > 0) {
                search_range >>= 1;
                const end = readInt(u16, bytes[search + search_range * 2 ..][0..2], .big);
                if (codepoint > end)
                    search += search_range * 2;
                entry_selector -= 1;
            }
            search += 2;

            const item: u16 = @intCast((search - end_count) >> 1);

            const start = readInt(u16, bytes[index_map + 14 + seg_count * 2 + 2 + 2 * item ..][0..2], .big);
            const last = readInt(u16, bytes[end_count + 2 * item ..][0..2], .big);
            if (codepoint < start or codepoint > last)
                return .notdef;

            const offset = readInt(u16, bytes[index_map + 14 + seg_count * 6 + 2 + 2 * item ..][0..2], .big);
            if (offset == 0) {
                const result = @as(i32, codepoint) + readInt(i16, bytes[index_map + 14 + seg_count * 4 + 2 + 2 * item ..][0..2], .big);
                // truncate to u16
                return @fromBackingInt(@intCast(@as(u16, @truncate(@as(u32, @bitCast(result))))));
            }

            return @fromBackingInt(@intCast(readInt(u16, bytes[offset + (codepoint - start) * 2 + index_map + 14 + seg_count * 6 + 2 + 2 * item ..][0..2], .big)));
        },
        6 => {
            const first = readInt(u16, bytes[index_map + 6 ..][0..2], .big);
            const count = readInt(u16, bytes[index_map + 8 ..][0..2], .big);
            if (codepoint >= first and codepoint < first + count)
                return @fromBackingInt(@intCast(readInt(u16, bytes[index_map + 10 + (codepoint - first) * 2 ..][0..2], .big)));

            return .notdef;
        },
        12, 13 => {
            const ngroups = readInt(u32, bytes[index_map + 12 ..][0..4], .big);
            var low: u32 = 0;
            var high: u32 = ngroups;
            // Binary search the right group.
            while (low < high) {
                const mid = low + ((high - low) >> 1); // rounds down, so low <= mid < high
                const off = index_map + 16 + mid * 12;
                const start_char = readInt(u32, bytes[off..][0..4], .big);
                const end_char = readInt(u32, bytes[off + 4 ..][0..4], .big);
                if (codepoint < start_char) {
                    high = mid;
                } else if (codepoint > end_char) {
                    low = mid + 1;
                } else {
                    const start_glyph = readInt(u32, bytes[off + 8 ..][0..4], .big);
                    return @fromBackingInt(@intCast(start_glyph + if (format == 12) codepoint - start_char else 0));
                }
            }
            return .notdef;
        },
        else => {
            // https://codeberg.org/andrewrk/TrueType/issues/47
            if (debug_todo) @panic("TODO implement glyphIndex for more formats");
            return .notdef;
        },
    }
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

pub const GlyphBitmapError = cff.GlyphShapeError || error{InvalidCompositeGlyph};
pub const CharstringCtx = cff.CharstringCtx;

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
    const vertices = try glyphShape(tt, gpa, glyph);
    defer gpa.free(vertices);

    assert(scale_x != 0);
    assert(scale_y != 0);

    const box = glyphBitmapBoxSubpixel(tt, glyph, scale_x, scale_y, shift_x, shift_y);

    const w: u32 = @intCast(box.x1 - box.x0);
    const h: u32 = @intCast(box.y1 - box.y0);

    if (w == 0 or h == 0) return .empty;

    var gbm: rasterizer.Bitmap = .{
        .w = w,
        .h = h,
        .stride = w,
        .pixels = try pixels.addManyAsSlice(gpa, w * h),
    };
    errdefer pixels.shrinkRetainingCapacity(pixels.items.len - gbm.pixels.len);

    try rasterizer.rasterize(gpa, &gbm, 0.35, vertices, scale_x, scale_y, shift_x, shift_y, box.x0, box.y0, true);

    return .{
        .width = @intCast(gbm.w),
        .height = @intCast(gbm.h),
        .off_x = @intCast(box.x0),
        .off_y = @intCast(box.y0),
    };
}

pub fn scaleForPixelHeight(tt: *const TrueType, height: f32) f32 {
    const vm = tt.verticalMetrics();
    const fheight: f32 = @floatFromInt(vm.ascent - vm.descent);
    return height / fheight;
}

pub const VerticalMetrics = struct {
    /// The coordinate above the baseline the font extends.
    ascent: i16,
    /// The coordinate below the baseline the font extends (typically negative).
    descent: i16,
    /// The spacing between one row's descent and the next row's ascent.
    line_gap: i16,
};

/// A typical expression for advancing the vertical position is
/// `ascent - descent + line_gap`. These are expressed in unscaled coordinates,
/// which are typically then multiplied by the scale factor for a given font size.
pub fn verticalMetrics(tt: *const TrueType) VerticalMetrics {
    const bytes = tt.ttf_bytes;
    const hhea = tt.table_offsets[@backingInt(TableId.hhea)];
    return .{
        .ascent = readInt(i16, bytes[hhea + 4 ..][0..2], .big),
        .descent = readInt(i16, bytes[hhea + 6 ..][0..2], .big),
        .line_gap = readInt(i16, bytes[hhea + 8 ..][0..2], .big),
    };
}

pub const HMetrics = struct {
    /// The offset from the current horizontal position to the next horizontal
    /// position in unscaled coordinates.
    advance_width: i16,
    /// The offset from the current horizontal position to the left edge of the
    /// character in unscaled coordinates.
    left_side_bearing: i16,
};

pub fn glyphHMetrics(tt: *const TrueType, glyph: GlyphIndex) HMetrics {
    const glyph_index: usize = @backingInt(glyph);
    const bytes = tt.ttf_bytes;
    const hhea = tt.table_offsets[@backingInt(TableId.hhea)];
    const hmtx = tt.table_offsets[@backingInt(TableId.hmtx)];
    const n_long_h_metrics = readInt(u16, bytes[hhea + 34 ..][0..2], .big);
    if (glyph_index < n_long_h_metrics) return .{
        .advance_width = readInt(i16, bytes[hmtx + 4 * glyph_index ..][0..2], .big),
        .left_side_bearing = readInt(i16, bytes[hmtx + 4 * glyph_index + 2 ..][0..2], .big),
    };
    return .{
        .advance_width = readInt(i16, bytes[hmtx + 4 * (n_long_h_metrics - 1) ..][0..2], .big),
        .left_side_bearing = readInt(i16, bytes[hmtx + 4 * n_long_h_metrics + 2 * (glyph_index - n_long_h_metrics) ..][0..2], .big),
    };
}

/// An additional amount to advance the horizontal coordinate between the two
/// provided glyphs, in font units. For GPOS, returns the first matching pair's
/// base X advance for the first glyph. Placement, second-glyph adjustments, and
/// device/variation deltas are not applied.
pub fn glyphKernAdvance(tt: *const TrueType, a: GlyphIndex, b: GlyphIndex) i16 {
    const gpos = tt.table_offsets[@backingInt(TableId.GPOS)];
    if (gpos > 0) return glyphKernAdvanceGpos(tt, a, b);
    const kern = tt.table_offsets[@backingInt(TableId.kern)];
    if (kern > 0) return glyphKernAdvanceKern(tt, a, b);
    return 0;
}

fn glyphKernAdvanceGpos(tt: *const TrueType, a: GlyphIndex, b: GlyphIndex) i16 {
    const bytes = tt.ttf_bytes;
    const gpos = tt.table_offsets[@backingInt(TableId.GPOS)];
    assert(gpos > 0);

    if (readInt(u16, bytes[gpos + 0 ..][0..2], .big) != 1) return 0; // Major version 1
    if (readInt(u16, bytes[gpos + 2 ..][0..2], .big) != 0) return 0; // Minor version 0

    const lookup_list_offset: u16 = readInt(u16, bytes[gpos + 8 ..][0..2], .big);
    const lookup_list = gpos + lookup_list_offset;
    const lookup_count: u16 = readInt(u16, bytes[lookup_list..][0..2], .big);

    for (0..lookup_count) |i| {
        const lookup_offset = readInt(u16, bytes[lookup_list + 2 + 2 * i ..][0..2], .big);
        const lookup_table = lookup_list + lookup_offset;

        const lookup_type = readInt(u16, bytes[lookup_table..][0..2], .big);
        const sub_table_count = readInt(u16, bytes[lookup_table + 4 ..][0..2], .big);
        const sub_table_offsets = lookup_table + 6;
        if (lookup_type != 2 and lookup_type != 9) // Pair Adjustment Positioning Subtable or Positioning Subtable Extension Subtable
            continue;

        for (0..sub_table_count) |sti| {
            const subtable_offset = readInt(u16, bytes[sub_table_offsets + 2 * sti ..][0..2], .big);
            var table = lookup_table + subtable_offset;
            if (lookup_type == 9) {
                const format = readInt(u16, bytes[table + 0 ..][0..2], .big);
                if (format != 1) continue;
                const extension_lookup_type = readInt(u16, bytes[table + 2 ..][0..2], .big);
                if (extension_lookup_type != 2) continue;
                table += readInt(u32, bytes[table + 4 ..][0..4], .big);
            }
            const pos_format = readInt(u16, bytes[table..][0..2], .big);
            const coverage_offset = readInt(u16, bytes[table + 2 ..][0..2], .big);
            const coverage_index = coverageIndex(bytes, table + coverage_offset, a) orelse continue;

            // ValueRecord fields are optional, ordered by their ValueFormat bits.
            // https://learn.microsoft.com/en-us/typography/opentype/spec/gpos#value-record
            if (pos_format != 1 and pos_format != 2) return 0;
            const value_format_1 = readInt(u16, bytes[table + 4 ..][0..2], .big);
            const value_format_2 = readInt(u16, bytes[table + 6 ..][0..2], .big);
            if ((value_format_1 | value_format_2) & 0xff00 != 0) return 0; // reserved bits
            const value_record_pair_size: u32 = 2 * (@as(u32, @popCount(value_format_1)) + @as(u32, @popCount(value_format_2)));

            switch (pos_format) {
                1 => {
                    const pair_set_count = readInt(u16, bytes[table + 8 ..][0..2], .big);
                    if (coverage_index >= pair_set_count) return 0;
                    const pair_pos_offset = readInt(u16, bytes[table + 10 + 2 * coverage_index ..][0..2], .big);
                    const pair_value_table = table + pair_pos_offset;
                    const pair_value_count = readInt(u16, bytes[pair_value_table..][0..2], .big);
                    const pair_value_array = pair_value_table + 2;

                    const needle = @backingInt(b);
                    var r: u32 = pair_value_count;
                    var l: u32 = 0;

                    // Half-open bounds also handle empty pair sets.
                    while (l < r) {
                        const m = l + (r - l) / 2;
                        const pair_value = pair_value_array + (2 + value_record_pair_size) * m;
                        const second_glyph = readInt(u16, bytes[pair_value..][0..2], .big);
                        if (needle < second_glyph) {
                            r = m;
                        } else if (needle > second_glyph) {
                            l = m + 1;
                        } else {
                            return gposXAdvance(bytes, pair_value + 2, value_format_1);
                        }
                    }
                },
                2 => {
                    const class_def10_offset = readInt(u16, bytes[table + 8 ..][0..2], .big);
                    const class_def20_offset = readInt(u16, bytes[table + 10 ..][0..2], .big);
                    const glyph1class = glyphClass(bytes, table + class_def10_offset, a);
                    const glyph2class = glyphClass(bytes, table + class_def20_offset, b);

                    const class1_count = readInt(u16, bytes[table + 12 ..][0..2], .big);
                    const class2_count = readInt(u16, bytes[table + 14 ..][0..2], .big);

                    if (glyph1class >= class1_count) return 0; // malformed
                    if (glyph2class >= class2_count) return 0; // malformed

                    const record = table + 16 + value_record_pair_size * (glyph1class * class2_count + glyph2class);
                    return gposXAdvance(bytes, record, value_format_1);
                },
                else => unreachable,
            }
        }
    }

    return 0;
}

/// The scalar kerning API returns the first glyph's base horizontal advance.
/// Placement, vertical advance, second-glyph adjustments, and device/variation
/// deltas require a positioning API with additional context and are not applied.
fn gposXAdvance(bytes: []const u8, record: u32, value_format: u16) i16 {
    if (value_format & 0x0004 == 0) return 0;
    const offset: u32 = 2 * @as(u32, @popCount(value_format & 0x0003));
    return readInt(i16, bytes[record + offset ..][0..2], .big);
}

fn glyphKernAdvanceKern(tt: *const TrueType, a: GlyphIndex, b: GlyphIndex) i16 {
    const bytes = tt.ttf_bytes;
    const kern = tt.table_offsets[@backingInt(TableId.kern)];
    assert(kern > 0);
    // we only look at the first table. it must be 'horizontal' and format 0.
    if (readInt(u16, bytes[kern + 2 ..][0..2], .big) < 1) // number of tables, need at least 1
        return 0;
    if (readInt(u16, bytes[kern + 8 ..][0..2], .big) != 1) // horizontal flag must be set in format
        return 0;

    const pair_count = readInt(u16, bytes[kern + 10 ..][0..2], .big);
    if (pair_count == 0) return 0;

    var l: u32 = 0;
    var r: u32 = pair_count - 1;
    const needle: u32 = @as(u32, @backingInt(a)) << 16 | @as(u32, @backingInt(b));
    while (l <= r) {
        const m: u32 = (l + r) >> 1;
        const straw: u32 = readInt(u32, bytes[kern + 18 + (m * 6) ..][0..4], .big); // note: unaligned read
        if (needle < straw) {
            if (m == 0) break;
            r = m - 1;
        } else if (needle > straw) {
            l = m + 1;
        } else {
            return readInt(i16, bytes[kern + 22 + (m * 6) ..][0..2], .big);
        }
    }
    return 0;
}

pub const Vertex = @import("glyph.zig").Vertex;

pub fn glyphShape(tt: *const TrueType, gpa: Allocator, glyph: GlyphIndex) GlyphBitmapError![]Vertex {
    return if (tt.cff_data.cff.size != 0)
        cff.glyphShape(&tt.cff_data, gpa, glyph)
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
    return glyphShapeTTInner(tt, gpa, glyph, null, 0);
}

fn glyphShapeTTInner(
    tt: *const TrueType,
    gpa: Allocator,
    glyph: GlyphIndex,
    outline_points: ?*ArrayList(OutlinePoint),
    depth: u32,
) GlyphBitmapError![]Vertex {
    if (depth >= 64) return error.RecursionLimit;
    if (@backingInt(glyph) >= tt.glyphs_len) return error.InvalidCompositeGlyph;
    const bytes = tt.ttf_bytes;
    const g = glyfOffset(tt, glyph) orelse return &.{};
    var vertices: ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    const n_contours_signed = readInt(i16, bytes[g..][0..2], .big);

    if (n_contours_signed > 0) {
        const n_contours: u16 = @intCast(n_contours_signed);
        const contours_end_pts: u32 = g + 10;
        const ins: i32 = readInt(u16, bytes[g + 10 + n_contours * 2 ..][0..2], .big);
        var points: u32 = @intCast(g + 10 + @as(i64, n_contours) * 2 + 2 + ins);

        const n: u32 = 1 + readInt(u16, bytes[contours_end_pts + n_contours * 2 - 2 ..][0..2], .big);

        // A loose bound on how many vertices we might need.
        const m: u32 = n + 2 * n_contours;
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
                    flags = bytes[points];
                    points += 1;
                    if ((flags & 8) != 0) {
                        flagcount = bytes[points];
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
                const dx: i16 = bytes[points];
                points += 1;
                x += if ((flags & 16) != 0) dx else -dx;
            } else {
                if ((flags & 16) == 0) {
                    x += readInt(i16, bytes[points..][0..2], .big);
                    points += 2;
                }
            }
            vertices.items[off + i].x = @intCast(x);
        }

        // now load y coordinates
        var y: i32 = 0;
        for (0..n) |i| {
            const flags = @backingInt(vertices.items[off + i].type);
            if ((flags & 4) != 0) {
                const dy: i16 = bytes[points];
                points += 1;
                y += if ((flags & 32) != 0) dy else -dy;
            } else {
                if ((flags & 32) == 0) {
                    y += readInt(i16, bytes[points..][0..2], .big);
                    points += 2;
                }
            }
            vertices.items[off + i].y = @intCast(y);
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
                    if ((@backingInt(vertices.items[off + i + 1].type) & 1) == 0) {
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
                next_move = 1 + readInt(u16, bytes[contours_end_pts + j * 2 ..][0..2], .big);
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
        var comp = g + 10;
        while (more) {
            var mtx: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

            const flags = readCursor(u16, bytes, &comp);
            const gidx: GlyphIndex = @fromBackingInt(@intCast(readCursor(u16, bytes, &comp)));

            var parent_point: u16 = 0;
            var child_point: u16 = 0;
            const xy_values = (flags & 2) != 0;
            if (xy_values) { // XY values
                if ((flags & 1) != 0) { // shorts
                    mtx[4] = @floatFromInt(readCursor(i16, bytes, &comp));
                    mtx[5] = @floatFromInt(readCursor(i16, bytes, &comp));
                } else {
                    mtx[4] = @floatFromInt(readCursor(i8, bytes, &comp));
                    mtx[5] = @floatFromInt(readCursor(i8, bytes, &comp));
                }
            } else {
                // Point indices are unsigned, unlike XY offsets.
                parent_point = if (flags & 1 != 0) readCursor(u16, bytes, &comp) else readCursor(u8, bytes, &comp);
                child_point = if (flags & 1 != 0) readCursor(u16, bytes, &comp) else readCursor(u8, bytes, &comp);
            }
            if ((flags & (1 << 3)) != 0) { // WE_HAVE_A_SCALE
                mtx[0] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = mtx[0];
            } else if ((flags & (1 << 6)) != 0) { // WE_HAVE_AN_X_AND_YSCALE
                mtx[0] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
            } else if ((flags & (1 << 7)) != 0) { // WE_HAVE_A_TWO_BY_TWO
                mtx[0] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[2] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[3] = @as(f32, @floatFromInt(readCursor(i16, bytes, &comp))) / 16384.0;
            }

            var child_points: ArrayList(OutlinePoint) = .empty;
            defer child_points.deinit(gpa);
            const comp_verts = try glyphShapeTTInner(tt, gpa, gidx, &child_points, depth + 1);
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
                v.x = @intFromFloat(end.x);
                v.y = @intFromFloat(end.y);
                v.cx = @intFromFloat(control.x);
                v.cy = @intFromFloat(control.y);
            }
            try vertices.appendSlice(gpa, comp_verts);
            for (child_points.items) |point| try parent_points.append(gpa, point.transform(mtx));
            more = (flags & (1 << 5)) != 0;
        }
        if (outline_points) |out| try out.appendSlice(gpa, parent_points.items);
    }
    return vertices.toOwnedSlice(gpa);
}

fn glyfOffset(tt: *const TrueType, glyph: GlyphIndex) ?u32 {
    const bytes = tt.ttf_bytes;
    const glyph_index: usize = @backingInt(glyph);

    assert(glyph_index < tt.glyphs_len);
    assert(tt.index_to_loc_format < 2);

    const glyf = tt.table_offsets[@backingInt(TableId.glyf)];
    const loca = tt.table_offsets[@backingInt(TableId.loca)];
    const g1, const g2 = if (tt.index_to_loc_format == 0) .{
        glyf + @as(u32, readInt(u16, bytes[loca + glyph_index * 2 ..][0..2], .big)) * 2,
        glyf + @as(u32, readInt(u16, bytes[loca + glyph_index * 2 + 2 ..][0..2], .big)) * 2,
    } else .{
        glyf + readInt(u32, bytes[loca + glyph_index * 4 ..][0..4], .big),
        glyf + readInt(u32, bytes[loca + glyph_index * 4 + 4 ..][0..4], .big),
    };
    if (g1 == g2) return null;
    return g1;
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
    const box = glyphBox(tt, glyph) orelse return .empty;
    return .{
        // move to integral bboxes (treating pixels as little squares, what pixels get touched)?
        .x0 = @intFromFloat(@floor(@as(f32, @floatFromInt(box.x0)) * scale_x + shift_x)),
        .y0 = @intFromFloat(@floor(@as(f32, @floatFromInt(-box.y1)) * scale_y + shift_y)),
        .x1 = @intFromFloat(@ceil(@as(f32, @floatFromInt(box.x1)) * scale_x + shift_x)),
        .y1 = @intFromFloat(@ceil(@as(f32, @floatFromInt(-box.y0)) * scale_y + shift_y)),
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

pub fn glyphBox(tt: *const TrueType, glyph: GlyphIndex) ?BitmapBox {
    return if (tt.cff_data.cff.size != 0)
        cff.glyphBox(&tt.cff_data, glyph)
    else
        tt.glyphBoxTT(glyph);
}

fn glyphBoxTT(tt: *const TrueType, glyph: GlyphIndex) ?BitmapBox {
    const bytes = tt.ttf_bytes;
    const g = glyfOffset(tt, glyph) orelse return null;
    return .{
        .x0 = readInt(i16, bytes[g + 2 ..][0..2], .big),
        .y0 = readInt(i16, bytes[g + 4 ..][0..2], .big),
        .x1 = readInt(i16, bytes[g + 6 ..][0..2], .big),
        .y1 = readInt(i16, bytes[g + 8 ..][0..2], .big),
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

fn readCursor(comptime I: type, bytes: []const u8, cursor: *u32) I {
    const start = cursor.*;
    const result = readInt(I, bytes[start..][0..@sizeOf(I)], .big);
    cursor.* = start + @sizeOf(I);
    return result;
}

fn coverageIndex(bytes: []const u8, coverage_table: u32, glyph: GlyphIndex) ?u32 {
    const coverage_format = readInt(u16, bytes[coverage_table..][0..2], .big);
    switch (coverage_format) {
        1 => {
            const glyph_count = readInt(u16, bytes[coverage_table + 2 ..][0..2], .big);

            // Binary search.
            var l: u32 = 0;
            var r: u32 = glyph_count - 1;
            const needle = @backingInt(glyph);
            while (l <= r) {
                const glyph_array = coverage_table + 4;
                const m = (l + r) >> 1;
                const glyph_id = readInt(u16, bytes[glyph_array + 2 * m ..][0..2], .big);
                const straw = glyph_id;
                if (needle < straw) {
                    if (m == 0) break;
                    r = m - 1;
                } else if (needle > straw) {
                    l = m + 1;
                } else {
                    return m;
                }
            }
        },
        2 => {
            const range_count = readInt(u16, bytes[coverage_table + 2 ..][0..2], .big);
            const range_array = coverage_table + 4;

            // Binary search.
            var l: u32 = 0;
            var r: u32 = range_count - 1;
            const needle = @backingInt(glyph);
            while (l <= r) {
                const m = (l + r) >> 1;
                const range_record = range_array + 6 * m;
                const straw_start = readInt(u16, bytes[range_record..][0..2], .big);
                const straw_end = readInt(u16, bytes[range_record + 2 ..][0..2], .big);
                if (needle < straw_start) {
                    if (m == 0) break;
                    r = m - 1;
                } else if (needle > straw_end) {
                    l = m + 1;
                } else {
                    const start_coverage_index = readInt(u16, bytes[range_record + 4 ..][0..2], .big);
                    return start_coverage_index + needle - straw_start;
                }
            }
        },
        else => {},
    }
    return null;
}

fn glyphClass(bytes: []const u8, class_def_table: u32, glyph: GlyphIndex) u32 {
    const glyph_int = @backingInt(glyph);
    const class_def_format = readInt(u16, bytes[class_def_table..][0..2], .big);
    switch (class_def_format) {
        1 => {
            const start_glyph_id = readInt(u16, bytes[class_def_table + 2 ..][0..2], .big);
            const glyph_count = readInt(u16, bytes[class_def_table + 4 ..][0..2], .big);
            const class_def1_value_array = class_def_table + 6;

            if (glyph_int >= start_glyph_id and glyph_int < start_glyph_id + glyph_count)
                return readInt(u16, bytes[class_def1_value_array + 2 * (glyph_int - start_glyph_id) ..][0..2], .big);
        },
        2 => {
            const class_range_count = readInt(u16, bytes[class_def_table + 2 ..][0..2], .big);
            const class_range_records = class_def_table + 4;

            if (class_range_count == 0)
                return 0;

            // Binary search.
            var l: u32 = 0;
            var r: u32 = class_range_count - 1;
            while (l <= r) {
                const m = (l + r) >> 1;
                const class_range_record = class_range_records + 6 * m;
                const straw_start = readInt(u16, bytes[class_range_record..][0..2], .big);
                const straw_end = readInt(u16, bytes[class_range_record + 2 ..][0..2], .big);
                if (glyph_int < straw_start) {
                    if (m == 0) break;
                    r = m - 1;
                } else if (glyph_int > straw_end) {
                    l = m + 1;
                } else {
                    return readInt(u16, bytes[class_range_record + 4 ..][0..2], .big);
                }
            }
        },
        else => return std.math.maxInt(u32), // Unsupported definition type, return an error.
    }

    // "All glyphs not assigned to a class fall into class 0". (OpenType spec)
    return 0;
}
