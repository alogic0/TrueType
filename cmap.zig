//! OpenType character maps. Format 8 keys encode UTF-16 pairs; format 14
//! supplements the base map with Unicode variation sequences.
//! https://learn.microsoft.com/en-us/typography/opentype/spec/cmap
const std = @import("std");
const Reader = @import("reader.zig");
pub const Error = Reader.Error;
const GlyphIndex = @import("glyph.zig").GlyphIndex;

pub fn glyphIndex(bytes: []const u8, map_offset: u32, codepoint: u21) Error!GlyphIndex {
    const source = try subtable(bytes, map_offset);
    const index_map: usize = 0;
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return .notdef;
    const format = try source.read(u16, index_map);
    switch (format) {
        0 => {
            if (codepoint < 256) return @fromBackingInt(try source.read(u8, 6 + codepoint));
            return .notdef;
        },
        2 => {
            if (codepoint > 0xffff) return .notdef;
            const high = codepoint >> 8;
            const low = codepoint & 0xff;
            const key_byte = if (high == 0) low else high;
            const key = try source.read(u16, index_map + 6 + 2 * key_byte);
            if ((high == 0 and key != 0) or (high != 0 and key == 0)) return .notdef;
            const subheader = index_map + 518 + key;
            const first = try source.read(u16, subheader);
            const count = try source.read(u16, subheader + 2);
            if (low < first or low - first >= count) return .notdef;
            const delta = try source.read(u16, subheader + 4);
            const range_offset = try source.read(u16, subheader + 6);
            const value = try source.read(u16, subheader + 6 + range_offset + 2 * (low - first));
            return @fromBackingInt(if (value == 0) 0 else value +% delta);
        },
        4 => {
            const seg_count: usize = (try source.read(u16, 6)) >> 1;
            _ = try source.records(16, seg_count, 8);
            if (codepoint > 0xffff) return .notdef;
            var low: usize = 0;
            var high = seg_count;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (codepoint > try source.read(u16, 14 + 2 * mid)) low = mid + 1 else high = mid;
            }
            if (low == seg_count) return .notdef;
            const item = low;
            const end_count: usize = 14;
            const start = try source.read(u16, index_map + 14 + seg_count * 2 + 2 + 2 * item);
            const last = try source.read(u16, end_count + 2 * item);
            if (codepoint < start or codepoint > last)
                return .notdef;

            const offset = try source.read(u16, index_map + 14 + seg_count * 6 + 2 + 2 * item);
            if (offset == 0) {
                const result = @as(i32, codepoint) + try source.read(i16, index_map + 14 + seg_count * 4 + 2 + 2 * item);
                // truncate to u16
                return @fromBackingInt(@intCast(@as(u16, @truncate(@as(u32, @bitCast(result))))));
            }

            const value = try source.read(u16, offset + (codepoint - start) * 2 + index_map + 14 + seg_count * 6 + 2 + 2 * item);
            const delta = try source.read(u16, index_map + 14 + seg_count * 4 + 2 + 2 * item);
            return @fromBackingInt(if (value == 0) 0 else value +% delta);
        },
        6 => {
            const first = try source.read(u16, index_map + 6);
            const count = try source.read(u16, index_map + 8);
            if (codepoint >= first and codepoint - first < count)
                return @fromBackingInt(@intCast(try source.read(u16, index_map + 10 + (codepoint - first) * 2)));

            return .notdef;
        },
        8 => {
            var encoded: u32 = codepoint;
            var word: u16 = @intCast(codepoint & 0xffff);
            if (codepoint > 0xffff) {
                const cp: u32 = codepoint - 0x10000;
                word = @intCast(0xd800 + (cp >> 10));
                encoded = @as(u32, word) << 16 | (0xdc00 + (cp & 0x3ff));
            }
            const is32 = (try source.read(u8, index_map + 12 + word / 8)) & (@as(u8, 1) << @intCast(7 - word % 8)) != 0;
            if (is32 != (codepoint > 0xffff)) return .notdef;
            return groupGlyphIndex(source, index_map + 8204, encoded, false);
        },
        10 => {
            const first = try source.read(u32, index_map + 12);
            const count = try source.read(u32, index_map + 16);
            if (codepoint < first or codepoint - first >= count) return .notdef;
            return @fromBackingInt(try source.read(u16, index_map + 20 + 2 * (codepoint - first)));
        },
        12, 13 => return groupGlyphIndex(source, index_map + 12, codepoint, format == 13),
        // Format 14 maps sequences, not individual codepoints.
        else => return .notdef,
    }
}

