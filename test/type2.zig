const std = @import("std");
const TrueType = @import("TrueType");
const programFont = @import("cff.zig").programFont;

pub fn expectOperands(program: []const u8, expected: []const i16) !void {
    var code: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&code);
    try w.writeAll(&.{ 139, 139, 21 });
    try w.writeAll(program);
    if (expected.len % 2 != 0) try w.writeByte(139);
    try w.writeAll(&.{ 5, 14 });
    var storage: [1024]u8 = undefined;
    const tt = try programFont(&storage, w.buffered());
    const shape = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
    defer std.testing.allocator.free(shape);
    var x: i16 = 0;
    var y: i16 = 0;
    var i: usize = 0;
    while (i < expected.len) : (i += 2) {
        x += expected[i];
        if (i + 1 < expected.len) y += expected[i + 1];
        try std.testing.expectEqual(x, shape[i / 2 + 1].x);
        try std.testing.expectEqual(y, shape[i / 2 + 1].y);
    }
    const box = tt.glyphBox(@fromBackingInt(0)).?;
    for (shape) |v| try std.testing.expect(v.x >= box.x0 and v.x <= box.x1 and v.y >= box.y0 and v.y <= box.y1);
}

pub fn expectFailure(program: []const u8, err: anyerror) !void {
    var storage: [1024]u8 = undefined;
    const tt = try programFont(&storage, program);
    try std.testing.expectError(err, tt.glyphShape(std.testing.allocator, @fromBackingInt(0)));
}

test "CFF Type 2 arithmetic preserves stack operands and evaluates numbers" {
    for ([_]struct { code: []const u8, values: []const i16 }{
        .{ .code = &.{ 134, 12, 9 }, .values = &.{5} }, // abs
        .{ .code = &.{ 159, 144, 12, 10 }, .values = &.{25} },
        .{ .code = &.{ 159, 144, 12, 11 }, .values = &.{15} },
        .{ .code = &.{ 149, 143, 12, 12, 143, 12, 24 }, .values = &.{10} }, // fractional div then mul
        .{ .code = &.{ 144, 12, 14 }, .values = &.{-5} },
        .{ .code = &.{ 144, 145, 12, 18 }, .values = &.{5} },
        .{ .code = &.{ 144, 145, 12, 24 }, .values = &.{30} },
        .{ .code = &.{ 175, 12, 26 }, .values = &.{6} },
        .{ .code = &.{ 144, 12, 27 }, .values = &.{ 5, 5 } },
        .{ .code = &.{ 144, 145, 12, 28 }, .values = &.{ 6, 5 } },
        .{ .code = &.{ 144, 145, 140, 12, 29 }, .values = &.{ 5, 6, 5 } },
        .{ .code = &.{ 144, 145, 138, 12, 29 }, .values = &.{ 5, 6, 6 } }, // negative index copies top
        .{ .code = &.{ 140, 141, 142, 142, 140, 12, 30 }, .values = &.{ 3, 1, 2 } },
        .{ .code = &.{ 140, 141, 142, 142, 138, 12, 30 }, .values = &.{ 2, 3, 1 } },
        .{ .code = &.{ 144, 139, 146, 12, 30 }, .values = &.{5} }, // zero-element roll
    }) |case| try expectOperands(case.code, case.values);
}

test "CFF Type 2 rejects stack and arithmetic faults" {
    for ([_]u8{ 9, 10, 11, 12, 14, 18, 24, 26, 27, 28, 29, 30 }) |op| {
        try expectFailure(&.{ 12, op, 14 }, error.StackUnderflow);
    }
    for ([_][]const u8{
        &.{ 140, 139, 12, 12, 14 }, // divide by zero
        &.{ 138, 12, 26, 14 }, // negative square root
        &.{ 140, 140, 12, 29, 14 }, // index outside stack
        &.{ 140, 141, 140, 12, 30, 14 }, // roll count exceeds stack
        &.{ 140, 138, 140, 12, 30, 14 }, // negative roll count
        &.{ 140, 255, 0, 0, 128, 0, 12, 29, 14 }, // fractional index
    }) |code| try expectFailure(code, error.InvalidCffOperand);
    var overflow: [51]u8 = @splat(139);
    @memcpy(overflow[48..], &[_]u8{ 12, 27, 14 });
    try expectFailure(&overflow, error.PushStackOverflow);
    var numeric: [100]u8 = undefined;
    var w: std.Io.Writer = .fixed(&numeric);
    try w.writeAll(&.{ 28, 0x7f, 0xff });
    for (0..20) |_| try w.writeAll(&.{ 12, 27, 12, 24 });
    try w.writeByte(14);
    try expectFailure(w.buffered(), error.CffNumericOverflow);
}

