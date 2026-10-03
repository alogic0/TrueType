const std = @import("std");
const TrueType = @import("TrueType");
const expectEqual = std.testing.expectEqual;

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn font(bytes: []const u8) TrueType {
    var result: TrueType = .{
        .table_offsets = @splat(0),
        .ttf_bytes = bytes,
        .index_map = 0,
        .index_to_loc_format = 0,
        .glyphs_len = 65536,
        .cff_data = .empty,
    };
    result.table_lengths[@backingInt(TrueType.TableId.cmap)] = @intCast(bytes.len);
    return result;
}

fn mapped(tt: TrueType, cp: u21) u16 {
    return @backingInt(tt.codepointGlyphIndex(cp));
}

test "cmap format 2 single and double byte subheaders" {
    var bytes: [544]u8 = @splat(0);
    put(u16, &bytes, 0, 2);
    put(u16, &bytes, 2, bytes.len);
    put(u16, &bytes, 6 + 0x81 * 2, 8);
    put(u16, &bytes, 6 + 0x82 * 2, 8); // shared subheader
    for ([_]u16{ 0x41, 2, 0xffff, 10, 0x40, 3, 3, 6, 2, 0, 7, 0, 0xffff }, 0..) |word, i|
        put(u16, &bytes, 518 + i * 2, word);
    const tt = font(&bytes);
    try expectEqual(1, mapped(tt, 0x41));
    try expectEqual(0, mapped(tt, 0x42)); // missing glyph must not receive idDelta
    try expectEqual(0, mapped(tt, 0x40));
    try expectEqual(0, mapped(tt, 0x43));
    try expectEqual(0, mapped(tt, 0x81)); // lead byte is not a single-byte character
    try expectEqual(10, mapped(tt, 0x8140));
    try expectEqual(10, mapped(tt, 0x8240));
    try expectEqual(0, mapped(tt, 0x8141));
    try expectEqual(2, mapped(tt, 0x8142)); // modulo-65536 delta
    try expectEqual(0, mapped(tt, 0x8143));
    try expectEqual(0, mapped(tt, 0x8041)); // unsupported lead cannot use subheader 0
    try expectEqual(0, mapped(tt, 0x10000));
}

test "cmap format 8 UTF-16 groups and is32 bits" {
    var bytes: [8232]u8 = @splat(0);
    put(u16, &bytes, 0, 8);
    put(u32, &bytes, 4, bytes.len);
    bytes[12 + 0xd83d / 8] = 1 << (7 - 0xd83d % 8);
    put(u32, &bytes, 8204, 2);
    for ([_]u32{ 0x41, 0x41, 3, 0xd83dde00, 0xd83dde02, 40 }, 0..) |word, i|
        put(u32, &bytes, 8208 + 4 * i, word);
    const tt = font(&bytes);
    try expectEqual(3, mapped(tt, 0x41));
    try expectEqual(0, mapped(tt, 0x42));
    try expectEqual(40, mapped(tt, 0x1f600));
    try expectEqual(42, mapped(tt, 0x1f602));
    try expectEqual(0, mapped(tt, 0x1f603));
    try expectEqual(0, mapped(tt, 0xd83d));
    bytes[12 + 0xd83d / 8] = 0;
    try expectEqual(0, mapped(tt, 0x1f600));
    bytes[12 + 0x41 / 8] = 1 << (7 - 0x41 % 8);
    try expectEqual(0, mapped(tt, 0x41));
}

test "cmap format 10 supplementary trimmed array" {
    var bytes: [26]u8 = @splat(0);
    put(u16, &bytes, 0, 10);
    put(u32, &bytes, 4, bytes.len);
    put(u32, &bytes, 12, 0x10000);
    put(u32, &bytes, 16, 3);
    put(u16, &bytes, 20, 7);
    put(u16, &bytes, 22, 0);
    put(u16, &bytes, 24, 0xffff);
    const tt = font(&bytes);
    try expectEqual(0, mapped(tt, 0xffff));
    try expectEqual(7, mapped(tt, 0x10000));
    try expectEqual(0, mapped(tt, 0x10001));
    try expectEqual(0xffff, mapped(tt, 0x10002));
    try expectEqual(0, mapped(tt, 0x10003));
    put(u32, &bytes, 16, 0);
    try expectEqual(0, mapped(tt, 0x10000));
}

test "cmap format 4 array entries apply delta except to missing glyphs" {
    var bytes: [36]u8 = @splat(0);
    const words = [_]u16{
        4, 36, 0, 4, 4, 1, 0, // header: two segments
        0x42, 0xffff, 0, // endCode and reservedPad
        0x41, 0xffff, // startCode
        0xffff, 1, // idDelta
        4, 0, // idRangeOffset
        2, 0, // glyphIdArray
    };
    for (words, 0..) |word, i| put(u16, &bytes, 2 * i, word);
    const tt = font(&bytes);
    try expectEqual(1, mapped(tt, 0x41));
    try expectEqual(0, mapped(tt, 0x42));
    try expectEqual(0, mapped(tt, 0xffff));
}

