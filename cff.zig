//! CFF font data and Type 2 charstring interpretation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const GlyphIndex = @import("glyph.zig").GlyphIndex;
const Vertex = @import("glyph.zig").Vertex;
const BitmapBox = @import("glyph.zig").BitmapBox;

pub const GlyphShapeError = error{
    OutOfMemory,
    Unimplemented,
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

    pub const InitError = error{
        UnsupportedCffData,
    };

    pub fn init(cff_offset: u32, bytes: [*]const u8) InitError!CffData {
        var result: CffData = .empty;
        // TODO this should use size from table (not 512MB)
        // https://codeberg.org/andrewrk/TrueType/issues/50
        result.cff = .init(bytes + cff_offset, 512 * 1024 * 1024);
        var b = result.cff;
        // read the header
        b.skip(2);
        b.seek(b.get8());
        // TODO the name INDEX could list multiple fonts, but we just use the first one.
        // https://codeberg.org/andrewrk/TrueType/issues/51
        _ = b.cffGetIndex(); // name INDEX
        var topdictidx = b.cffGetIndex();
        var topdict = topdictidx.cffIndexGet(@fromBackingInt(@intCast(0)));
        _ = b.cffGetIndex(); // string INDEX
        result.gsubrs = b.cffGetIndex();

        var cstype: u32 = 2;
        var csoff: u32 = 0;
        var fdarrayoff: u32 = 0;
        var fdselectoff: u32 = 0;

        topdict.dictGetInts(17, 1, @ptrCast(&csoff));
        topdict.dictGetInts(0x100 | 6, 1, @ptrCast(&cstype));
        topdict.dictGetInts(0x100 | 36, 1, @ptrCast(&fdarrayoff));
        topdict.dictGetInts(0x100 | 37, 1, @ptrCast(&fdselectoff));
        result.subrs = b.getSubrs(topdict);

        // we only support Type 2 charstrings
        if (cstype != 2) return error.UnsupportedCffData;
        if (csoff == 0) return error.UnsupportedCffData;

        if (fdarrayoff != 0) {
            // looks like a CID font
            if (fdselectoff == 0) return error.UnsupportedCffData;
            b.seek(fdarrayoff);
            result.fontdicts = b.cffGetIndex();
            result.fdselect = b.range(fdselectoff, b.size - fdselectoff);
        }

        b.seek(csoff);
        result.charstrings = b.cffGetIndex();
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

    pub fn skip(b: *Buf, o: u32) void {
        b.seek(b.cursor + o);
    }

    pub fn seek(b: *Buf, o: u32) void {
        assert(o <= b.size);
        b.cursor = if (o > b.size) b.size else o;
    }

    pub fn peek8(b: *Buf) u8 {
        if (b.cursor >= b.size)
            return 0;
        return b.data[b.cursor];
    }

    pub fn get8(b: *Buf) u8 {
        if (b.cursor >= b.size) return 0;
        defer b.cursor += 1;
        return b.data[b.cursor];
    }

    pub fn get16(b: *Buf) u16 {
        return @truncate(b.get(2));
    }

    pub fn get32(b: *Buf) u32 {
        return b.get(4);
    }

    pub fn get(b: *Buf, n: u32) u32 {
        var v: u32 = 0;
        assert(n >= 1 and n <= 4);
        for (0..n) |_|
            v = (v << 8) | b.get8();
        return v;
    }

    pub fn cffGetIndex(b: *Buf) Buf {
        const start = b.cursor;
        const count: u32 = b.get16();
        if (count != 0) {
            const offsize: u32 = b.get8();
            assert(offsize >= 1 and offsize <= 4);
            b.skip(offsize * count);

            b.skip(b.get(offsize) - 1);
        }
        return b.range(start, b.cursor - start);
    }

    pub fn cffIndexGet(b_const: Buf, glyph: GlyphIndex) Buf {
        var b = b_const;
        b.seek(0);
        const count: u32 = b.get16();
        const offsize: u32 = b.get8();
        const i: u32 = @backingInt(glyph);
        assert(i < count);
        assert(offsize >= 1 and offsize <= 4);
        b.skip(i * offsize);

        const start = b.get(offsize);
        const end = b.get(offsize);
        return b.range(2 + (count + 1) * offsize + start, end - start);
    }

    pub fn cffIndexCount(b: *Buf) u16 {
        b.seek(0);
        return b.get16();
    }

    pub fn range(b: *Buf, o: u32, s: u32) Buf {
        var r = Buf.empty;
        if (o < 0 or s < 0 or o > b.size or s > b.size - o) return r;
        r.data = b.data + o;
        r.size = s;
        return r;
    }

    pub fn cffInt(b: *Buf) u32 {
        const b0: i32 = b.get8();
        const result: u32 = switch (b0) {
            32...246 => @bitCast(b0 - 139),
            247...250 => @bitCast((b0 - 247) * 256 + b.get8() + 108),
            251...254 => @bitCast(-(b0 - 251) * 256 - b.get8() - 108),
            28 => b.get16(),
            29 => b.get32(),
            else => @panic("invalid instruction"),
        };
        // std.log.debug("cffInt() b0 {} result {}", .{ b0, result });
        return result;
    }

    pub fn dictGetInts(b: *Buf, key: u32, outcount: u32, out: [*]u32) void {
        var operands = b.dictGet(key);
        for (0..outcount) |i| {
            if (operands.cursor >= operands.size) break;
            out[i] = operands.cffInt();
        }
    }

    pub fn dictGet(b: *Buf, key: u32) Buf {
        b.seek(0);
        while (b.cursor < b.size) {
            const start = b.cursor;
            while (b.peek8() >= 28) b.cffSkipOperand();
            const end = b.cursor;
            var op: i32 = b.get8();
            if (op == 12) op = @as(i32, b.get8()) | 0x100;
            if (op == key) return b.range(start, end - start);
        }
        return b.range(0, 0);
    }

    fn cffSkipOperand(b: *Buf) void {
        const b0 = b.peek8();
        assert(b0 >= 28);
        if (b0 == 30) {
            b.skip(1);
            while (b.cursor < b.size) {
                const v = b.get8();
                if ((v & 0xF) == 0xF or (v >> 4) == 0xF)
                    break;
            }
        } else {
            _ = b.cffInt();
        }
    }

    pub fn getSubrs(cff_const: Buf, fontdict_const: Buf) Buf {
        var private_loc: [2]u32 = .{ 0, 0 };
        var fontdict = fontdict_const;
        fontdict.dictGetInts(18, 2, &private_loc);
        if (private_loc[1] == 0 or private_loc[0] == 0) return .empty;
        var cff = cff_const;
        var pdict = cff.range(private_loc[1], private_loc[0]);
        var subrsoff: u32 = 0;
        pdict.dictGetInts(19, 1, @ptrCast(&subrsoff));
        if (subrsoff == 0) return .empty;
        cff.seek(private_loc[1] + subrsoff);
        return cff.cffGetIndex();
    }

    fn getSubr(idx_const: Buf, n_const: u32) Buf {
        var idx = idx_const;
        var n = n_const;
        const count = idx.cffIndexCount();
        n +%= if (count >= 33900)
            32768
        else if (count >= 1240)
            1131
        else
            107;
        if (n >= count) return .empty;
        return idx.cffIndexGet(@fromBackingInt(@intCast(n)));
    }
};

pub const CharstringCtx = struct {
    first_x: f32,
    first_y: f32,
    x: f32,
    y: f32,
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

    fn v(ctx: *CharstringCtx, ty: Vertex.Type, x: i32, y: i32, cx: i32, cy: i32, cx1: i32, cy1: i32) !void {
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
            try ctx.v(.vline, @intFromFloat(ctx.first_x), @intFromFloat(ctx.first_y), 0, 0, 0, 0);
    }

    fn rmoveTo(ctx: *CharstringCtx, dx: f32, dy: f32) !void {
        try ctx.closeShape();
        ctx.first_x = ctx.x + dx;
        ctx.x = ctx.first_x;
        ctx.first_y = ctx.y + dy;
        ctx.y = ctx.first_y;
        // std.log.debug("moveTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
        try ctx.v(.vmove, @intFromFloat(ctx.x), @intFromFloat(ctx.y), 0, 0, 0, 0);
    }

    fn rlineTo(ctx: *CharstringCtx, dx: f32, dy: f32) !void {
        ctx.x += dx;
        ctx.y += dy;
        // std.log.debug("lineTo {d:.1},{d:.1}", .{ ctx.x, ctx.y });
        try ctx.v(.vline, @intFromFloat(ctx.x), @intFromFloat(ctx.y), 0, 0, 0, 0);
    }

    fn rccurveTo(ctx: *CharstringCtx, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) !void {
        const cx1 = ctx.x + dx1;
        const cy1 = ctx.y + dy1;
        const cx2 = cx1 + dx2;
        const cy2 = cy1 + dy2;
        ctx.x = cx2 + dx3;
        ctx.y = cy2 + dy3;
        // std.log.debug("curveTo {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}", .{ ctx.x, ctx.y, cx1, cy1, cx2, cy2 });
        try ctx.v(
            .vcubic,
            @intFromFloat(ctx.x),
            @intFromFloat(ctx.y),
            @intFromFloat(cx1),
            @intFromFloat(cy1),
            @intFromFloat(cx2),
            @intFromFloat(cy2),
        );
    }
};

pub fn glyphBox(cff_data: *const CffData, glyph: GlyphIndex) ?BitmapBox {
    var ctx = CharstringCtx.init(.{ .mode = .bounds }, undefined);
    runCharstring(cff_data, glyph, &ctx) catch return null;

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
    var maskbits: u32 = 0;
    var in_header = true;
    var has_subrs = false;
    var clear_stack = false;
    var s: [48]f32 = @splat(0); // stack
    var sp: u32 = 0; // stack pointer
    var subr_buf: [10]Buf = undefined;
    var subr_stack: std.ArrayList(Buf) = .initBuffer(&subr_buf);
    var subrs = cff_data.subrs;
    // this currently ignores the initial width value, which isn't needed if we have hmtx
    var b = cff_data.charstrings.cffIndexGet(glyph);

    while (b.cursor < b.size) {
        var i: u32 = 0;
        clear_stack = true;
        const b0: u16 = b.get8();
        // const tag_name = if (std.meta.intToEnum(Instruction, b0)) |t| @tagName(t) else |_| "other";
        // std.log.debug("{}/{} b0 {s}/{}/0x{x} num_vertices {}", .{ b.cursor, b.size, tag_name, b0, b0, ctx.num_vertices });

        sw: switch (b0) {
            // @TODO implement hinting
            Instruction.hintmask.asInt(), // 0x13
            Instruction.cntrmask.asInt(), // 0x14
            => {
                if (in_header) maskbits += (sp / 2); // implicit "vstem"
                in_header = false;
                b.skip((maskbits + 7) / 8);
            },
            Instruction.hstem.asInt(), // 0x01
            Instruction.vstem.asInt(), // 0x03
            Instruction.hstemhm.asInt(), // 0x12
            Instruction.vstemhm.asInt(), // 0x17
            => {
                maskbits += (sp / 2);
            },
            Instruction.rmoveto.asInt() => { // 0x15
                in_header = false;
                if (sp < 2) return error.RMoveToStack;
                try ctx.rmoveTo(s[sp - 2], s[sp - 1]);
            },
            Instruction.vmoveto.asInt() => { // 0x04
                in_header = false;
                if (sp < 1) return error.VMoveToStack;
                try ctx.rmoveTo(0, s[sp - 1]);
            },
            Instruction.hmoveto.asInt() => { // 0x16
                in_header = false;
                if (sp < 1) return error.HMoveToStack;
                try ctx.rmoveTo(s[sp - 1], 0);
            },
            Instruction.rlineto.asInt() => { // 0x05
                if (sp < 2) return error.RLineToStack;
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
                if (sp < 4) return error.HCurveToStack;
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
                if (sp < 4) return error.HCurveToStack;
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
                if (sp < 6) return error.RCurveToStack;
                while (i + 5 < sp) : (i += 6)
                    try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            },
            Instruction.rcurveline.asInt() => { // 0x18
                if (sp < 8) return error.RCurveLineStack;
                while (i + 5 < sp - 2) : (i += 6)
                    try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
                if (i + 1 >= sp) return error.CurveLineStack;
                try ctx.rlineTo(s[i], s[i + 1]);
            },
            Instruction.rlinecurve.asInt() => { // 0x19
                if (sp < 8) return error.RLineCurveStack;
                while (i + 1 < sp - 6) : (i += 2)
                    try ctx.rlineTo(s[i], s[i + 1]);
                if (i + 5 >= sp) return error.RLineCurveStack;
                try ctx.rccurveTo(s[i], s[i + 1], s[i + 2], s[i + 3], s[i + 4], s[i + 5]);
            },
            Instruction.vvcurveto.asInt(), // 0x1A
            Instruction.hhcurveto.asInt(), // 0x1B
            => {
                if (sp < 4) return error.CurveToStack;
                var f: f32 = 0.0;
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
                        subrs = getGlyphSubrs(cff_data, glyph);
                    has_subrs = true;
                }
                continue :sw Instruction.callgsubr.asInt();
                // FALLTHROUGH
            },
            Instruction.callgsubr.asInt() => { // 0x1D
                sp = std.math.sub(u32, sp, 1) catch return error.CallGSubRStack;
                const v: i32 = @intFromFloat(@trunc(s[sp]));
                subr_stack.appendBounded(b) catch return error.RecursionLimit;
                b = (if (b0 == Instruction.callsubr.asInt()) // 0x0A
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
                try ctx.closeShape();
                return;
            },
            Instruction.twoByteEscape.asInt() => { // 0x0C
                const b1 = b.get8();
                switch (b1) {
                    // @TODO These "flex" implementations ignore the flex-depth and resolution,
                    // and always draw beziers.
                    Instruction.hflex.asInt() => { // 0x22
                        if (sp < 7) return error.HFlexStack;
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
                        if (sp < 13) return error.FlexStack;
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
                        if (sp < 9) return error.HFlex1Stack;
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
                        if (sp < 11) return error.Flex1Stack;
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

                    else => return error.Unimplemented,
                }
            },
            else => {
                if (b0 != 255 and b0 != 28 and b0 < 32)
                    return error.ReservedOperator;

                // push immediate
                const f: f32 = if (b0 == 255)
                    @floatFromInt(@as(i32, @intCast(b.get32() / 0x10000)))
                else blk: {
                    b.cursor -= 1;
                    break :blk @floatFromInt(@as(i16, @truncate(@as(i32, @bitCast(b.cffInt())))));
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

fn getGlyphSubrs(cff_data: *const CffData, glyph: GlyphIndex) Buf {
    var fdselector: u32 = std.math.maxInt(u32);
    var fdselect = cff_data.fdselect;
    // std.log.debug("getGlyphSubrs fdselect {}", .{fdselect});
    fdselect.seek(0);

    const fmt = fdselect.get8();
    if (fmt == 0) {
        // untested
        fdselect.skip(@backingInt(glyph));
        fdselector = fdselect.get8();
    } else if (fmt == 3) {
        const nranges = fdselect.get16();
        var start = fdselect.get16();
        for (0..nranges) |_| {
            const v = fdselect.get8();
            const end = fdselect.get16();
            const glyph_int = @backingInt(glyph);
            if (glyph_int >= start and glyph_int < end) {
                fdselector = v;
                break;
            }
            start = end;
        }
    }
    // what was this line? it does nothing. why was it in the original c code?
    // if (fdselector == -1) new_buf(NULL, 0);
    return cff_data.cff.getSubrs(cff_data.fontdicts.cffIndexGet(@fromBackingInt(@intCast(fdselector))));
}
