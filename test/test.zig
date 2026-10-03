const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

const TrueType = @import("TrueType");
const c = @import("c");

const max_codepoint = 0x10FFFF;

const test_data = blk: {
    const filenames: []const [:0]const u8 = &.{
        "GoNotoCurrent-Regular.ttf",
        "StandardSymbolsPS.otf",
    };
    var result: [filenames.len][2][:0]const u8 = undefined;
    for (0..filenames.len) |i| result[i] = .{ filenames[i], @embedFile(filenames[i]) };
    break :blk result;
};

fn testIndexLookup(ttf_data: []const u8) !void {
    const ttf = try TrueType.load(ttf_data);

    var stb_font: c.stbtt_fontinfo = undefined;
    try expect(c.stbtt_InitFont(&stb_font, ttf_data.ptr, 0) != 0);

    try expectEqualInts(stb_font.loca, ttf.table_offsets[@backingInt(TrueType.TableId.loca)]);
    try expectEqualInts(stb_font.head, ttf.table_offsets[@backingInt(TrueType.TableId.head)]);
    try expectEqualInts(stb_font.glyf, ttf.table_offsets[@backingInt(TrueType.TableId.glyf)]);
    try expectEqualInts(stb_font.hhea, ttf.table_offsets[@backingInt(TrueType.TableId.hhea)]);
    try expectEqualInts(stb_font.hmtx, ttf.table_offsets[@backingInt(TrueType.TableId.hmtx)]);
    try expectEqualInts(stb_font.kern, ttf.table_offsets[@backingInt(TrueType.TableId.kern)]);
    try expectEqualInts(stb_font.gpos, ttf.table_offsets[@backingInt(TrueType.TableId.GPOS)]);

    {
        var stb_ascent: c_int = undefined;
        var stb_descent: c_int = undefined;
        var stb_line_gap: c_int = undefined;
        c.stbtt_GetFontVMetrics(&stb_font, &stb_ascent, &stb_descent, &stb_line_gap);
        const vm = ttf.verticalMetrics();
        try expectEqualInts(stb_ascent, vm.ascent);
        try expectEqualInts(stb_descent, vm.descent);
        try expectEqualInts(stb_line_gap, vm.line_gap);
    }

    try expectEqualInts(stb_font.numGlyphs, ttf.glyphs_len);
    try expectEqualInts(stb_font.indexToLocFormat, ttf.index_to_loc_format);
    try expectEqualInts(stb_font.index_map, ttf.index_map);

    for (0..max_codepoint) |codepoint| {
        const zig_answer = @backingInt(ttf.codepointGlyphIndex(@intCast(codepoint)));
        const stb_answer = c.stbtt_FindGlyphIndex(&stb_font, @intCast(codepoint));
        try expectEqualInts(stb_answer, zig_answer);
    }
}

test "glyph index lookup" {
    for (test_data) |td| {
        const filename, const ttf_data = td;
        testIndexLookup(ttf_data) catch |e| {
            std.log.err("test failure from {s}\n", .{filename});
            return e;
        };
    }
}

fn testHMetrics(ttf_data: []const u8) !void {
    const ttf = try TrueType.load(ttf_data);
    var stb_font: c.stbtt_fontinfo = undefined;
    try expect(c.stbtt_InitFont(&stb_font, ttf_data.ptr, 0) != 0);
    try expectEqualInts(stb_font.numGlyphs, ttf.glyphs_len);

    for (0..ttf.glyphs_len) |glyph_index| {
        //std.debug.print("glyph_index={d}/{d}\n", .{ glyph_index, ttf.glyphs_len });
        const zig_answer = ttf.glyphHMetrics(@fromBackingInt(@intCast(glyph_index)));

        var stb_advance_width: c_int = undefined;
        var stb_left_side_bearing: c_int = undefined;
        c.stbtt_GetGlyphHMetrics(&stb_font, @intCast(glyph_index), &stb_advance_width, &stb_left_side_bearing);

        try expectEqual(stb_advance_width, zig_answer.advance_width);
        try expectEqual(stb_left_side_bearing, zig_answer.left_side_bearing);
    }
}

test "glyph h metrics" {
    for (test_data) |td| {
        const filename, const ttf_data = td;
        testHMetrics(ttf_data) catch |e| {
            std.log.err("test failure from {s}\n", .{filename});
            return e;
        };
    }
}

