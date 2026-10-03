//! Small authored TrueType seed; the CFF seed reuses the existing test fixture.
const std = @import("std");
pub const cff = @embedFile("../test/StandardSymbolsPS.otf");
pub const tt = makeTrueType();

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn makeTrueType() [569]u8 {
    @setEvalBranchQuota(10000);
    var bytes: [569]u8 = @splat(0);
    put(u32, &bytes, 0, 0x10000);
    put(u16, &bytes, 4, 7);
    const tags = [_]*const [4]u8{ "head", "hhea", "maxp", "hmtx", "loca", "glyf", "cmap" };
    const lengths = [_]u32{ 54, 36, 32, 8, 12, 29, 274 };
    var offsets: [7]usize = undefined;
    var cursor: usize = 124;
    for (tags, lengths, 0..) |tag, length, i| {
        offsets[i] = cursor;
        const row = 12 + 16 * i;
        @memcpy(bytes[row..][0..4], tag);
        put(u32, &bytes, row + 8, @intCast(cursor));
        put(u32, &bytes, row + 12, length);
        cursor += length;
    }
    put(u32, &bytes, offsets[0], 0x10000);
    put(u16, &bytes, offsets[0] + 18, 1000);
    put(u16, &bytes, offsets[0] + 50, 1);
    put(u32, &bytes, offsets[1], 0x10000);
    put(i16, &bytes, offsets[1] + 4, 800);
    put(i16, &bytes, offsets[1] + 6, -200);
    put(u16, &bytes, offsets[1] + 34, 2);
    put(u32, &bytes, offsets[2], 0x10000);
    put(u16, &bytes, offsets[2] + 4, 2);
    put(u16, &bytes, offsets[3], 150);
    put(u16, &bytes, offsets[3] + 4, 150);
    put(u32, &bytes, offsets[4] + 8, 29);
    const g = offsets[5];
    put(i16, &bytes, g, 1);
    put(i16, &bytes, g + 6, 100);
    put(i16, &bytes, g + 8, 100);
    put(u16, &bytes, g + 10, 2);
    @memset(bytes[g + 14 ..][0..3], 1);
    put(i16, &bytes, g + 19, 100);
    put(i16, &bytes, g + 21, -100);
    put(i16, &bytes, g + 27, 100);
    const c = offsets[6];
    put(u16, &bytes, c + 2, 1);
    put(u16, &bytes, c + 4, 3);
    put(u16, &bytes, c + 6, 1);
    put(u32, &bytes, c + 8, 12);
    put(u16, &bytes, c + 14, 262);
    bytes[c + 18 + 'A'] = 1;
    return bytes;
}
