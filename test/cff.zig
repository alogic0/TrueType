const std = @import("std");
const TrueType = @import("TrueType");
const CffData = @TypeOf(@as(TrueType, undefined).cff_data);
const Buf = @TypeOf(CffData.empty.cff);
const expectError = std.testing.expectError;

const minimal = [_]u8{
    1, 0, 4, 4, // header
    0, 1, 1, 1, 2, 'A', // Name INDEX
    0, 1, 1, 1, 3, 160, 17, // Top DICT: CharStrings at 21
    0, 0, 0, 0, // empty String and Global Subr INDEXes
    0, 1, 1, 1, 2, 14, // one endchar program
};

test "CFF rejects truncated tables and malformed INDEX offsets" {
    _ = try CffData.init(&minimal);
    for (0..minimal.len) |length| {
        if (CffData.init(minimal[0..length])) |_| return error.AcceptedTruncatedCff else |_| {}
    }
    for ([_][]const u8{
        &.{ 0, 1, 0 }, // zero offSize
        &.{ 0, 1, 5 }, // oversized offSize
        &.{ 0, 1, 1, 0, 2, 14 }, // offsets are one based
        &.{ 0, 1, 1, 2, 3, 14, 14 }, // first offset must be one
        &.{ 0, 2, 1, 1, 3, 2, 14, 14 }, // decreasing offsets
    }) |bytes| {
        var b: Buf = .init(bytes.ptr, @intCast(bytes.len));
        try expectError(error.InvalidCffData, b.cffGetIndex());
    }
    for ([_][]const u8{
        &.{0},                                             &.{ 0, 1, 1, 1 }, &.{ 0, 1, 1, 1, 3, 14 },
        &.{ 0, 1, 4, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xff },
    }) |bytes| {
        var b: Buf = .init(bytes.ptr, @intCast(bytes.len));
        try expectError(error.TruncatedCffData, b.cffGetIndex());
    }
    var bad = minimal;
    bad[15] = 246; // CharStrings beyond this table
    try expectError(error.TruncatedCffData, CffData.init(&bad));
    var index: Buf = .init(minimal[21..].ptr, 6);
    try expectError(error.InvalidCffData, index.cffIndexGet(@fromBackingInt(1)));
}

test "CFF validates DICT operand widths and private subroutine offsets" {
    for ([_][]const u8{ &.{28}, &.{ 29, 0, 0, 0 }, &.{ 30, 0x12 }, &.{ 139, 12 } }) |bytes| {
        var dict: Buf = .init(bytes.ptr, @intCast(bytes.len));
        var value: u32 = 0;
        try expectError(error.TruncatedCffData, dict.dictGetInts(17, 1, @ptrCast(&value)));
    }
    for ([_][]const u8{ &.{17}, &.{ 139, 140, 17 }, &.{ 30, 0xdf, 17 }, &.{ 255, 17 } }) |bytes| {
        var dict: Buf = .init(bytes.ptr, @intCast(bytes.len));
        var value: u32 = 0;
        try expectError(error.InvalidCffData, dict.dictGetInts(17, 1, @ptrCast(&value)));
    }
    var signed: Buf = .init((&[_]u8{ 28, 0xff, 0xff }).ptr, 3);
    try std.testing.expectEqual(@as(u32, 0xffffffff), try signed.cffInt());
    const bytes = [_]u8{ 0, 29, 0xff, 0xff, 0xff, 0xff, 19 };
    const cff: Buf = .init(&bytes, bytes.len);
    // Private DICT at offset 1, length 6; local Subrs offset would wrap.
    const dict = [_]u8{ 145, 140, 18 };
    try expectError(error.TruncatedCffData, cff.getSubrs(.init(&dict, dict.len)));
    const outside = [_]u8{ 145, 146, 18 };
    try expectError(error.TruncatedCffData, cff.getSubrs(.init(&outside, outside.len)));
}

fn cidFont(w: *std.Io.Writer, selection: []const u8) ![]const u8 {
    try w.writeAll(minimal[0..10]);
    // Eight-byte Top DICT: CharStrings at 27, FDArray at 33, FDSelect at 38.
    try w.writeAll(&.{ 0, 1, 1, 1, 9, 166, 17, 172, 12, 36, 177, 12, 37 });
    try w.writeAll(&.{ 0, 0, 0, 0 });
    try w.writeAll(&.{ 0, 1, 1, 1, 2, 14 });
    try w.writeAll(&.{ 0, 1, 1, 1, 1 }); // one empty Font DICT
    try w.writeAll(selection);
    return w.buffered();
}

