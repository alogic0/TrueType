//! Bounded horizontal and vertical metrics in unscaled font units.
const Reader = @import("reader.zig");

pub const Vertical = struct {
    ascent: i16,
    descent: i16,
    line_gap: i16,
};

pub const Horizontal = struct {
    /// Unsigned advance in font units, as encoded by OpenType hmtx.
    advance_width: u16,
    left_side_bearing: i16,
};

pub fn vertical(hhea: Reader) Reader.Error!Vertical {
    const result: Vertical = .{
        .ascent = try hhea.read(i16, 4),
        .descent = try hhea.read(i16, 6),
        .line_gap = try hhea.read(i16, 8),
    };
    if (result.ascent <= result.descent) return error.InvalidFontData;
    return result;
}

pub fn horizontal(hhea: Reader, hmtx: Reader, glyph: usize, glyph_count: u32) Reader.Error!Horizontal {
    if (glyph >= glyph_count) return error.InvalidFontData;
    const count: usize = try hhea.read(u16, 34);
    if (count == 0 or count > glyph_count) return error.InvalidFontData;
    return .{
        .advance_width = try hmtx.read(u16, 4 * @min(glyph, count - 1)),
        .left_side_bearing = try hmtx.read(i16, if (glyph < count) 4 * glyph + 2 else 4 * count + 2 * (glyph - count)),
    };
}
