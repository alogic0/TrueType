//! Checked scalar horizontal kerning. Positioning beyond xAdvance belongs to
//! a glyph-run API; unsupported lookup kinds are skipped.
const Reader = @import("reader.zig");
const GlyphIndex = @import("glyph.zig").GlyphIndex;
pub const Error = Reader.Error;

fn nonzeroTail(source: Reader, offset: usize) Error!Reader {
    if (offset == 0) return error.InvalidFontData;
    return source.tail(offset);
}

pub fn gpos(source: Reader, a: GlyphIndex, b: GlyphIndex) Error!i16 {
    if (try source.read(u16, 0) != 1 or try source.read(u16, 2) != 0) return 0;
    const list = try nonzeroTail(source, try source.read(u16, 8));
    const count = try list.read(u16, 0);
    _ = try list.records(2, count, 2);
    for (0..count) |i| {
        const lookup = try nonzeroTail(list, try list.read(u16, 2 + 2 * i));
        const kind = try lookup.read(u16, 0);
        const flags = try lookup.read(u16, 2);
        const n = try lookup.read(u16, 4);
        _ = try lookup.records(6, n, 2);
        if (flags & 0x10 != 0) _ = try lookup.read(u16, 6 + @as(usize, n) * 2);
        if (kind != 2 and kind != 9) continue;
        for (0..n) |j| {
            var table = try nonzeroTail(lookup, try lookup.read(u16, 6 + 2 * j));
            if (kind == 9) {
                if (try table.read(u16, 0) != 1 or try table.read(u16, 2) != 2) continue;
                table = try nonzeroTail(table, try table.read(u32, 4));
            }
            const format = try table.read(u16, 0);
            if (format != 1 and format != 2) continue;
            const coverage = try nonzeroTail(table, try table.read(u16, 2));
            const index = try coverageIndex(coverage, a) orelse continue;
            const value1 = try table.read(u16, 4);
            const value2 = try table.read(u16, 6);
            if ((value1 | value2) & 0xff00 != 0) return 0;
            const pair_size: usize = 2 * (@as(usize, @popCount(value1)) + @as(usize, @popCount(value2)));
            if (format == 1) {
                const sets = try table.read(u16, 8);
                _ = try table.records(10, sets, 2);
                if (index >= sets) return error.InvalidFontData;
                const pairs = try nonzeroTail(table, try table.read(u16, 10 + 2 * @as(usize, index)));
                var high: usize = try pairs.read(u16, 0);
                const stride = pair_size + 2;
                _ = try pairs.records(2, high, stride);
                var low: usize = 0;
                while (low < high) {
                    const mid = low + (high - low) / 2;
                    const at = 2 + stride * mid;
                    const second = try pairs.read(u16, at);
                    if (@backingInt(b) < second) high = mid else if (@backingInt(b) > second) low = mid + 1 else return xAdvance(pairs, at + 2, value1);
                }
            } else {
                const class1 = try glyphClass(try nonzeroTail(table, try table.read(u16, 8)), a) orelse continue;
                const class2 = try glyphClass(try nonzeroTail(table, try table.read(u16, 10)), b) orelse continue;
                const count1: usize = try table.read(u16, 12);
                const count2: usize = try table.read(u16, 14);
                if (class1 >= count1 or class2 >= count2) return error.InvalidFontData;
                // Check rows first to avoid overflowing class-count products.
                if (pair_size == 0) return 0;
                const row_size = count2 * pair_size; // count2 is u16, pair_size <= 32
                _ = try table.records(16, count1, row_size);
                return xAdvance(table, 16 + @as(usize, class1) * row_size + @as(usize, class2) * pair_size, value1);
            }
        }
    }
    return 0;
}

fn xAdvance(source: Reader, offset: usize, format: u16) Error!i16 {
    if (format & 4 == 0) return 0;
    return source.read(i16, offset + 2 * @as(usize, @popCount(format & 3)));
}

pub fn kern(source: Reader, a: GlyphIndex, b: GlyphIndex) Error!i16 {
    if (try source.read(u16, 0) != 0 or try source.read(u16, 2) == 0) return 0;
    // Preserve the existing first-subtable, horizontal-format-0 policy.
    const length = try source.read(u16, 6);
    const table: Reader = .{ .bytes = try source.span(4, length) };
    if (try table.read(u16, 0) != 0 or try table.read(u16, 4) != 1) return 0;
    var high: usize = try table.read(u16, 6);
    _ = try table.records(14, high, 6);
    var low: usize = 0;
    const needle = @as(u32, @backingInt(a)) << 16 | @backingInt(b);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const at = 14 + mid * 6;
        const pair = try table.read(u32, at);
        if (needle < pair) high = mid else if (needle > pair) low = mid + 1 else return table.read(i16, at + 4);
    }
    return 0;
}

fn coverageIndex(source: Reader, glyph: GlyphIndex) Error!?u32 {
    const format = try source.read(u16, 0);
    var high: usize = try source.read(u16, 2);
    const stride: usize = switch (format) {
        1 => 2,
        2 => 6,
        else => return null,
    };
    _ = try source.records(4, high, stride);
    var low: usize = 0;
    const needle = @backingInt(glyph);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const at = 4 + stride * mid;
        const first = try source.read(u16, at);
        const last = if (format == 1) first else try source.read(u16, at + 2);
        if (last < first) return error.InvalidFontData;
        if (needle < first) high = mid else if (needle > last) low = mid + 1 else {
            return if (format == 1) @intCast(mid) else @as(u32, try source.read(u16, at + 4)) + needle - first;
        }
    }
    return null;
}

fn glyphClass(source: Reader, glyph: GlyphIndex) Error!?u16 {
    const format = try source.read(u16, 0);
    const needle = @backingInt(glyph);
    if (format == 1) {
        const first = try source.read(u16, 2);
        const count = try source.read(u16, 4);
        _ = try source.records(6, count, 2);
        if (@as(u32, first) + count > 65536) return error.InvalidFontData;
        if (needle < first or needle - first >= count) return 0;
        return try source.read(u16, 6 + 2 * @as(usize, needle - first));
    }
    if (format != 2) return null;
    var high: usize = try source.read(u16, 2);
    _ = try source.records(4, high, 6);
    var low: usize = 0;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const at = 4 + 6 * mid;
        const first = try source.read(u16, at);
        const last = try source.read(u16, at + 2);
        if (last < first) return error.InvalidFontData;
        if (needle < first) high = mid else if (needle > last) low = mid + 1 else return try source.read(u16, at + 4);
    }
    return 0;
}