/// stb only reads advance-only GPOS records. The bundled Noto font also uses
/// xPlacement + xAdvance (ValueFormat 5). Compact those records in a separate
/// copy for the reference reader, preserving every pair's base X advance.
/// This leaves the original font under test untouched. Hand-written GPOS
/// fixtures below independently verify fields and record strides.
fn normalizeStbKerning(tt: *const TrueType, normalized: []u8) void {
    const bytes = tt.ttf_bytes;
    const gpos = tt.table_offsets[@backingInt(TrueType.TableId.GPOS)];
    if (gpos == 0) return;
    const lookup_list = gpos + readU16(bytes, gpos + 8);
    for (0..readU16(bytes, lookup_list)) |i| {
        const lookup = lookup_list + readU16(bytes, lookup_list + 2 + 2 * i);
        const kind = readU16(bytes, lookup);
        if (kind != 2 and kind != 9) continue;
        for (0..readU16(bytes, lookup + 4)) |j| {
            var table = lookup + readU16(bytes, lookup + 6 + 2 * j);
            if (kind == 9) {
                if (readU16(bytes, table) != 1 or readU16(bytes, table + 2) != 2) continue;
                table += std.mem.readInt(u32, bytes[table + 4 ..][0..4], .big);
            }
            if (readU16(bytes, table + 4) != 5 or readU16(bytes, table + 6) != 0) continue;
            switch (readU16(bytes, table)) {
                1 => {
                    for (0..readU16(bytes, table + 8)) |p| {
                        const pair_set = table + readU16(bytes, table + 10 + 2 * p);
                        for (0..readU16(bytes, pair_set)) |r| {
                            const source = pair_set + 2 + 6 * r;
                            const dest = pair_set + 2 + 4 * r;
                            @memcpy(normalized[dest..][0..2], bytes[source..][0..2]); // secondGlyph
                            @memcpy(normalized[dest + 2 ..][0..2], bytes[source + 4 ..][0..2]); // xAdvance
                        }
                    }
                },
                2 => {
                    const record_count = @as(usize, readU16(bytes, table + 12)) * readU16(bytes, table + 14);
                    for (0..record_count) |r| {
                        @memcpy(normalized[table + 16 + 2 * r ..][0..2], bytes[table + 16 + 4 * r + 2 ..][0..2]);
                    }
                },
                else => continue,
            }
            std.mem.writeInt(u16, normalized[table + 4 ..][0..2], 4, .big);
        }
    }
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn testKernAdvance(ttf_data: []const u8) !void {
    const ttf = try TrueType.load(ttf_data);
    const stb_data = try std.testing.allocator.dupe(u8, ttf_data);
    defer std.testing.allocator.free(stb_data);
    normalizeStbKerning(&ttf, stb_data);
    var stb_font: c.stbtt_fontinfo = undefined;
    try expect(c.stbtt_InitFont(&stb_font, stb_data.ptr, 0) != 0);
    try expectEqualInts(stb_font.numGlyphs, ttf.glyphs_len);

    // I tested this with every combination of pairs once and it fully passed,
    // but that takes 2 days to run so let's just test a sample instead.

    var rng_instance: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rng = rng_instance.random();

    for (0..500_000) |_| {
        const a = rng.uintLessThan(u32, ttf.glyphs_len);
        const b = rng.uintLessThan(u32, ttf.glyphs_len);
        //if (b == 0) std.debug.print("glyph_index={d}/{d}\n", .{ a * ttf.glyphs_len + b, ttf.glyphs_len * ttf.glyphs_len });
        const stb_answer = c.stbtt_GetGlyphKernAdvance(&stb_font, @intCast(a), @intCast(b));
        const zig_answer = ttf.glyphKernAdvance(@fromBackingInt(@intCast(a)), @fromBackingInt(@intCast(b)));
        if (stb_answer != zig_answer) std.debug.print("kerning pair: {d}, {d}\n", .{ a, b });
        try expectEqual(stb_answer, zig_answer);
    }
}

test "glyph kern advance" {
    for (test_data) |td| {
        const filename, const ttf_data = td;
        testKernAdvance(ttf_data) catch |e| {
            std.log.err("test failure from {s}\n", .{filename});
            return e;
        };
    }
}

const KernPair = struct { left: u16, right: u16, value: i16 };

/// Returns a font containing only a 'kern' table with a single horizontal
/// format 0 subtable. Neither test font has a 'kern' table (they use GPOS
/// or nothing), so this is how glyphKernAdvance's 'kern' path gets tested.
fn writeKernOnlyFont(w: *std.Io.Writer, pairs: []const KernPair) error{WriteFailed}!TrueType {
    const kern_offset = 4;
    // A table offset of 0 means "no table", so don't put it at the start.
    try w.splatByteAll(0, kern_offset);
    // 'kern' table header
    try w.writeInt(u16, 0, .big); // version
    try w.writeInt(u16, 1, .big); // nTables
    // subtable header
    try w.writeInt(u16, 0, .big); // version
    try w.writeInt(u16, @intCast(14 + 6 * pairs.len), .big); // length
    try w.writeInt(u16, 1, .big); // coverage: horizontal
    try w.writeInt(u16, @intCast(pairs.len), .big); // nPairs
    try w.writeInt(u16, 0, .big); // searchRange (unused)
    try w.writeInt(u16, 0, .big); // entrySelector (unused)
    try w.writeInt(u16, 0, .big); // rangeShift (unused)
    // pairs, sorted by (left, right)
    for (pairs) |pair| {
        try w.writeInt(u16, pair.left, .big);
        try w.writeInt(u16, pair.right, .big);
        try w.writeInt(i16, pair.value, .big);
    }

    var ttf: TrueType = .{
        .table_offsets = @splat(0),
        .ttf_bytes = w.buffered(),
        .index_map = 0,
        .index_to_loc_format = 0,
        .glyphs_len = 0,
        .cff_data = .empty,
    };
    ttf.table_offsets[@backingInt(TrueType.TableId.kern)] = kern_offset;
    return ttf;
}

fn kernAdvance(ttf: *const TrueType, left: u16, right: u16) i16 {
    return ttf.glyphKernAdvance(@fromBackingInt(@intCast(left)), @fromBackingInt(@intCast(right)));
}

test "kern table lookup" {
    {
        var ttf_buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&ttf_buf);
        const ttf = try writeKernOnlyFont(&w, &.{});
        try expectEqual(0, kernAdvance(&ttf, 5, 7));
    }

    {
        var ttf_buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&ttf_buf);
        const ttf = try writeKernOnlyFont(&w, &.{
            .{ .left = 5, .right = 7, .value = -3 },
            .{ .left = 9, .right = 2, .value = 4 },
            .{ .left = 9, .right = 300, .value = -10 },
        });
        try expectEqual(-3, kernAdvance(&ttf, 5, 7));
        try expectEqual(4, kernAdvance(&ttf, 9, 2));
        try expectEqual(-10, kernAdvance(&ttf, 9, 300));
        try expectEqual(0, kernAdvance(&ttf, 9, 3)); // between pairs
        try expectEqual(0, kernAdvance(&ttf, 0xffff, 0xffff)); // after the last pair
        try expectEqual(0, kernAdvance(&ttf, 0, 0)); // before the first pair
    }
}

