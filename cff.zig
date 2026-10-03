//! CFF font data and Type 2 charstring interpretation.

const std = @import("std");
const type2 = @import("type2.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const GlyphIndex = @import("glyph.zig").GlyphIndex;
const Vertex = @import("glyph.zig").Vertex;
const BitmapBox = @import("glyph.zig").BitmapBox;

pub const ParseError = error{ TruncatedCffData, InvalidCffData };

pub const GlyphShapeError = ParseError || type2.Error || error{
    OutOfMemory,
    CoordinateOutOfRange,
    Unimplemented,
    UnsupportedCffSeac,
    RMoveToStack,
    VMoveToStack,
    HMoveToStack,
    RLineToStack,
    VLineToStack,
    HLineToStack,
    HCurveToStack,
    RCurveToStack,
    RCurveLineStack,
    CurveLineStack,
    RLineCurveStack,
    CallGSubRStack,
    RecursionLimit,
    SubRNotFound,
    ReturnOutsideSubR,
    HFlexStack,
    FlexStack,
    HFlex1Stack,
    Flex1Stack,
    CurveToStack,
    ReservedOperator,
    PushStackOverflow,
    NoEndChar,
};

pub const CffData = struct {
    /// cff font data
    cff: Buf,
    /// the charstring index
    charstrings: Buf,
    /// global charstring subroutines index
    gsubrs: Buf,
    /// private charstring subroutines index
    subrs: Buf,
    /// array of font dicts
    fontdicts: Buf,
    /// map from glyph to fontdict
    fdselect: Buf,

    pub const empty: CffData = .{
        .cff = .empty,
        .charstrings = .empty,
        .gsubrs = .empty,
        .subrs = .empty,
        .fontdicts = .empty,
        .fdselect = .empty,
    };

    pub const InitError = ParseError || error{
        UnsupportedCffData,
    };

    pub fn init(bytes: []const u8) InitError!CffData {
        if (bytes.len < 4 or bytes[2] < 4 or bytes[2] > bytes.len) return error.UnsupportedCffData;
        if (bytes[0] != 1 or bytes[3] < 1 or bytes[3] > 4) return error.UnsupportedCffData;
        const size = std.math.cast(u32, bytes.len) orelse return error.InvalidCffData;
        var result: CffData = .empty;
        result.cff = .init(bytes.ptr, size);
        var b = result.cff;
        try b.seek(bytes[2]);
        // OpenType CFF FontSets contain exactly one font.
        // https://learn.microsoft.com/en-us/typography/opentype/spec/cff
        var names = try b.cffGetIndex();
        if (try names.cffIndexCount() != 1) return error.UnsupportedCffData;
        var topdictidx = try b.cffGetIndex();
        if (try topdictidx.cffIndexCount() != 1) return error.UnsupportedCffData;
        var topdict = try topdictidx.cffIndexGet(@fromBackingInt(0));
        _ = try b.cffGetIndex(); // string INDEX
        result.gsubrs = try b.cffGetIndex();

        var cstype: u32 = 2;
        var csoff: u32 = 0;
        var fdarrayoff: u32 = 0;
        var fdselectoff: u32 = 0;
        try topdict.dictGetInts(17, 1, @ptrCast(&csoff));
        try topdict.dictGetInts(0x100 | 6, 1, @ptrCast(&cstype));
        try topdict.dictGetInts(0x100 | 36, 1, @ptrCast(&fdarrayoff));
        try topdict.dictGetInts(0x100 | 37, 1, @ptrCast(&fdselectoff));
        result.subrs = try b.getSubrs(topdict);
        if (cstype != 2) return error.UnsupportedCffData;
        if (csoff == 0) return error.InvalidCffData;
        try b.seek(csoff);
        result.charstrings = try b.cffGetIndex();
        const glyph_count = try result.charstrings.cffIndexCount();
        if (glyph_count == 0) return error.InvalidCffData;

        if (fdarrayoff != 0) {
            if (fdselectoff == 0) return error.InvalidCffData;
            try b.seek(fdarrayoff);
            result.fontdicts = try b.cffGetIndex();
            const dict_count = try result.fontdicts.cffIndexCount();
            if (dict_count == 0) return error.InvalidCffData;
            for (0..dict_count) |i| {
                const dict = try result.fontdicts.cffIndexGet(@fromBackingInt(@as(u16, @intCast(i))));
                _ = try b.getSubrs(dict);
            }
            try b.seek(fdselectoff);
            result.fdselect = try b.range(fdselectoff, b.size - fdselectoff);
            try validateFdSelect(result.fdselect, glyph_count, dict_count);
        } else if (fdselectoff != 0) return error.InvalidCffData;
        return result;
    }
};

const Buf = struct {
    data: [*]const u8,
    cursor: u32,
    size: u32,

    pub const empty: Buf = .init(undefined, 0);

    pub fn init(data: [*]const u8, size: u32) Buf {
        return .{ .data = data, .size = size, .cursor = 0 };
    }

    pub fn skip(b: *Buf, count: u32) ParseError!void {
        if (count > b.size - b.cursor) return error.TruncatedCffData;
        b.cursor += count;
    }

    pub fn seek(b: *Buf, offset: u32) ParseError!void {
        if (offset > b.size) return error.TruncatedCffData;
        b.cursor = offset;
    }

    pub fn peek8(b: *const Buf) ParseError!u8 {
        if (b.cursor == b.size) return error.TruncatedCffData;
        return b.data[b.cursor];
    }

    pub fn get8(b: *Buf) ParseError!u8 {
        const value = try b.peek8();
        b.cursor += 1;
        return value;
    }

    pub fn get16(b: *Buf) ParseError!u16 {
        return @intCast(try b.get(2));
    }

    pub fn get32(b: *Buf) ParseError!u32 {
        return b.get(4);
    }

    pub fn get(b: *Buf, count: u32) ParseError!u32 {
        if (count < 1 or count > 4) return error.InvalidCffData;
        if (count > b.size - b.cursor) return error.TruncatedCffData;
        var value: u32 = 0;
        for (0..count) |_| value = (value << 8) | try b.get8();
        return value;
    }

    pub fn cffGetIndex(b: *Buf) ParseError!Buf {
        const start = b.cursor;
        const count: u32 = try b.get16();
        if (count != 0) {
            const width = try b.get8();
            if (width < 1 or width > 4) return error.InvalidCffData;
            var previous = try b.get(width);
            if (previous != 1) return error.InvalidCffData;
            for (0..count) |_| {
                const next = try b.get(width);
                if (next < previous) return error.InvalidCffData;
                previous = next;
            }
            try b.skip(previous - 1);
        }
        return b.range(start, b.cursor - start);
    }

    pub fn cffIndexGet(index: Buf, glyph: GlyphIndex) ParseError!Buf {
        var b = index;
        try b.seek(0);
        const count: u32 = try b.get16();
        const i: u32 = @backingInt(glyph);
        if (i >= count) return error.InvalidCffData;
        const width: u32 = try b.get8();
        if (width < 1 or width > 4) return error.InvalidCffData;
        const data_offset = 3 + (count + 1) * width;
        if (data_offset > b.size) return error.TruncatedCffData;
        try b.skip(i * width);
        const first = try b.get(width);
        const end = try b.get(width);
        if (first == 0 or end < first) return error.InvalidCffData;
        if (end - 1 > b.size - data_offset) return error.TruncatedCffData;
        return b.range(data_offset + first - 1, end - first);
    }

    pub fn cffIndexCount(b: *Buf) ParseError!u16 {
        try b.seek(0);
        return b.get16();
    }

    pub fn range(b: *const Buf, offset: u32, size: u32) ParseError!Buf {
        if (offset > b.size or size > b.size - offset) return error.TruncatedCffData;
        return .init(b.data + offset, size);
    }

    pub fn cffInt(b: *Buf) ParseError!u32 {
        const first: i32 = try b.get8();
        return switch (first) {
            32...246 => @bitCast(first - 139),
            247...250 => @bitCast((first - 247) * 256 + try b.get8() + 108),
            251...254 => @bitCast(-(first - 251) * 256 - try b.get8() - 108),
            28 => @bitCast(@as(i32, @as(i16, @bitCast(try b.get16())))),
            29 => try b.get32(),
            else => error.InvalidCffData,
        };
    }

    pub fn dictGetInts(b: *Buf, key: u32, count: u32, out: [*]u32) ParseError!void {
        var operands = try b.dictGet(key);
        if (operands.size == 0) return; // absent operator: keep the default
        for (0..count) |i| out[i] = try operands.cffInt();
        if (operands.cursor != operands.size) return error.InvalidCffData;
    }

    pub fn dictGet(b: *Buf, key: u32) ParseError!Buf {
        try b.seek(0);
        while (b.cursor < b.size) {
            const start = b.cursor;
            while (try b.peek8() >= 28) try b.cffSkipOperand();
            const end = b.cursor;
            var op: u32 = try b.get8();
            if (op > 21) return error.InvalidCffData;
            if (op == 12) op = @as(u32, try b.get8()) | 0x100;
            if (op == key) {
                if (end == start) return error.InvalidCffData;
                return b.range(start, end - start);
            }
        }
        return .empty;
    }

    fn cffSkipOperand(b: *Buf) ParseError!void {
        if (try b.peek8() != 30) {
            _ = try b.cffInt();
            return;
        }
        try b.skip(1);
        while (true) {
            const byte = try b.get8();
            for ([_]u8{ byte >> 4, byte & 0xf }) |nibble| {
                if (nibble == 0xf) return;
                if (nibble == 0xd) return error.InvalidCffData;
            }
        }
    }

    pub fn getSubrs(cff: Buf, dictionary: Buf) ParseError!Buf {
        var private: [2]u32 = .{ 0, 0 };
        var dict = dictionary;
        try dict.dictGetInts(18, 2, &private);
        if (private[0] == 0) return .empty;
        var pdict = try cff.range(private[1], private[0]);
        var offset: u32 = 0;
        try pdict.dictGetInts(19, 1, @ptrCast(&offset));
        if (offset == 0) return .empty;
        if (offset > cff.size - private[1]) return error.TruncatedCffData;
        var b = cff;
        try b.seek(private[1] + offset);
        return b.cffGetIndex();
    }

    fn getSubr(index: Buf, number: u32) ParseError!Buf {
        if (index.size == 0) return .empty;
        var b = index;
        const count = try b.cffIndexCount();
        const bias: u32 = if (count >= 33900) 32768 else if (count >= 1240) 1131 else 107;
        const n = number +% bias;
        if (n >= count) return .empty;
        return b.cffIndexGet(@fromBackingInt(@as(u16, @intCast(n))));
    }
};

pub const CharstringCtx = struct {
    first_x: f64,
    first_y: f64,
    x: f64,
    y: f64,
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,
    num_vertices: u32,
    vertices: [*]Vertex,
    flags: Flags,

    const Flags = packed struct(u8) {
        started: bool = false,
        mode: enum(u1) {
            /// set min/max and num_vertices
            bounds,
            /// set vertices and num_vertices
            verts,
        },
        _padding: u6 = undefined,
    };

    pub fn init(flags: Flags, vertices: [*]Vertex) CharstringCtx {
        return .{
            .flags = flags,
            .vertices = vertices,
            .first_x = 0,
            .first_y = 0,
            .x = 0,
            .y = 0,
            .min_x = 0,
            .min_y = 0,
            .max_x = 0,
            .max_y = 0,
            .num_vertices = 0,
        };
    }
    pub fn deinit(ctx: *CharstringCtx, alloc: Allocator) void {
        if (ctx.flags.mode == .verts)
            alloc.free(ctx.allVertices());
    }

    fn trackVertex(ctx: *CharstringCtx, x: i32, y: i32) void {
        if (x > ctx.max_x or !ctx.flags.started) ctx.max_x = x;
        if (y > ctx.max_y or !ctx.flags.started) ctx.max_y = y;
        if (x < ctx.min_x or !ctx.flags.started) ctx.min_x = x;
        if (y < ctx.min_y or !ctx.flags.started) ctx.min_y = y;
        ctx.flags.started = true;
    }

    fn coordinate(value: f64) error{CoordinateOutOfRange}!i16 {
        const integer = @trunc(value);
        if (!std.math.isFinite(integer) or integer < -32768 or integer > 32767)
            return error.CoordinateOutOfRange;
        return @intFromFloat(integer);
    }

    fn v(ctx: *CharstringCtx, ty: Vertex.Type, x_value: f64, y_value: f64, cx_value: f64, cy_value: f64, cx1_value: f64, cy1_value: f64) !void {
        // Validate in both passes; bounds must describe the same integer outline.
        const x = try coordinate(x_value);
        const y = try coordinate(y_value);
        const cx = try coordinate(cx_value);
        const cy = try coordinate(cy_value);
        const cx1 = try coordinate(cx1_value);
        const cy1 = try coordinate(cy1_value);
        if (ctx.flags.mode == .bounds) {
            trackVertex(ctx, x, y);
            if (ty == .vcubic) {
                trackVertex(ctx, cx, cy);
                trackVertex(ctx, cx1, cy1);
            }
        } else {
            ctx.vertices[ctx.num_vertices].set(ty, x, y, cx, cy);
            ctx.vertices[ctx.num_vertices].cx1 = @truncate(cx1);
            ctx.vertices[ctx.num_vertices].cy1 = @truncate(cy1);
        }
        ctx.num_vertices += 1;
    }

    fn closeShape(ctx: *CharstringCtx) !void {
        if (ctx.first_x != ctx.x or ctx.first_y != ctx.y)
            try ctx.v(.vline, ctx.first_x, ctx.first_y, 0, 0, 0, 0);
    }

    fn rmoveTo(ctx: *CharstringCtx, dx: f64, dy: f64) !void {
        try ctx.closeShape();
        ctx.first_x = ctx.x + dx;
        ctx.x = ctx.first_x;
        ctx.first_y = ctx.y + dy;
        ctx.y = ctx.first_y;
        // std.log.debug("moveTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
        try ctx.v(.vmove, ctx.x, ctx.y, 0, 0, 0, 0);
    }

    fn rlineTo(ctx: *CharstringCtx, dx: f64, dy: f64) !void {
        ctx.x += dx;
        ctx.y += dy;
        // std.log.debug("lineTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
        try ctx.v(.vline, ctx.x, ctx.y, 0, 0, 0, 0);
    }

    fn rccurveTo(ctx: *CharstringCtx, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) !void {
        const cx1 = ctx.x + dx1;
        const cy1 = ctx.y + dy1;
        const cx2 = cx1 + dx2;
        const cy2 = cy1 + dy2;
        ctx.x = cx2 + dx3;
        ctx.y = cy2 + dy3;
        // std.log.debug("curveTo {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}", .{ ctx.x, ctx.y, cx1, cy1, cx2, cy2 });
        try ctx.v(
            .vcubic,
            ctx.x,
            ctx.y,
            cx1,
            cy1,
            cx2,
            cy2,
        );
    }
};

pub fn glyphBox(cff_data: *const CffData, glyph: GlyphIndex) ?BitmapBox {
    return glyphBoxChecked(cff_data, glyph) catch null;
}

pub fn glyphBoxChecked(cff_data: *const CffData, glyph: GlyphIndex) GlyphShapeError!?BitmapBox {
    var ctx = CharstringCtx.init(.{ .mode = .bounds }, undefined);
    try runCharstring(cff_data, glyph, &ctx);
    if (ctx.num_vertices == 0) return null;

    return .{
        .x0 = ctx.min_x,
        .y0 = ctx.min_y,
        .x1 = ctx.max_x,
        .y1 = ctx.max_y,
    };
}

pub fn glyphShape(cff_data: *const CffData, gpa: Allocator, glyph: GlyphIndex) GlyphShapeError![]Vertex {
    // mode=bounds to get bounds and num_vertices
    var count_ctx = CharstringCtx.init(.{ .mode = .bounds }, undefined);
    try runCharstring(cff_data, glyph, &count_ctx);
    const vertices = try gpa.alloc(Vertex, count_ctx.num_vertices);
    errdefer gpa.free(vertices);
    // mode=verts to assign vertices
    var out_ctx = CharstringCtx.init(.{ .mode = .verts }, vertices.ptr);
    try runCharstring(cff_data, glyph, &out_ctx);
    assert(out_ctx.num_vertices == count_ctx.num_vertices);
    // std.log.debug(
    //     "glyphShapeT2() first {d:.1},{d:.1} xy {d:.1},{d:.1} min {d:.1},{d:.1} max {d:.1},{d:.1} num_vertices {}",
    //     .{ count_ctx.first_x, count_ctx.first_y, count_ctx.x, count_ctx.y, count_ctx.min_x, count_ctx.min_y, count_ctx.max_x, count_ctx.max_y, count_ctx.num_vertices },
    // );

    return out_ctx.vertices[0..out_ctx.num_vertices];
}

const Instruction = enum(u8) {
    hintmask = 0x13,
    cntrmask = 0x14,
    hstem = 0x01,
    vstem = 0x03,
    hstemhm = 0x12,
    vstemhm = 0x17,
    rmoveto = 0x15,
    vmoveto = 0x04,
    hmoveto = 0x16,
    rlineto = 0x05,
    vlineto = 0x07,
    hlineto = 0x06,
    hvcurveto = 0x1F,
    vhcurveto = 0x1E,
    rrcurveto = 0x08,
    rcurveline = 0x18,
    rlinecurve = 0x19,
    vvcurveto = 0x1A,
    hhcurveto = 0x1B,
    callsubr = 0x0A,
    callgsubr = 0x1D,
    /// return
    ret = 0x0B,
    endchar = 0x0E,
    twoByteEscape = 0x0C,
    hflex = 0x22,
    flex = 0x23,
    hflex1 = 0x24,
    flex1 = 0x25,

    pub fn asInt(i: Instruction) u16 {
        return @backingInt(i);
    }
};

fn runCharstring(cff_data: *const CffData, glyph: GlyphIndex, ctx: *CharstringCtx) !void {
    var state: type2.State = .init(@backingInt(glyph));
    var maskbits: u32 = 0;
    var in_header = true;
    var width_seen = false;
    var path_started = false;
    var has_subrs = false;
    var clear_stack = false;
    var s: [48]f64 = @splat(0); // stack
    var sp: u32 = 0; // stack pointer
    var subr_buf: [10]Buf = undefined;
    var subr_stack: std.ArrayList(Buf) = .initBuffer(&subr_buf);
    var subrs = cff_data.subrs;
    // this currently ignores the initial width value, which isn't needed if we have hmtx
    var b = try cff_data.charstrings.cffIndexGet(glyph);

    while (b.cursor < b.size) {
        var i: u32 = 0;
        clear_stack = true;
        const b0: u16 = try b.get8();
        // const tag_name = if (std.meta.intToEnum(Instruction, b0)) |t| @tagName(t) else |_| "other";
        // std.log.debug("{}/{} b0 {s}/{}/0x{x} num_vertices {}", .{ b.cursor, b.size, tag_name, b0, b0, ctx.num_vertices });

        if (!path_started and switch (b0) {
            5...8, 24...27, 30, 31 => true,
            else => false,
        }) return error.InvalidCffData;

        sw: switch (b0) {
            // @TODO implement hinting
            Instruction.hintmask.asInt(), // 0x13
            Instruction.cntrmask.asInt(), // 0x14
            => {
                skipWidth(&s, &sp, &width_seen, sp % 2 != 0);
                if (sp % 2 != 0 or (!in_header and sp != 0)) return error.InvalidCffData;
                if (in_header) maskbits += sp / 2; // implicit vstem
                if (maskbits == 0 or maskbits > 96) return error.InvalidCffData;
                in_header = false;
                try b.skip((maskbits + 7) / 8);
            },
            Instruction.hstem.asInt(), // 0x01
            Instruction.vstem.asInt(), // 0x03
            Instruction.hstemhm.asInt(), // 0x12
            Instruction.vstemhm.asInt(), // 0x17
            => {
                skipWidth(&s, &sp, &width_seen, sp % 2 != 0);
                if (!in_header or sp < 2 or sp % 2 != 0) return error.InvalidCffData;
                maskbits += sp / 2;
                if (maskbits > 96) return error.InvalidCffData;
            },
            Instruction.rmoveto.asInt() => { // 0x15
                in_header = false;
                skipWidth(&s, &sp, &width_seen, sp == 3);
                if (sp != 2) return error.RMoveToStack;
                path_started = true;
                try ctx.rmoveTo(s[sp - 2], s[sp - 1]);
            },
            Instruction.vmoveto.asInt() => { // 0x04
                in_header = false;
                skipWidth(&s, &sp, &width_seen, sp == 2);
                if (sp != 1) return error.VMoveToStack;
                path_started = true;
                try ctx.rmoveTo(0, s[sp - 1]);
            },
            Instruction.hmoveto.asInt() => { // 0x16
                in_header = false;
                skipWidth(&s, &sp, &width_seen, sp == 2);
                if (sp != 1) return error.HMoveToStack;
                path_started = true;
                try ctx.rmoveTo(s[sp - 1], 0);
            },
            Instruction.rlineto.asInt() => { // 0x05
                if (sp < 2 or sp % 2 != 0) return error.RLineToStack;
                while (i + 1 < sp) : (i += 2)
                    try ctx.rlineTo(s[i], s[i + 1]);
            },
            // hlineto/vlineto and vhcurveto/hvcurveto alternate horizontal and vertical
            // starting from a different place.
            Instruction.vlineto.asInt() => { // 0x07
                if (sp < 1) return error.VLineToStack;
                // std.log.debug("vlineto i {} sp {}", .{ i, sp });
                while (true) {
                    if (i >= sp) break;
                    try ctx.rlineTo(0, s[i]);
                    i += 1;
                    if (i >= sp) break;
                    try ctx.rlineTo(s[i], 0);
                    i += 1;
                }
            },
            Instruction.hlineto.asInt() => { // 0x06
                if (sp < 1) return error.HLineToStack;
                // std.log.debug("hlineto i {} sp {}", .{ i, sp });
                while (true) {
                    if (i >= sp) break;
                    try ctx.rlineTo(s[i], 0);
                    i += 1;
                    if (i >= sp) break;
                    try ctx.rlineTo(0, s[i]);
                    i += 1;
                }
            },
            Instruction.hvcurveto.asInt() => { // 0x1F
                if (sp < 4 or sp % 4 > 1) return error.HCurveToStack;
                while (true) {
                    // std.log.debug("hvcurveto i {} sp {}", .{ i, sp });
                    if (i + 3 >= sp) break;
                    try ctx.rccurveTo(s[i], 0, s[i + 1], s[i + 2], if (sp - i == 5) s[i + 4] else 0.0, s[i + 3]);
                    i += 4;
                    if (i + 3 >= sp) break;
                    try ctx.rccurveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], if (sp - i == 5) s[i + 4] else 0.0);
                    i += 4;
                }
            },
            Instruction.vhcurveto.asInt() => { // 0x1E
                if (sp < 4 or sp % 4 > 1) return error.HCurveToStack;
                while (true) {
                    // std.log.debug("vhcurveto i {} sp {}", .{ i, sp });
                    if (i + 3 >= sp) break;
                    try ctx.rccurveTo(0, s[i], s[i + 1], s[i + 2], s[i + 3], if (sp - i == 5) s[i + 4] else 0.0);
                    i += 4;
                    if (i + 3 >= sp) break;
                    try ctx.rccurveTo(s[i], 0, s[i + 1], s[i + 2], if (sp - i == 5) s[i + 4] else 0.0, s[i + 3]);
                    i += 4;
                }
            },
            Instruction.rrcurveto.asInt() => { // 0x08
                if (sp < 6 or sp % 6 != 0) return error.RCurveToStack;
                while (i + 5 < sp) : (i += 6)
                    try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            },
            Instruction.rcurveline.asInt() => { // 0x18
                if (sp < 8 or (sp - 2) % 6 != 0) return error.RCurveLineStack;
                while (i + 5 < sp - 2) : (i += 6)
                    try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                if (i + 1 >= sp) return error.CurveLineStack;
                try ctx.rlineTo(s[i], s[i + 1]);
            },
            Instruction.rlinecurve.asInt() => { // 0x19
                if (sp < 8 or (sp - 6) % 2 != 0) return error.RLineCurveStack;
                while (i + 1 < sp - 6) : (i += 2)
                    try ctx.rlineTo(s[i], s[i + 1]);
                if (i + 5 >= sp) return error.RLineCurveStack;
                try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            },
            Instruction.vvcurveto.asInt(), // 0x1A
            Instruction.hhcurveto.asInt(), // 0x1B
            => {
                if (sp < 4 or sp % 4 > 1) return error.CurveToStack;
                var f: f64 = 0.0;
                if (sp & 1 != 0) {
                    f = s[i];
                    i += 1;
                }
                while (i + 3 < sp) : (i += 4) {
                    if (b0 == Instruction.hhcurveto.asInt()) //  0x1B
                        try ctx.rccurveTo(s[i], f, s[i + 1], s[i + 2], s[i + 3], 0.0)
                    else
                        try ctx.rccurveTo(f, s[i], s[i + 1], s[i + 2], 0.0, s[i + 3]);
                    f = 0.0;
                }
            },
            Instruction.callsubr.asInt() => { // 0x0A
                if (!has_subrs) {
                    if (cff_data.fdselect.size != 0)
                        subrs = try getGlyphSubrs(cff_data, glyph);
                    has_subrs = true;
                }
                continue :sw Instruction.callgsubr.asInt();
                // FALLTHROUGH
            },
            Instruction.callgsubr.asInt() => { // 0x1D
                sp = std.math.sub(u32, sp, 1) catch return error.CallGSubRStack;
                const v = try type2.integer(s[sp]);
                subr_stack.appendBounded(b) catch return error.RecursionLimit;
                b = try (if (b0 == Instruction.callsubr.asInt()) // 0x0A
                    subrs
                else
                    cff_data.gsubrs).getSubr(@bitCast(v));
                if (b.size == 0) return error.SubRNotFound;
                b.cursor = 0;
                clear_stack = false;
            },
            Instruction.ret.asInt() => { // 0x0B
                b = subr_stack.pop() orelse return error.ReturnOutsideSubR;
                clear_stack = false;
            },
            Instruction.endchar.asInt() => { // 0x0E
                skipWidth(&s, &sp, &width_seen, sp % 2 != 0);
                if (sp == 4) return error.UnsupportedCffSeac;
                if (sp != 0) return error.InvalidCffData;
                try ctx.closeShape();
                return;
            },
            Instruction.twoByteEscape.asInt() => { // 0x0C
                const b1 = try b.get8();
                if (try type2.arithmetic(b1, &s, &sp) or try state.apply(b1, &s, &sp)) {
                    clear_stack = false;
                    continue;
                }
                if (b1 >= 34 and b1 <= 37 and !path_started) return error.InvalidCffData;
                switch (b1) {
                    0 => continue, // deprecated dotsection: ignore without clearing operands
                    // @TODO These "flex" implementations ignore the flex-depth and resolution,
                    // and always draw beziers.
                    Instruction.hflex.asInt() => { // 0x22
                        if (sp != 7) return error.HFlexStack;
                        const dx1 = s[0];
                        const dx2 = s[1];
                        const dy2 = s[2];
                        const dx3 = s[3];
                        const dx4 = s[4];
                        const dx5 = s[5];
                        const dx6 = s[6];
                        try ctx.rccurveTo(dx1, 0, dx2, dy2, dx3, 0);
                        try ctx.rccurveTo(dx4, 0, dx5, -dy2, dx6, 0);
                    },
                    Instruction.flex.asInt() => { // 0x23
                        if (sp != 13) return error.FlexStack;
                        const dx1 = s[0];
                        const dy1 = s[1];
                        const dx2 = s[2];
                        const dy2 = s[3];
                        const dx3 = s[4];
                        const dy3 = s[5];
                        const dx4 = s[6];
                        const dy4 = s[7];
                        const dx5 = s[8];
                        const dy5 = s[9];
                        const dx6 = s[10];
                        const dy6 = s[11];
                        //fd is s[12]
                        try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, dy3);
                        try ctx.rccurveTo(dx4, dy4, dx5, dy5, dx6, dy6);
                    },
                    Instruction.hflex1.asInt() => { // 0x24
                        if (sp != 9) return error.HFlex1Stack;
                        const dx1 = s[0];
                        const dy1 = s[1];
                        const dx2 = s[2];
                        const dy2 = s[3];
                        const dx3 = s[4];
                        const dx4 = s[5];
                        const dx5 = s[6];
                        const dy5 = s[7];
                        const dx6 = s[8];
                        try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, 0);
                        try ctx.rccurveTo(dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5));
                    },
                    Instruction.flex1.asInt() => { // 0x25
                        if (sp != 11) return error.Flex1Stack;
                        const dx1 = s[0];
                        const dy1 = s[1];
                        const dx2 = s[2];
                        const dy2 = s[3];
                        const dx3 = s[4];
                        const dy3 = s[5];
                        const dx4 = s[6];
                        const dy4 = s[7];
                        const dx5 = s[8];
                        const dy5 = s[9];
                        var dx6 = s[10];
                        var dy6 = s[10];
                        const dx = dx1 + dx2 + dx3 + dx4 + dx5;
                        const dy = dy1 + dy2 + dy3 + dy4 + dy5;
                        if (@abs(dx) > @abs(dy))
                            dy6 = -dy
                        else
                            dx6 = -dx;
                        try ctx.rccurveTo(dx1, dy1, dx2, dy2, dx3, dy3);
                        try ctx.rccurveTo(dx4, dy4, dx5, dy5, dx6, dy6);
                    },

                    else => return error.ReservedOperator,
                }
            },
            else => {
                if (b0 != 255 and b0 != 28 and b0 < 32)
                    return error.ReservedOperator;

                // push immediate
                const f: f64 = if (b0 == 255)
                    @as(f64, @floatFromInt(@as(i32, @bitCast(try b.get32())))) / 65536.0
                else blk: {
                    b.cursor -= 1;
                    break :blk @floatFromInt(@as(i16, @truncate(@as(i32, @bitCast(try b.cffInt())))));
                };
                // std.log.debug("f {d:.2}", .{f});
                if (sp >= 48) return error.PushStackOverflow;
                s[sp] = f;
                sp += 1;
                clear_stack = false;
            },
        }
        if (clear_stack) sp = 0;
    }
    return error.NoEndChar;
}

