const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const TrueType = @import("TrueType");
const ttf_data = @embedFile("GoNotoCurrent-Regular.ttf");
const c = @import("c");

test "glyph index lookup" {
    const ttf = try TrueType.load(ttf_data);
    const max_codepoint = 0x10FFFF;

    var stb_font: c.stbtt_fontinfo = undefined;
    try expect(c.stbtt_InitFont(&stb_font, ttf_data, 0) != 0);

    try expectEqualInts(stb_font.loca, ttf.table_offsets[@intFromEnum(TrueType.TableId.loca)]);
    try expectEqualInts(stb_font.head, ttf.table_offsets[@intFromEnum(TrueType.TableId.head)]);
    try expectEqualInts(stb_font.glyf, ttf.table_offsets[@intFromEnum(TrueType.TableId.glyf)]);
    try expectEqualInts(stb_font.hhea, ttf.table_offsets[@intFromEnum(TrueType.TableId.hhea)]);
    try expectEqualInts(stb_font.hmtx, ttf.table_offsets[@intFromEnum(TrueType.TableId.hmtx)]);
    try expectEqualInts(stb_font.kern, ttf.table_offsets[@intFromEnum(TrueType.TableId.kern)]);
    try expectEqualInts(stb_font.gpos, ttf.table_offsets[@intFromEnum(TrueType.TableId.GPOS)]);

    try expectEqualInts(stb_font.numGlyphs, ttf.glyphs_len);
    try expectEqualInts(stb_font.indexToLocFormat, ttf.index_to_loc_format);
    try expectEqualInts(stb_font.index_map, ttf.index_map);

    for (0..max_codepoint) |codepoint| {
        const zig_answer = if (ttf.codepointGlyphIndex(@intCast(codepoint))) |x| @intFromEnum(x) else 0;
        const stb_answer = c.stbtt_FindGlyphIndex(&stb_font, @intCast(codepoint));
        try expectEqualInts(stb_answer, zig_answer);
    }
}

fn expectEqualInts(expected: anytype, actual: anytype) anyerror!void {
    const actual_casted = std.math.cast(@TypeOf(expected), actual) orelse {
        std.debug.print("expected {any}, found {any}\n", .{ expected, actual });
        return error.TestFailed;
    };
    try std.testing.expectEqual(expected, actual_casted);
}
