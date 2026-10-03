const std = @import("std");
const TrueType = @import("TrueType");
const expectEqual = std.testing.expectEqual;
const gpa = std.testing.allocator;

const Point = struct { x: i16, y: i16, on: bool = true };
const Component = struct {
    glyph: u16,
    flags: u16,
    a: i32,
    b: i32,
    matrix: [4]i16 = .{ 16384, 0, 0, 16384 },
};

fn simple(w: *std.Io.Writer, points: []const Point) ![]const u8 {
    try w.writeInt(i16, 1, .big);
    try w.splatByteAll(0, 8); // bounds are unused by glyphShape
    try w.writeInt(u16, @intCast(points.len - 1), .big);
    try w.writeInt(u16, 0, .big); // no instructions
    for (points) |p| try w.writeByte(if (p.on) 1 else 0);
    var x: i16 = 0;
    for (points) |p| {
        try w.writeInt(i16, p.x - x, .big);
        x = p.x;
    }
    var y: i16 = 0;
    for (points) |p| {
        try w.writeInt(i16, p.y - y, .big);
        y = p.y;
    }
    return w.buffered();
}

fn composite(w: *std.Io.Writer, components: []const Component) ![]const u8 {
    try w.writeInt(i16, -1, .big);
    try w.splatByteAll(0, 8);
    for (components, 0..) |part, i| {
        const flags = part.flags | @as(u16, if (i + 1 < components.len) 0x20 else 0);
        try w.writeInt(u16, flags, .big);
        try w.writeInt(u16, part.glyph, .big);
        for ([_]i32{ part.a, part.b }) |arg| {
            if (flags & 1 != 0) {
                const word: u16 = if (flags & 2 != 0) @bitCast(@as(i16, @intCast(arg))) else @intCast(arg);
                try w.writeInt(u16, word, .big);
            } else {
                const byte: u8 = if (flags & 2 != 0) @bitCast(@as(i8, @intCast(arg))) else @intCast(arg);
                try w.writeByte(byte);
            }
        }
        if (flags & 8 != 0) {
            try w.writeInt(i16, part.matrix[0], .big);
        } else if (flags & 0x40 != 0) {
            try w.writeInt(i16, part.matrix[0], .big);
            try w.writeInt(i16, part.matrix[3], .big);
        } else if (flags & 0x80 != 0) {
            for (part.matrix) |element| try w.writeInt(i16, element, .big);
        }
    }
    return w.buffered();
}

fn font(w: *std.Io.Writer, glyphs: []const []const u8) !TrueType {
    const loca = 4;
    try w.splatByteAll(0, loca + 4 * (glyphs.len + 1));
    const glyf = w.buffered().len;
    for (glyphs, 0..) |data, i| {
        std.mem.writeInt(u32, w.buffer[loca + 4 * i ..][0..4], @intCast(w.buffered().len - glyf), .big);
        try w.writeAll(data);
    }
    std.mem.writeInt(u32, w.buffer[loca + 4 * glyphs.len ..][0..4], @intCast(w.buffered().len - glyf), .big);
    var result: TrueType = .{
        .table_offsets = @splat(0),
        .ttf_bytes = w.buffered(),
        .index_map = 0,
        .index_to_loc_format = 1,
        .glyphs_len = @intCast(glyphs.len),
        .cff_data = .empty,
    };
    result.table_offsets[@backingInt(TrueType.TableId.loca)] = loca;
    result.table_offsets[@backingInt(TrueType.TableId.glyf)] = @intCast(glyf);
    result.table_lengths[@backingInt(TrueType.TableId.loca)] = @intCast(4 * (glyphs.len + 1));
    result.table_lengths[@backingInt(TrueType.TableId.glyf)] = @intCast(w.buffered().len - glyf);
    return result;
}

test "composite attachments use original off-curve point numbers" {
    var base_buf: [128]u8 = undefined;
    var base_w: std.Io.Writer = .fixed(&base_buf);
    const base = try simple(&base_w, &.{ .{ .x = 0, .y = 0, .on = false }, .{ .x = 100, .y = 0, .on = false }, .{ .x = 100, .y = 100 } });
    var child_buf: [128]u8 = undefined;
    var child_w: std.Io.Writer = .fixed(&child_buf);
    const child = try simple(&child_w, &.{ .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 10, .on = false }, .{ .x = 20, .y = 20 } });
    for ([_]u16{ 0, 1 }) |word_args| {
        var comp_buf: [128]u8 = undefined;
        var comp_w: std.Io.Writer = .fixed(&comp_buf);
        const comp = try composite(&comp_w, &.{
            .{ .glyph = 0, .flags = 3, .a = 10, .b = 20 },
            .{ .glyph = 1, .flags = word_args, .a = 1, .b = 1 },
        });
        var font_buf: [512]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ base, child, comp });
        const verts = try tt.glyphShape(gpa, @fromBackingInt(2));
        defer gpa.free(verts);
        // Base begins at an implied midpoint; its point 1 is still (110,20).
        try expectEqual(60, verts[0].x);
        var moves: usize = 0;
        for (verts, 0..) |v, i| {
            if (v.type != .vmove) continue;
            moves += 1;
            if (moves == 2) {
                try expectEqual(100, v.x);
                try expectEqual(20, v.y);
                try expectEqual(110, verts[i + 1].cx);
                try expectEqual(20, verts[i + 1].cy);
                try expectEqual(110, verts[i + 1].x);
                try expectEqual(30, verts[i + 1].y);
            }
        }
        try expectEqual(2, moves);
    }
}