test "cmap format 14 default and explicit variation sequences" {
    var bytes: [79]u8 = @splat(0);
    for ([_]u16{ 6, 16, 0, 0x41, 3, 3, 4, 5 }, 0..) |word, i| put(u16, &bytes, 2 * i, word);
    const uv = bytes[16..];
    put(u16, uv, 0, 14);
    put(u32, uv, 2, 63);
    put(u32, uv, 6, 2);
    // u24 occupies three encoded bytes, even though @sizeOf(u24) is four.
    std.mem.writeInt(u24, uv[10..13], 0xfe0f, .big);
    put(u32, uv, 13, 32);
    put(u32, uv, 17, 40);
    std.mem.writeInt(u24, uv[21..24], 0xe0100, .big);
    put(u32, uv, 24, 0);
    put(u32, uv, 28, 54);
    put(u32, uv, 32, 1);
    std.mem.writeInt(u24, uv[36..39], 0x41, .big);
    uv[39] = 1; // A..B use the base map
    put(u32, uv, 40, 2);
    std.mem.writeInt(u24, uv[44..47], 0x43, .big);
    put(u16, uv, 47, 77);
    std.mem.writeInt(u24, uv[49..52], 0x1f600, .big);
    put(u16, uv, 52, 88);
    put(u32, uv, 54, 1);
    std.mem.writeInt(u24, uv[58..61], 0x4e00, .big);
    put(u16, uv, 61, 99);
    var tt = font(&bytes);
    tt.variation_map = 16;
    try expectEqual(3, @backingInt(tt.codepointVariationGlyphIndex(0x41, 0xfe0f).?));
    try expectEqual(4, @backingInt(tt.codepointVariationGlyphIndex(0x42, 0xfe0f).?));
    try expectEqual(77, @backingInt(tt.codepointVariationGlyphIndex(0x43, 0xfe0f).?));
    try expectEqual(88, @backingInt(tt.codepointVariationGlyphIndex(0x1f600, 0xfe0f).?));
    try expectEqual(99, @backingInt(tt.codepointVariationGlyphIndex(0x4e00, 0xe0100).?));
    try expectEqual(null, tt.codepointVariationGlyphIndex(0x44, 0xfe0f));
    try expectEqual(null, tt.codepointVariationGlyphIndex(0x41, 0xfe0e));
    try expectEqual(5, mapped(tt, 0x43));
    tt.variation_map = 0;
    try expectEqual(null, tt.codepointVariationGlyphIndex(0x41, 0xfe0f));
}

test "cmap selection includes record zero and separates variations" {
    const original = @embedFile("StandardSymbolsPS.otf");
    const base = try TrueType.load(original);
    const offset = base.table_offsets[@backingInt(TrueType.TableId.cmap)];
    const bytes = try std.testing.allocator.alloc(u8, original.len + 10);
    defer std.testing.allocator.free(bytes);
    @memcpy(bytes[0..original.len], original);
    @memset(bytes[original.len..], 0);
    put(u16, bytes, offset + 2, 1);
    put(u16, bytes, offset + 4, 0); // Unicode, BMP
    put(u16, bytes, offset + 6, 3);
    put(u32, bytes, offset + 8, base.index_map - offset);
    const single = try TrueType.load(bytes);
    try expectEqual(base.index_map, single.index_map);
    put(u16, bytes, offset + 2, 0);
    try std.testing.expectError(error.IndexMapMissing, TrueType.load(bytes));
    put(u16, bytes, offset + 2, 2);
    put(u16, bytes, offset + 12, 0);
    put(u16, bytes, offset + 14, 5);
    put(u32, bytes, offset + 16, @intCast(original.len - offset));
    put(u16, bytes, original.len, 14);
    put(u32, bytes, original.len + 2, 10);
    const table_count = std.mem.readInt(u16, bytes[4..6], .big);
    for (0..table_count) |i| {
        const record = 12 + i * 16;
        if (std.mem.eql(u8, bytes[record..][0..4], "cmap"))
            put(u32, bytes, record + 12, @intCast(bytes.len - offset));
    }
    const with_variations = try TrueType.load(bytes);
    try expectEqual(base.index_map, with_variations.index_map);
    try expectEqual(original.len, with_variations.variation_map);
    try expectEqual(null, with_variations.codepointVariationGlyphIndex(0x41, 0xfe0f));
}