test "CFF validates CID FDSelect IDs ranges and sentinels" {
    for ([_][]const u8{ &.{ 0, 0 }, &.{ 3, 0, 1, 0, 0, 0, 0, 1 } }) |selection| {
        var storage: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        _ = try CffData.init(try cidFont(&writer, selection));
    }
    for ([_][]const u8{
        &.{ 0, 1 }, // nonexistent Font DICT
        &.{ 3, 0, 0, 0, 0 }, // no ranges
        &.{ 3, 0, 1, 0, 1, 0, 0, 1 }, // first range doesn't start at zero
        &.{ 3, 0, 1, 0, 0, 1, 0, 1 }, // nonexistent Font DICT
        &.{ 3, 0, 1, 0, 0, 0, 0, 0 }, // empty range
        &.{ 3, 0, 1, 0, 0, 0, 0, 2 }, // sentinel exceeds glyph count
        &.{4}, // unsupported format
    }) |selection| {
        var storage: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try expectError(error.InvalidCffData, CffData.init(try cidFont(&writer, selection)));
    }
    var storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try expectError(error.TruncatedCffData, CffData.init(try cidFont(&writer, &.{ 3, 0, 1, 0, 0, 0, 0 })));
}

test "CFF incomplete charstrings return errors without reading adjacent data" {
    for ([_][]const u8{ &.{255}, &.{ 255, 0, 0, 0 }, &.{28}, &.{247}, &.{12}, &.{ 139, 140, 1, 19 } }) |program| {
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..26], minimal[0..26]);
        bytes[25] = @intCast(program.len + 1);
        @memcpy(bytes[26..][0..program.len], program);
        const tt: TrueType = .{
            .table_offsets = @splat(0),
            .ttf_bytes = &bytes,
            .index_map = 0,
            .index_to_loc_format = 0,
            .glyphs_len = 1,
            .cff_data = try CffData.init(bytes[0 .. 26 + program.len]),
        };
        try expectError(error.TruncatedCffData, tt.glyphShape(std.testing.allocator, @fromBackingInt(0)));
    }
}

test "CFF bundled font tolerates every truncation boundary" {
    const tt = try TrueType.load(@embedFile("StandardSymbolsPS.otf"));
    const bytes = tt.cff_data.cff.data[0..tt.cff_data.cff.size];
    for (0..bytes.len) |length| {
        _ = CffData.init(bytes[0..length]) catch continue;
    }
}

pub fn programFont(storage: []u8, program: []const u8) !TrueType {
    @memcpy(storage[0..21], minimal[0..21]);
    @memcpy(storage[21..26], &[_]u8{ 0, 1, 2, 0, 1 });
    std.mem.writeInt(u16, storage[26..28], @intCast(program.len + 1), .big);
    @memcpy(storage[28..][0..program.len], program);
    return .{
        .table_offsets = @splat(0),
        .ttf_bytes = storage[0 .. 28 + program.len],
        .index_map = 0,
        .index_to_loc_format = 0,
        .glyphs_len = 1,
        .cff_data = try CffData.init(storage[0 .. 28 + program.len]),
    };
}

fn fixed(w: *std.Io.Writer, value: i32) !void {
    try w.writeByte(255);
    try w.writeInt(i32, value, .big);
}

test "CFF fixed operands preserve signed fractions and accumulated deltas" {
    var program: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&program);
    try fixed(&w, -98304); // -1.5
    try fixed(&w, 98304); // 1.5
    try w.writeByte(21);
    for (0..2) |_| {
        try fixed(&w, 32768); // +0.5
        try fixed(&w, -32768); // -0.5
        try w.writeByte(5);
    }
    try w.writeByte(14);
    var storage: [256]u8 = undefined;
    const tt = try programFont(&storage, w.buffered());
    const shape = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
    defer std.testing.allocator.free(shape);
    try std.testing.expectEqual(4, shape.len);
    for (shape[0..3], [_]i16{ -1, -1, 0 }, [_]i16{ 1, 1, 0 }) |v, x, y| {
        try std.testing.expectEqual(x, v.x);
        try std.testing.expectEqual(y, v.y);
    }
}

test "CFF fixed operand boundaries retain the integer vertex contract" {
    for ([_]i32{ 0, 1, -1, 2147483647, -2147483648 }) |value| {
        var program: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&program);
        try fixed(&w, value);
        try w.writeAll(&.{ 139, 21, 14 });
        var storage: [128]u8 = undefined;
        const tt = try programFont(&storage, w.buffered());
        const shape = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
        defer std.testing.allocator.free(shape);
        try std.testing.expectEqual(@as(i16, @intCast(@divTrunc(value, 65536))), shape[0].x);
    }
}

test "CFF coordinate overflow returns an error before allocation" {
    for ([_][]const u8{
        &.{ 28, 0x7f, 0xff, 139, 21, 140, 139, 5, 14 },
        &.{ 28, 0x80, 0, 139, 21, 138, 139, 5, 14 },
        &.{ 28, 0x7f, 0xff, 139, 21, 140, 139, 138, 139, 139, 139, 8, 14 },
    }) |program| {
        var storage: [128]u8 = undefined;
        const tt = try programFont(&storage, program);
        var no_alloc: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
        try expectError(error.CoordinateOutOfRange, tt.glyphShape(no_alloc.allocator(), @fromBackingInt(0)));
    }
}