test "composite attachments transform child anchors and retain nested numbering" {
    var base_buf: [128]u8 = undefined;
    var base_w: std.Io.Writer = .fixed(&base_buf);
    const base = try simple(&base_w, &.{ .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 20 } });
    var inner_buf: [128]u8 = undefined;
    var inner_w: std.Io.Writer = .fixed(&inner_buf);
    const inner = try composite(&inner_w, &.{
        .{ .glyph = 0, .flags = 3, .a = 100, .b = 50 },
        .{ .glyph = 0, .flags = 1, .a = 1, .b = 0 },
    });
    for ([_]Component{
        .{ .glyph = 0, .flags = 9, .a = 4, .b = 0, .matrix = .{ 8192, 0, 0, 8192 } },
        .{ .glyph = 0, .flags = 0x81, .a = 4, .b = 0, .matrix = .{ 0, 16384, -16384, 0 } },
    }, 0..) |part, case| {
        var outer_buf: [128]u8 = undefined;
        var outer_w: std.Io.Writer = .fixed(&outer_buf);
        const outer = try composite(&outer_w, &.{ .{ .glyph = 1, .flags = 3, .a = 5, .b = 6 }, part });
        var font_buf: [512]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ base, inner, outer });
        const verts = try tt.glyphShape(gpa, @fromBackingInt(2));
        defer gpa.free(verts);
        // Raw point 4 is point 1 of the nested second component: (135,66).
        try expectEqual(135, verts[8].x);
        try expectEqual(66, verts[8].y);
        try expectEqual(if (case == 0) @as(i16, 140) else 135, verts[9].x);
        try expectEqual(if (case == 0) @as(i16, 66) else 76, verts[9].y);
    }
}

test "composite point arguments are unsigned bytes or words" {
    var points: [260]Point = undefined;
    for (&points, 0..) |*p, i| p.* = .{ .x = @intCast(i), .y = 0 };
    var simple_buf: [2048]u8 = undefined;
    var simple_w: std.Io.Writer = .fixed(&simple_buf);
    const base = try simple(&simple_w, &points);
    for ([_]u16{ 0, 1 }) |word_args| {
        const index: i32 = if (word_args == 0) 129 else 259;
        var comp_buf: [128]u8 = undefined;
        var comp_w: std.Io.Writer = .fixed(&comp_buf);
        const comp = try composite(&comp_w, &.{
            .{ .glyph = 0, .flags = 3, .a = 0, .b = 0 },
            .{ .glyph = 0, .flags = word_args, .a = index, .b = index - 1 },
        });
        var font_buf: [4096]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ base, comp });
        const verts = try tt.glyphShape(gpa, @fromBackingInt(1));
        defer gpa.free(verts);
        try expectEqual(1, verts[261].x);
    }
}

test "composite invalid point references and cycles return errors" {
    var simple_buf: [128]u8 = undefined;
    var simple_w: std.Io.Writer = .fixed(&simple_buf);
    const base = try simple(&simple_w, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } });
    for ([_]Component{
        .{ .glyph = 0, .flags = 1, .a = 99, .b = 0 },
        .{ .glyph = 0, .flags = 1, .a = 0, .b = 99 },
        .{ .glyph = 99, .flags = 3, .a = 0, .b = 0 },
        .{ .glyph = 1, .flags = 3, .a = 0, .b = 0 },
    }, 0..) |part, i| {
        var comp_buf: [128]u8 = undefined;
        var comp_w: std.Io.Writer = .fixed(&comp_buf);
        const comp = try composite(&comp_w, &.{ .{ .glyph = 0, .flags = 3, .a = 0, .b = 0 }, part });
        var font_buf: [512]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ base, comp });
        try std.testing.expectError(if (i == 3) error.RecursionLimit else error.InvalidCompositeGlyph, tt.glyphShape(gpa, @fromBackingInt(1)));
    }
}