/// A minimal GPOS table with one pair-positioning lookup. Offsets in `pair_words`
/// are relative to the PairPos subtable, including when wrapped in an extension.
fn writeGposOnlyFont(w: *std.Io.Writer, pair_words: []const u16, extension: bool) !TrueType {
    const header = [_]u16{
        0, 0, // keep the GPOS offset nonzero
        1, 0, 0, 0, 10, // GPOS 1.0; LookupList follows the header
        1, 4, // one lookup
        if (extension) 9 else 2, 0, 1, 8, // one subtable
    };
    for (header) |word| try w.writeInt(u16, word, .big);
    if (extension) {
        for ([_]u16{ 1, 2, 0, 8 }) |word| try w.writeInt(u16, word, .big);
    }
    for (pair_words) |word| try w.writeInt(u16, word, .big);
    var ttf: TrueType = .{
        .table_offsets = @splat(0),
        .ttf_bytes = w.buffered(),
        .index_map = 0,
        .index_to_loc_format = 0,
        .glyphs_len = 0,
        .cff_data = .empty,
    };
    ttf.table_offsets[@backingInt(TrueType.TableId.GPOS)] = 4;
    return ttf;
}

test "GPOS pair records with placement and second-glyph adjustments" {
    for ([_]bool{ false, true }) |extension| {
        var buffer: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const ttf = try writeGposOnlyFont(&w, &.{
            1, 12, 0x000f, 0x0005, 1, 18, // PairPos format 1
            1, 1, 5, // coverage: glyph 5
            3, // three sorted pairs; negative advances are encoded as int16
            7, 11, 12, 0xffec, 14, 21, 100, // -20
            9, 15, 16, 0xffe2, 18, 25, 200, // -30
            300, 19, 20, 40, 22, 29, 300, // +40
        }, extension);
        try expectEqual(-20, kernAdvance(&ttf, 5, 7));
        try expectEqual(-30, kernAdvance(&ttf, 5, 9));
        try expectEqual(40, kernAdvance(&ttf, 5, 300));
        try expectEqual(0, kernAdvance(&ttf, 5, 0));
        try expectEqual(0, kernAdvance(&ttf, 5, 8));
        try expectEqual(0, kernAdvance(&ttf, 5, 0xffff));
        try expectEqual(0, kernAdvance(&ttf, 6, 7));
    }
}