test "cmap checked queries reject truncated arrays and out of range glyph IDs" {
    var bytes: [28]u8 = @splat(0);
    put(u16, &bytes, 0, 12);
    put(u32, &bytes, 4, bytes.len);
    put(u32, &bytes, 12, 1);
    put(u32, &bytes, 16, 0x41);
    put(u32, &bytes, 20, 0x41);
    put(u32, &bytes, 24, 3);
    for (0..bytes.len) |length| {
        const tt = font(bytes[0..length]);
        try std.testing.expectError(error.EndOfStream, tt.codepointGlyphIndexChecked(0x41));
        try expectEqual(0, mapped(tt, 0x41));
    }
    var tt = font(&bytes);
    try expectEqual(3, @backingInt(try tt.codepointGlyphIndexChecked(0x41)));
    put(u32, &bytes, 12, 0xffffffff);
    try std.testing.expectError(error.EndOfStream, tt.codepointGlyphIndexChecked(0x41));
    put(u32, &bytes, 12, 1);
    tt.glyphs_len = 3;
    try std.testing.expectError(error.InvalidFontData, tt.codepointGlyphIndexChecked(0x41));
}

test "cmap format 4 ignores search hints and stays in its declared subtable" {
    var bytes: [38]u8 = @splat(0);
    for ([_]u16{ 4, 36, 0, 4, 0xffff, 0xffff, 0xffff, 0x42, 0xffff, 0, 0x41, 0xffff, 0, 1, 4, 0, 2, 0 }, 0..) |word, i|
        put(u16, &bytes, 2 * i, word);
    const tt = font(&bytes);
    try expectEqual(2, mapped(tt, 0x41));
    put(u16, &bytes, 28, 8); // points to padding after this subtable
    try std.testing.expectError(error.EndOfStream, tt.codepointGlyphIndexChecked(0x41));
    put(u16, &bytes, 28, 0xfffe);
    try std.testing.expectError(error.EndOfStream, tt.codepointGlyphIndexChecked(0x41));
}

test "cmap variation queries bound nested counts and offsets" {
    var bytes: [64]u8 = @splat(0);
    for ([_]u16{ 6, 12, 0, 0x41, 1, 3 }, 0..) |word, i| put(u16, &bytes, 2 * i, word);
    const uv = bytes[12..];
    put(u16, uv, 0, 14);
    put(u32, uv, 2, 21);
    put(u32, uv, 6, 1);
    std.mem.writeInt(u24, uv[10..13], 0xfe0f, .big);
    put(u32, uv, 17, 21); // next record is outside the declared format 14 span
    var tt = font(&bytes);
    tt.variation_map = 12;
    try std.testing.expectError(error.EndOfStream, tt.codepointVariationGlyphIndexChecked(0x41, 0xfe0f));
    try expectEqual(null, tt.codepointVariationGlyphIndex(0x41, 0xfe0f));
    put(u32, uv, 17, 0);
    put(u32, uv, 6, 0xffffffff);
    try std.testing.expectError(error.EndOfStream, tt.codepointVariationGlyphIndexChecked(0x41, 0xfe0f));
}

test "cmap format 6 trimmed array preserves missing glyphs and boundaries" {
    var bytes: [16]u8 = @splat(0);
    put(u16, &bytes, 0, 6);
    put(u16, &bytes, 2, bytes.len);
    put(u16, &bytes, 6, 0x40);
    put(u16, &bytes, 8, 3);
    put(u16, &bytes, 10, 10);
    put(u16, &bytes, 14, 12);
    const tt = font(&bytes);
    for ([_]u21{ 0x3f, 0x40, 0x41, 0x42, 0x43 }, [_]u16{ 0, 10, 0, 12, 0 }) |cp, glyph|
        try expectEqual(glyph, mapped(tt, cp));
}

test "cmap formats 12 and 13 distinguish sequential and constant groups" {
    for ([_]u16{ 12, 13 }) |format| {
        var bytes: [40]u8 = @splat(0);
        put(u16, &bytes, 0, format);
        put(u32, &bytes, 4, bytes.len);
        put(u32, &bytes, 12, 2);
        for ([_]u32{ 0x10000, 0x10002, 40, 0x10fffd, 0x10ffff, 65533 }, 0..) |word, i|
            put(u32, &bytes, 16 + 4 * i, word);
        const tt = font(&bytes);
        try expectEqual(0, mapped(tt, 0xffff));
        try expectEqual(40, mapped(tt, 0x10000));
        try expectEqual(@as(u16, if (format == 12) 42 else 40), mapped(tt, 0x10002));
        try expectEqual(0, mapped(tt, 0x10003));
        try expectEqual(@as(u16, if (format == 12) 65535 else 65533), mapped(tt, 0x10ffff));
    }
}
