//! Shared glyph identifiers and outline geometry.

pub const GlyphIndex = enum(u16) {
    notdef = 0,
    _,
};

pub const Vertex = struct {
    x: i16,
    y: i16,
    cx: i16,
    cy: i16,
    cx1: i16,
    cy1: i16,
    type: Type,

    pub const Type = enum(u8) {
        vmove = 1,
        vline = 2,
        vcurve = 3,
        vcubic = 4,
        _,
    };

    pub fn set(v: *Vertex, ty: Type, x: i32, y: i32, cx: i32, cy: i32) void {
        v.type = ty;
        v.x = @intCast(x);
        v.y = @intCast(y);
        v.cx = @intCast(cx);
        v.cy = @intCast(cy);
    }
};

pub const BitmapBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    /// e.g. space character
    pub const empty: BitmapBox = .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 0,
        .y1 = 0,
    };
};