test "GPOS class records with variable size" {
    for ([_]bool{ false, true }) |extension| {
        var buffer: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const ttf = try writeGposOnlyFont(&w, &.{
            2, 40, 0x0006, 0x0001, 46, 54, 2, 2, // PairPos format 2
            // Each record contains yPlacement, xAdvance, second xPlacement.
            11, 0, 21, // class (0, 0)
            12, 0xfffd, 22, // class (0, 1): -3
            13, 0xfff9, 23, // class (1, 0): -7
            14, 0xffec, 24, // class (1, 1): -20
            1, 1, 5, // coverage: glyph 5
            1, 5, 1, 1, // class definition 1: glyph 5 -> class 1
            1, 7, 1, 1, // class definition 2: glyph 7 -> class 1
        }, extension);
        try expectEqual(-20, kernAdvance(&ttf, 5, 7));
        try expectEqual(-7, kernAdvance(&ttf, 5, 8));
        try expectEqual(0, kernAdvance(&ttf, 6, 7));
    }
}

test "GPOS optional value fields" {
    // Exercise every defined ValueFormat combination, including device offsets,
    // no X advance, and empty ValueRecords. Two pairs expose incorrect strides.
    for (0..256) |format| {
        var pair_buffer: [128]u8 = undefined;
        var pair_writer: std.Io.Writer = .fixed(&pair_buffer);
        const header = [_]u16{ 1, 12, @intCast(format), @intCast(format), 1, 18, 1, 1, 5, 2 };
        for (header) |word| try pair_writer.writeInt(u16, word, .big);
        for ([_]u16{ 7, 9 }) |second| {
            try pair_writer.writeInt(u16, second, .big);
            for ([_][8]i16{
                .{ 11, 12, -20, 14, 0, 0, 0, 0 },
                .{ 21, 22, 100, 24, 0, 0, 0, 0 },
            }) |values| {
                for (values, 0..) |value, bit| {
                    if (format & (@as(usize, 1) << @intCast(bit)) != 0)
                        try pair_writer.writeInt(i16, value, .big);
                }
            }
        }
        var words: [64]u16 = undefined;
        const word_count = pair_writer.buffered().len / 2;
        for (words[0..word_count], 0..) |*word, i|
            word.* = std.mem.readInt(u16, pair_writer.buffered()[i * 2 ..][0..2], .big);
        var buffer: [160]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const ttf = try writeGposOnlyFont(&w, words[0..word_count], false);
        const expected: i16 = if (format & 4 != 0) -20 else 0;
        try expectEqual(expected, kernAdvance(&ttf, 5, 7));
        try expectEqual(expected, kernAdvance(&ttf, 5, 9));
    }
}

test "GPOS empty pairs and unsupported formats" {
    for ([_]u16{ 1, 3 }) |pos_format| {
        var buffer: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const ttf = try writeGposOnlyFont(&w, &.{ pos_format, 12, 4, 0, 1, 18, 1, 1, 5, 0 }, false);
        try expectEqual(0, kernAdvance(&ttf, 5, 7));
    }
    {
        var buffer: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        const ttf = try writeGposOnlyFont(&w, &.{ 1, 12, 0xff04, 0, 1, 18, 1, 1, 5, 1, 7, 0xffec }, false);
        try expectEqual(0, kernAdvance(&ttf, 5, 7));
    }
}

