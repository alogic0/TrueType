const std = @import("std");
const TrueType = @import("TrueType");
const original = @embedFile("StandardSymbolsPS.otf");

pub fn tableRecord(bytes: []const u8, tag: *const [4]u8) usize {
    const count = std.mem.readInt(u16, bytes[4..6], .big);
    for (0..count) |i| {
        const record = 12 + i * 16;
        if (std.mem.eql(u8, bytes[record..][0..4], tag)) return record;
    }
    unreachable;
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

test "sfnt directory validates header ranges versions and duplicate consumed tags" {
    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    for (0..12) |len| try std.testing.expectError(error.EndOfStream, TrueType.load(bytes[0..len]));
    put(u16, bytes, 4, 0xffff);
    try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    @memcpy(bytes, original);
    put(u32, bytes, 0, 0x74746366); // collections need a face-selection API
    try std.testing.expectError(error.UnsupportedFontVersion, TrueType.load(bytes));
    @memcpy(bytes, original);
    const record = tableRecord(bytes, "head");
    for ([_][2]u32{ .{ @intCast(bytes.len + 1), 54 }, .{ 0xfffffff0, 0xffffffff }, .{ @intCast(bytes.len - 1), 54 } }) |range| {
        put(u32, bytes, record + 8, range[0]);
        put(u32, bytes, record + 12, range[1]);
        try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    }
    @memcpy(bytes, original);
    put(u32, bytes, record + 8, 0);
    try std.testing.expectError(error.InvalidFontData, TrueType.load(bytes));
    @memcpy(bytes, original);
    @memcpy(bytes[tableRecord(bytes, "hhea")..][0..4], "head");
    try std.testing.expectError(error.DuplicateTable, TrueType.load(bytes));
    @memcpy(bytes, original);
    @memcpy(bytes[record..][0..4], "NONE");
    try std.testing.expectError(error.MissingRequiredTable, TrueType.load(bytes));
}

test "sfnt metadata uses declared table lengths and coherent counts" {
    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    for ([_]struct { tag: *const [4]u8, length: u32 }{
        .{ .tag = "head", .length = 53 }, .{ .tag = "hhea", .length = 35 },
        .{ .tag = "maxp", .length = 5 },  .{ .tag = "hmtx", .length = 1 },
        .{ .tag = "cmap", .length = 3 },
    }) |case| {
        @memcpy(bytes, original);
        put(u32, bytes, tableRecord(bytes, case.tag) + 12, case.length);
        try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    }
    const font = try TrueType.load(original);
    const hhea = font.table_offsets[@backingInt(TrueType.TableId.hhea)];
    const maxp = font.table_offsets[@backingInt(TrueType.TableId.maxp)];
    for ([_]u16{ 0, @intCast(font.glyphs_len + 1) }) |count| {
        @memcpy(bytes, original);
        put(u16, bytes, hhea + 34, count);
        try std.testing.expectError(error.InvalidFontData, TrueType.load(bytes));
    }
    @memcpy(bytes, original);
    put(u16, bytes, maxp + 4, @intCast(font.glyphs_len + 1));
    try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    @memcpy(bytes, original);
    put(u16, bytes, maxp + 4, @intCast(font.glyphs_len - 1));
    put(u16, bytes, hhea + 34, @intCast(font.glyphs_len - 1));
    try std.testing.expectError(error.InvalidFontData, TrueType.load(bytes));
    @memcpy(bytes, original);
    put(i16, bytes, hhea + 4, 0);
    put(i16, bytes, hhea + 6, 0);
    try std.testing.expectError(error.InvalidFontData, TrueType.load(bytes));
}

test "sfnt cmap encoding records stay inside their table" {
    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    const font = try TrueType.load(original);
    const offset = font.table_offsets[@backingInt(TrueType.TableId.cmap)];
    put(u16, bytes, offset + 2, 0xffff);
    try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
    @memcpy(bytes, original);
    put(u32, bytes, offset + 8, 0xffffffff);
    try std.testing.expectError(error.EndOfStream, TrueType.load(bytes));
}