test "TrueType glyph reads cannot escape into the following glyph" {
    var glyph_buf: [128]u8 = undefined;
    var glyph_w: std.Io.Writer = .fixed(&glyph_buf);
    const data = try simple(&glyph_w, &.{ .{ .x = 1, .y = 2 }, .{ .x = 10, .y = 20 }, .{ .x = 30, .y = 40 } });
    for (1..data.len) |length| {
        var font_buf: [512]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ data[0..length], data });
        const shape = tt.glyphShape(gpa, @fromBackingInt(0)) catch continue;
        gpa.free(shape);
        return error.AcceptedTruncatedGlyph;
    }
    var comp_buf: [128]u8 = undefined;
    var comp_w: std.Io.Writer = .fixed(&comp_buf);
    const comp = try composite(&comp_w, &.{.{ .glyph = 0, .flags = 0x83, .a = 1, .b = 2 }});
    for (1..comp.len) |length| {
        var font_buf: [512]u8 = undefined;
        var font_w: std.Io.Writer = .fixed(&font_buf);
        const tt = try font(&font_w, &.{ data, comp[0..length], comp });
        const shape = tt.glyphShape(gpa, @fromBackingInt(1)) catch continue;
        gpa.free(shape);
        return error.AcceptedTruncatedComposite;
    }
}

test "TrueType single off-curve contours and invalid flag repeats" {
    var glyph_buf: [64]u8 = undefined;
    var glyph_w: std.Io.Writer = .fixed(&glyph_buf);
    const data = try simple(&glyph_w, &.{.{ .x = 50, .y = 60, .on = false }});
    var font_buf: [128]u8 = undefined;
    var font_w: std.Io.Writer = .fixed(&font_buf);
    const tt = try font(&font_w, &.{data});
    const shape = try tt.glyphShape(gpa, @fromBackingInt(0));
    defer gpa.free(shape);
    try expectEqual(2, shape.len);
    try expectEqual(50, shape[0].x);
    try expectEqual(60, shape[0].y);
    const offset = tt.table_offsets[@backingInt(TrueType.TableId.glyf)];
    font_buf[offset + 14] = 8;
    font_buf[offset + 15] = 1; // repeats past the only point
    try std.testing.expectError(error.InvalidFontData, tt.glyphShape(gpa, @fromBackingInt(0)));
}

test "TrueType validates location intervals coordinate sums and component instructions" {
    var glyph_buf: [64]u8 = undefined;
    var glyph_w: std.Io.Writer = .fixed(&glyph_buf);
    const data = try simple(&glyph_w, &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } });
    var font_buf: [256]u8 = undefined;
    var font_w: std.Io.Writer = .fixed(&font_buf);
    const tt = try font(&font_w, &.{data});
    const loca = tt.table_offsets[@backingInt(TrueType.TableId.loca)];
    const glyf = tt.table_offsets[@backingInt(TrueType.TableId.glyf)];
    std.mem.writeInt(u32, font_buf[loca + 4 ..][0..4], 0xffffffff, .big);
    try std.testing.expectError(error.EndOfStream, tt.glyphShape(gpa, @fromBackingInt(0)));
    std.mem.writeInt(u32, font_buf[loca..][0..4], 1, .big);
    std.mem.writeInt(u32, font_buf[loca + 4 ..][0..4], 0, .big);
    try std.testing.expectError(error.InvalidFontData, tt.glyphShape(gpa, @fromBackingInt(0)));
    std.mem.writeInt(u32, font_buf[loca..][0..4], 0, .big);
    std.mem.writeInt(u32, font_buf[loca + 4 ..][0..4], @intCast(data.len), .big);
    std.mem.writeInt(i16, font_buf[glyf + 16 ..][0..2], 32767, .big);
    try std.testing.expectError(error.CoordinateOutOfRange, tt.glyphShape(gpa, @fromBackingInt(0)));

    var comp_buf: [64]u8 = undefined;
    var comp_w: std.Io.Writer = .fixed(&comp_buf);
    const comp = try composite(&comp_w, &.{.{ .glyph = 0, .flags = 0x103, .a = 0, .b = 0 }});
    font_w = .fixed(&font_buf);
    const composite_tt = try font(&font_w, &.{ data, comp });
    try std.testing.expectError(error.EndOfStream, composite_tt.glyphShape(gpa, @fromBackingInt(1)));
}

test "composite budgets count repeated empty children and assembly work" {
    var comp_buf: [128]u8 = undefined;
    var comp_w: std.Io.Writer = .fixed(&comp_buf);
    const comp = try composite(&comp_w, &.{
        .{ .glyph = 0, .flags = 3, .a = 0, .b = 0 },
        .{ .glyph = 0, .flags = 3, .a = 0, .b = 0 },
        .{ .glyph = 0, .flags = 3, .a = 0, .b = 0 },
    });
    var font_buf: [512]u8 = undefined;
    var font_w: std.Io.Writer = .fixed(&font_buf);
    const tt = try font(&font_w, &.{ &.{}, comp });
    const limited = tt.withLimits(.{ .max_components = 3 });
    try std.testing.expectError(error.ResourceLimitExceeded, limited.glyphShape(gpa, @fromBackingInt(1)));
    const accepted = tt.withLimits(.{ .max_components = 4 });
    const shape = try accepted.glyphShape(gpa, @fromBackingInt(1));
    defer gpa.free(shape);
    try expectEqual(@as(usize, 0), shape.len);
}