fn testBitmapRendering(ttf_data: []const u8) !void {
    const gpa = std.testing.allocator;

    const ttf = try TrueType.load(ttf_data);
    var stb_font: c.stbtt_fontinfo = undefined;
    try expect(c.stbtt_InitFont(&stb_font, ttf_data.ptr, 0) != 0);
    try expectEqualInts(stb_font.numGlyphs, ttf.glyphs_len);

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);

    const scale = ttf.scaleForPixelHeight(32);
    try expectEqual(c.stbtt_ScaleForPixelHeight(&stb_font, 32), scale);

    for (0..ttf.glyphs_len) |glyph_index| {
        buffer.clearRetainingCapacity();

        //std.debug.print("glyph_index={d}/{d}\n", .{ glyph_index, ttf.glyphs_len });

        var stb_width: c_int = undefined;
        var stb_height: c_int = undefined;
        var stb_xoff: c_int = undefined;
        var stb_yoff: c_int = undefined;
        const stb_pixels = c.stbtt_GetGlyphBitmap(&stb_font, scale, scale, @intCast(glyph_index), &stb_width, &stb_height, &stb_xoff, &stb_yoff);
        defer c.stbtt_FreeBitmap(stb_pixels, null);

        const dims = ttf.glyphBitmap(gpa, &buffer, @fromBackingInt(@intCast(glyph_index)), scale, scale) catch |err| switch (err) {
            else => |e| return e,
        };

        try expectEqualInts(stb_width, dims.width);
        try expectEqualInts(stb_height, dims.height);
        try expectEqualInts(stb_xoff, dims.off_x);
        try expectEqualInts(stb_yoff, dims.off_y);
        try expectEqual(buffer.items.len, dims.width * dims.height);
        // stb sometimes returns null pixels given otf data
        if (stb_pixels) |pixels| {
            // 55 of the glyphs have some bytes off by exactly 1.
            try expectNearlyEqual(pixels[0..buffer.items.len], buffer.items);
        } else {
            try std.testing.expectEqual(0, buffer.items.len);
        }
    }
}

test "glyph bitmap rendering" {
    for (test_data) |td| {
        const filename, const ttf_data = td;
        testBitmapRendering(ttf_data) catch |e| {
            std.log.err("test failure from {s}\n", .{filename});
            return e;
        };
    }
}

fn expectEqualInts(expected: anytype, actual: anytype) anyerror!void {
    const actual_casted = std.math.cast(@TypeOf(expected), actual) orelse {
        std.debug.print("expected {any}, found {any}\n", .{ expected, actual });
        return error.TestFailed;
    };
    try std.testing.expectEqual(expected, actual_casted);
}

fn expectNearlyEqual(expected: []const u8, actual: []const u8) anyerror!void {
    if (expected.len != actual.len) return expectEqualSlices(u8, expected, actual);
    if (std.mem.eql(u8, expected, actual)) return;

    var max_dist: usize = 0;
    var total_dist: usize = 0;
    for (expected, actual) |e, a| {
        const dist = @max(e, a) - @min(e, a);
        max_dist = @max(dist, max_dist);
        total_dist += 1;
    }
    if (total_dist > 1500 or max_dist > 1) {
        std.debug.print("total_dist={d} max_dist={d}\n", .{ total_dist, max_dist });
        return expectEqualSlices(u8, expected, actual);
    }
}

// Locate a directory record so tests can alter its range without corrupting
// the other required tables in the bundled font.
fn tableRecord(bytes: []const u8, tag: *const [4]u8) usize {
    for (0..readU16(bytes, 4)) |i| {
        const record = 12 + 16 * i;
        if (std.mem.eql(u8, bytes[record..][0..4], tag)) return record;
    }
    unreachable;
}

test "CFF uses its declared table bounds" {
    const original = @embedFile("StandardSymbolsPS.otf");
    const record = tableRecord(original, "CFF ");
    const offset = std.mem.readInt(u32, original[record + 8 ..][0..4], .big);
    const length = std.mem.readInt(u32, original[record + 12 ..][0..4], .big);
    const font = try TrueType.load(original);
    try expectEqual(length, font.cff_data.cff.size);
    try expectEqualSlices(u8, original[offset..][0..length], font.cff_data.cff.data[0..font.cff_data.cff.size]);

    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    for ([_][2]u32{
        .{ @intCast(bytes.len + 1), length },
        .{ offset, @intCast(bytes.len - offset + 1) },
        .{ 0xfffffff0, 0xffffffff },
    }) |range| {
        @memcpy(bytes, original);
        std.mem.writeInt(u32, bytes[record + 8 ..][0..4], range[0], .big);
        std.mem.writeInt(u32, bytes[record + 12 ..][0..4], range[1], .big);
        try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    }
    for (0..4) |short_length| {
        @memcpy(bytes, original);
        std.mem.writeInt(u32, bytes[record + 12 ..][0..4], @intCast(short_length), .big);
        try std.testing.expectError(error.UnsupportedCffData, TrueType.load(bytes));
    }
    @memcpy(bytes, original);
    bytes[offset + 2] = 3; // header size must include the four header bytes
    try std.testing.expectError(error.UnsupportedCffData, TrueType.load(bytes));
}

test {
    _ = @import("composite.zig");
    _ = @import("cmap.zig");
}