fn groupGlyphIndex(source: Reader, count_offset: usize, code: u32, constant: bool) Error!GlyphIndex {
    var low: usize = 0;
    var high: usize = try source.read(u32, count_offset);
    _ = try source.records(count_offset + 4, high, 12);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const off = count_offset + 4 + mid * 12;
        const first = try source.read(u32, off);
        const last = try source.read(u32, off + 4);
        if (code < first) {
            high = mid;
        } else if (code > last) {
            low = mid + 1;
        } else {
            const base = try source.read(u32, off + 8);
            const index = @as(u64, base) + (if (constant) @as(u32, 0) else code - first);
            return @fromBackingInt(std.math.cast(u16, index) orelse return error.InvalidFontData);
        }
    }
    return .notdef;
}

pub fn variationGlyphIndex(bytes: []const u8, offset: u32, codepoint: u21, selector: u21, default: GlyphIndex) Error!?GlyphIndex {
    const source = try subtable(bytes, offset);
    const table: usize = 0;
    if (try source.read(u16, 0) != 14) return error.InvalidFontData;
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return null;
    var low: usize = 0;
    var high: usize = try source.read(u32, table + 6);
    _ = try source.records(10, high, 11);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = table + 10 + 11 * mid;
        const candidate = try source.read(u24, record);
        if (selector < candidate) {
            high = mid;
        } else if (selector > candidate) {
            low = mid + 1;
        } else {
            const explicit_offset = try source.read(u32, record + 7);
            if (explicit_offset != 0) {
                const mapping = table + explicit_offset;
                var l: usize = 0;
                var r: usize = try source.read(u32, mapping);
                _ = try source.records(mapping + 4, r, 5);
                while (l < r) {
                    const m = l + (r - l) / 2;
                    const entry = mapping + 4 + 5 * m;
                    const cp = try source.read(u24, entry);
                    if (codepoint < cp) {
                        r = m;
                    } else if (codepoint > cp) {
                        l = m + 1;
                    } else {
                        return @fromBackingInt(try source.read(u16, entry + 3));
                    }
                }
            }
            const default_offset = try source.read(u32, record + 3);
            if (default_offset != 0) {
                const ranges = table + default_offset;
                var l: usize = 0;
                var r: usize = try source.read(u32, ranges);
                _ = try source.records(ranges + 4, r, 4);
                while (l < r) {
                    const m = l + (r - l) / 2;
                    const entry = ranges + 4 + 4 * m;
                    const first = try source.read(u24, entry);
                    if (codepoint < first) {
                        r = m;
                    } else if (codepoint - first > try source.read(u8, entry + 3)) {
                        l = m + 1;
                    } else {
                        return default;
                    }
                }
            }
            return null;
        }
    }
    return null;
}

pub fn subtable(bytes: []const u8, offset: u32) Error!Reader {
    const tail = try (Reader{ .bytes = bytes }).tail(offset);
    const format = try tail.read(u16, 0);
    const length: usize = switch (format) {
        0, 2, 4, 6 => try tail.read(u16, 2),
        8, 10, 12, 13 => try tail.read(u32, 4),
        14 => try tail.read(u32, 2),
        else => return error.InvalidFontData,
    };
    const minimum: usize = switch (format) {
        0 => 262,
        2 => 526,
        4 => 24,
        6 => 10,
        8 => 8208,
        10 => 20,
        12, 13 => 16,
        14 => 10,
        else => unreachable,
    };
    if (length < minimum) return error.InvalidFontData;
    return .{ .bytes = try tail.span(0, length) };
}

