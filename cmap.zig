//! OpenType character maps. Format 8 keys encode UTF-16 pairs; format 14
//! supplements the base map with Unicode variation sequences.
//! https://learn.microsoft.com/en-us/typography/opentype/spec/cmap
const std = @import("std");
const readInt = std.mem.readInt;
const GlyphIndex = @import("glyph.zig").GlyphIndex;

pub fn glyphIndex(bytes: []const u8, index_map: u32, codepoint: u21) GlyphIndex {
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return .notdef;
    const format = readInt(u16, bytes[index_map..][0..2], .big);
    switch (format) {
        0 => {
            const n = readInt(u16, bytes[index_map + 2 ..][0..2], .big);
            if (codepoint < n - 6)
                return @fromBackingInt(@intCast(bytes[index_map + 6 + codepoint]));

            return .notdef;
        },
        2 => {
            if (codepoint > 0xffff) return .notdef;
            const high = codepoint >> 8;
            const low = codepoint & 0xff;
            const key_byte = if (high == 0) low else high;
            const key = readInt(u16, bytes[index_map + 6 + 2 * key_byte ..][0..2], .big);
            if ((high == 0 and key != 0) or (high != 0 and key == 0)) return .notdef;
            const subheader = index_map + 518 + key;
            const first = readInt(u16, bytes[subheader..][0..2], .big);
            const count = readInt(u16, bytes[subheader + 2 ..][0..2], .big);
            if (low < first or low - first >= count) return .notdef;
            const delta = readInt(u16, bytes[subheader + 4 ..][0..2], .big);
            const range_offset = readInt(u16, bytes[subheader + 6 ..][0..2], .big);
            const value = readInt(u16, bytes[subheader + 6 + range_offset + 2 * (low - first) ..][0..2], .big);
            return @fromBackingInt(if (value == 0) 0 else value +% delta);
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

            const value = readInt(u16, bytes[offset + (codepoint - start) * 2 + index_map + 14 + seg_count * 6 + 2 + 2 * item ..][0..2], .big);
            const delta = readInt(u16, bytes[index_map + 14 + seg_count * 4 + 2 + 2 * item ..][0..2], .big);
            return @fromBackingInt(if (value == 0) 0 else value +% delta);
        },
        6 => {
            const first = readInt(u16, bytes[index_map + 6 ..][0..2], .big);
            const count = readInt(u16, bytes[index_map + 8 ..][0..2], .big);
            if (codepoint >= first and codepoint - first < count)
                return @fromBackingInt(@intCast(readInt(u16, bytes[index_map + 10 + (codepoint - first) * 2 ..][0..2], .big)));

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
            const is32 = bytes[index_map + 12 + word / 8] & (@as(u8, 1) << @intCast(7 - word % 8)) != 0;
            if (is32 != (codepoint > 0xffff)) return .notdef;
            return groupGlyphIndex(bytes, index_map + 8204, encoded, false);
        },
        10 => {
            const first = readInt(u32, bytes[index_map + 12 ..][0..4], .big);
            const count = readInt(u32, bytes[index_map + 16 ..][0..4], .big);
            if (codepoint < first or codepoint - first >= count) return .notdef;
            return @fromBackingInt(readInt(u16, bytes[index_map + 20 + 2 * (codepoint - first) ..][0..2], .big));
        },
        12, 13 => return groupGlyphIndex(bytes, index_map + 12, codepoint, format == 13),
        // Format 14 maps sequences, not individual codepoints.
        else => return .notdef,
    }
}

fn groupGlyphIndex(bytes: []const u8, count_offset: u32, code: u32, constant: bool) GlyphIndex {
    var low: u32 = 0;
    var high = readInt(u32, bytes[count_offset..][0..4], .big);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const off = count_offset + 4 + mid * 12;
        const first = readInt(u32, bytes[off..][0..4], .big);
        const last = readInt(u32, bytes[off + 4 ..][0..4], .big);
        if (code < first) {
            high = mid;
        } else if (code > last) {
            low = mid + 1;
        } else {
            const base = readInt(u32, bytes[off + 8 ..][0..4], .big);
            const index = @as(u64, base) + (if (constant) @as(u32, 0) else code - first);
            return @fromBackingInt(std.math.cast(u16, index) orelse return .notdef);
        }
    }
    return .notdef;
}

pub fn variationGlyphIndex(bytes: []const u8, table: u32, codepoint: u21, selector: u21, default: GlyphIndex) ?GlyphIndex {
    if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return null;
    var low: u32 = 0;
    var high = readInt(u32, bytes[table + 6 ..][0..4], .big);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = table + 10 + 11 * mid;
        const candidate = readInt(u24, bytes[record..][0..3], .big);
        if (selector < candidate) {
            high = mid;
        } else if (selector > candidate) {
            low = mid + 1;
        } else {
            const explicit_offset = readInt(u32, bytes[record + 7 ..][0..4], .big);
            if (explicit_offset != 0) {
                const mapping = table + explicit_offset;
                var l: u32 = 0;
                var r = readInt(u32, bytes[mapping..][0..4], .big);
                while (l < r) {
                    const m = l + (r - l) / 2;
                    const entry = mapping + 4 + 5 * m;
                    const cp = readInt(u24, bytes[entry..][0..3], .big);
                    if (codepoint < cp) {
                        r = m;
                    } else if (codepoint > cp) {
                        l = m + 1;
                    } else {
                        return @fromBackingInt(readInt(u16, bytes[entry + 3 ..][0..2], .big));
                    }
                }
            }
            const default_offset = readInt(u32, bytes[record + 3 ..][0..4], .big);
            if (default_offset != 0) {
                const ranges = table + default_offset;
                var l: u32 = 0;
                var r = readInt(u32, bytes[ranges..][0..4], .big);
                while (l < r) {
                    const m = l + (r - l) / 2;
                    const entry = ranges + 4 + 4 * m;
                    const first = readInt(u24, bytes[entry..][0..3], .big);
                    if (codepoint < first) {
                        r = m;
                    } else if (codepoint - first > bytes[entry + 3]) {
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