test "CFF Type 2 transient storage and conditionals" {
    for ([_]struct { code: []const u8, values: []const i16 }{
        .{ .code = &.{ 144, 170, 12, 20, 170, 12, 21 }, .values = &.{5} }, // put/get last slot
        .{ .code = &.{ 140, 138, 12, 3 }, .values = &.{1} },
        .{ .code = &.{ 140, 139, 12, 3 }, .values = &.{0} },
        .{ .code = &.{ 139, 138, 12, 4 }, .values = &.{1} },
        .{ .code = &.{ 139, 139, 12, 4 }, .values = &.{0} },
        .{ .code = &.{ 139, 12, 5 }, .values = &.{1} },
        .{ .code = &.{ 138, 12, 5 }, .values = &.{0} },
        .{ .code = &.{ 144, 144, 12, 15 }, .values = &.{1} },
        .{ .code = &.{ 144, 145, 12, 15 }, .values = &.{0} },
        .{ .code = &.{ 149, 159, 140, 141, 12, 22 }, .values = &.{10} },
        .{ .code = &.{ 149, 159, 141, 141, 12, 22 }, .values = &.{10} },
        .{ .code = &.{ 149, 159, 142, 141, 12, 22 }, .values = &.{20} },
    }) |case| try expectOperands(case.code, case.values);
    // A subsequent glyph (and its counting pass) cannot see a previous put.
    try expectFailure(&.{ 170, 12, 21, 14 }, error.UninitializedCffStorage);
    for ([_][]const u8{
        &.{ 144, 171, 12, 20, 14 }, &.{ 144, 138, 12, 20, 14 },
        &.{ 171, 12, 21, 14 },      &.{ 138, 12, 21, 14 },
    }) |code| try expectFailure(code, error.InvalidCffOperand);
    for ([_]u8{ 3, 4, 5, 15, 20, 21, 22 }) |op|
        try expectFailure(&.{ 12, op, 14 }, error.StackUnderflow);
}

test "CFF Type 2 random repeats across bounds outlines and calls" {
    var storage: [128]u8 = undefined;
    const tt = try programFont(&storage, &.{ 12, 23, 239, 12, 24, 12, 27, 21, 14 });
    const a = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
    defer std.testing.allocator.free(a);
    const b = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(a[0].x >= 0 and a[0].x <= 100);
    try std.testing.expectEqual(a[0].x, a[0].y);
    for (a, b) |va, vb| try std.testing.expectEqualDeep(va, vb);
    const box = tt.glyphBox(@fromBackingInt(0)).?;
    try std.testing.expectEqual(a[0].x, box.x0);
    try std.testing.expectEqual(a[0].x, box.x1);
    var full: [51]u8 = @splat(139);
    @memcpy(full[48..], &[_]u8{ 12, 23, 14 });
    try expectFailure(&full, error.PushStackOverflow);
}

test "CFF Type 2 subroutines share stack and transient storage" {
    var storage: [128]u8 = undefined;
    var tt = try programFont(&storage, &.{ 149, 139, 12, 20, 144, 32, 29, 139, 21, 14 });
    const subr = [_]u8{ 0, 1, 1, 1, 7, 139, 12, 21, 12, 10, 11 };
    tt.cff_data.gsubrs = .init(&subr, subr.len);
    const shape = try tt.glyphShape(std.testing.allocator, @fromBackingInt(0));
    defer std.testing.allocator.free(shape);
    try std.testing.expectEqual(15, shape[0].x);
}