fn validateFdSelect(source: Buf, glyph_count: u16, dict_count: u16) ParseError!void {
    var b = source;
    const format = try b.get8();
    switch (format) {
        0 => for (0..glyph_count) |_| {
            if (try b.get8() >= dict_count) return error.InvalidCffData;
        },
        3 => {
            const count = try b.get16();
            var first = try b.get16();
            if (count == 0 or first != 0) return error.InvalidCffData;
            for (0..count) |_| {
                const dict = try b.get8();
                const end = try b.get16();
                if (dict >= dict_count or end <= first or end > glyph_count) return error.InvalidCffData;
                first = end;
            }
            if (first != glyph_count) return error.InvalidCffData;
        },
        else => return error.InvalidCffData,
    }
}

fn getGlyphSubrs(cff_data: *const CffData, glyph: GlyphIndex) ParseError!Buf {
    var fdselect = cff_data.fdselect;
    const format = try fdselect.get8();
    const selected: u16 = switch (format) {
        0 => blk: {
            try fdselect.skip(@backingInt(glyph));
            break :blk try fdselect.get8();
        },
        3 => blk: {
            const count = try fdselect.get16();
            var first = try fdselect.get16();
            for (0..count) |_| {
                const dict = try fdselect.get8();
                const end = try fdselect.get16();
                if (end <= first) return error.InvalidCffData;
                if (@backingInt(glyph) >= first and @backingInt(glyph) < end) break :blk dict;
                first = end;
            }
            return error.InvalidCffData;
        },
        else => return error.InvalidCffData,
    };
    const dict = try cff_data.fontdicts.cffIndexGet(@fromBackingInt(selected));
    return cff_data.cff.getSubrs(dict);
}

// Width is optional only at the first stem, mask, move, or endchar operator.
// OpenType horizontal metrics supply the actual advance, so discard it here.
fn skipWidth(s: *[48]f64, sp: *u32, seen: *bool, extra: bool) void {
    if (seen.*) return;
    seen.* = true;
    if (extra) {
        std.mem.copyForwards(f64, s[0 .. sp.* - 1], s[1..sp.*]);
        sp.* -= 1;
    }
}