/// Validate searched structures once at load; queries also use checked reads.
pub fn validate(bytes: []const u8, offset: u32) Error!void {
    const source = try subtable(bytes, offset);
    switch (try source.read(u16, 0)) {
        0 => {},
        2 => {
            for (0..256) |i| {
                const key = try source.read(u16, 6 + 2 * i);
                if (key % 8 != 0) return error.InvalidFontData;
                const h: usize = 518 + @as(usize, key);
                const first = try source.read(u16, h);
                const count = try source.read(u16, h + 2);
                const relative = try source.read(u16, h + 6);
                if (first > 255 or count > 256 - first or relative % 2 != 0) return error.InvalidFontData;
                _ = try source.records(h + 6 + relative, count, 2);
            }
        },
        4 => {
            const twice = try source.read(u16, 6);
            if (twice == 0 or twice % 2 != 0) return error.InvalidFontData;
            const count: usize = twice / 2;
            _ = try source.records(16, count, 8);
            var previous: ?u16 = null;
            for (0..count) |i| {
                const last = try source.read(u16, 14 + 2 * i);
                const first = try source.read(u16, 16 + 2 * count + 2 * i);
                if (first > last) return error.InvalidFontData;
                if (previous) |end| if (first <= end) return error.InvalidFontData;
                previous = last;
                const word = 16 + 6 * count + 2 * i;
                const relative = try source.read(u16, word);
                if (relative != 0) {
                    if (relative % 2 != 0 or word + relative < 16 + 8 * count) return error.InvalidFontData;
                    _ = try source.records(word + relative, @as(usize, last) - first + 1, 2);
                }
            }
            if (previous.? != 0xffff) return error.InvalidFontData;
        },
        6 => {
            const first = try source.read(u16, 6);
            const count = try source.read(u16, 8);
            if (@as(u32, first) + count > 65536) return error.InvalidFontData;
            _ = try source.records(10, count, 2);
        },
        8, 12, 13 => |format| {
            const base: usize = if (format == 8) 8204 else 12;
            const count = try source.read(u32, base);
            _ = try source.records(base + 4, count, 12);
            var previous: ?u32 = null;
            for (0..count) |i| {
                const row = base + 4 + 12 * i;
                const first = try source.read(u32, row);
                const last = try source.read(u32, row + 4);
                if (last < first or (format != 8 and last > 0x10ffff)) return error.InvalidFontData;
                if (previous) |end| if (first <= end) return error.InvalidFontData;
                previous = last;
                const glyph = try source.read(u32, row + 8);
                const span: u64 = if (format == 13) 0 else last - first;
                if (@as(u64, glyph) + span > 65535) return error.InvalidFontData;
            }
        },
        10 => {
            const first = try source.read(u32, 12);
            const count = try source.read(u32, 16);
            if (first > 0x10ffff or count > 0x110000 - first) return error.InvalidFontData;
            _ = try source.records(20, count, 2);
        },
        14 => {
            const count = try source.read(u32, 6);
            _ = try source.records(10, count, 11);
            var previous: ?u24 = null;
            for (0..count) |i| {
                const row = 10 + 11 * i;
                const selector = try source.read(u24, row);
                if (selector > 0x10ffff) return error.InvalidFontData;
                if (previous) |last| if (selector <= last) return error.InvalidFontData;
                previous = selector;
                for (0..2) |kind| {
                    const relative = try source.read(u32, row + 3 + 4 * kind);
                    if (relative == 0) continue;
                    const mapping = try source.tail(relative);
                    const entries = try mapping.read(u32, 0);
                    const stride: usize = if (kind == 0) 4 else 5;
                    _ = try mapping.records(4, entries, stride);
                    var last_end: ?u32 = null;
                    for (0..entries) |j| {
                        const at = 4 + stride * j;
                        const first: u32 = try mapping.read(u24, at);
                        const last = first + @as(u32, if (kind == 0) try mapping.read(u8, at + 3) else 0);
                        if (last > 0x10ffff) return error.InvalidFontData;
                        if (last_end) |end| if (first <= end) return error.InvalidFontData;
                        last_end = last;
                    }
                }
            }
        },
        else => unreachable,
    }
}
