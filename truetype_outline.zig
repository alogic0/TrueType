//! Bounded loca/glyf decoding and composite outline assembly.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Reader = @import("reader.zig");
const Limits = @import("limits.zig");
const GlyphIndex = @import("glyph.zig").GlyphIndex;
const Vertex = @import("glyph.zig").Vertex;
const BitmapBox = @import("glyph.zig").BitmapBox;
const Font = @This();

loca: Reader,
glyf: Reader,
index_to_loc_format: u16,
glyphs_len: u32,
limits: Limits,

pub const Error = Reader.Error || Allocator.Error || Limits.Error || error{
    InvalidCompositeGlyph,
    RecursionLimit,
    CoordinateOutOfRange,
};

pub fn box(tt: *const Font, glyph: GlyphIndex) Error!?BitmapBox {
    const source = try tt.data(glyph);
    if (source.bytes.len == 0) return null;
    return .{
        .x0 = try source.read(i16, 2),
        .y0 = try source.read(i16, 4),
        .x1 = try source.read(i16, 6),
        .y1 = try source.read(i16, 8),
    };
}

const OutlinePoint = struct {
    x: f32,
    y: f32,

    fn transform(p: OutlinePoint, m: [6]f32) OutlinePoint {
        return .{ .x = m[0] * p.x + m[2] * p.y + m[4], .y = m[1] * p.x + m[3] * p.y + m[5] };
    }
};

pub fn shape(tt: *const Font, gpa: Allocator, glyph: GlyphIndex) Error![]Vertex {
    var budget: OutlineBudget = .{ .vertices = tt.limits.max_outline_vertices, .components = tt.limits.max_components };
    return shapeInner(tt, gpa, glyph, null, 0, &budget);
}

const OutlineBudget = struct { vertices: u32, components: u32 };

fn shapeInner(
    tt: *const Font,
    gpa: Allocator,
    glyph: GlyphIndex,
    outline_points: ?*ArrayList(OutlinePoint),
    depth: u32,
    budget: *OutlineBudget,
) Error![]Vertex {
    try Limits.consume(&budget.components, 1);
    if (depth >= 64) return error.RecursionLimit;
    if (@backingInt(glyph) >= tt.glyphs_len) return error.InvalidCompositeGlyph;
    const source = try data(tt, glyph);
    const bytes = source.bytes;
    if (bytes.len == 0) return &.{};
    const g: u32 = 0;
    var vertices: ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    const n_contours_signed = try source.read(i16, 0);
    if (n_contours_signed < -1) return error.InvalidFontData;

    if (n_contours_signed > 0) {
        const n_contours: u16 = @intCast(n_contours_signed);
        const contours_end_pts: u32 = g + 10;
        _ = try source.records(contours_end_pts, n_contours, 2);
        var previous: ?u16 = null;
        for (0..n_contours) |contour| {
            const end = try source.read(u16, contours_end_pts + contour * 2);
            if (previous) |last| if (end <= last) return error.InvalidFontData;
            previous = end;
        }
        const instruction_offset: u32 = contours_end_pts + @as(u32, n_contours) * 2;
        const instructions = try source.read(u16, instruction_offset);
        _ = try source.span(instruction_offset + 2, instructions);
        var points: u32 = instruction_offset + 2 + instructions;
        const n: u32 = @as(u32, previous.?) + 1;

        // A loose bound on how many vertices we might need.
        const m: u32 = n + 2 * n_contours;
        try Limits.consume(&budget.vertices, m);
        try vertices.resize(gpa, m);

        var next_move: i32 = 0;
        var flagcount: u8 = 0;

        // in first pass, we load uninterpreted data into the allocated array
        // above, shifted to the end of the array so we won't overwrite it when
        // we create our final data starting from the front

        // Starting offset for uninterpreted data, regardless of how m ends up being calculated.
        const off: u32 = m - n;

        // first load flags
        {
            var flags: u8 = 0;
            for (0..n) |i| {
                if (flagcount == 0) {
                    flags = try source.read(u8, points);
                    points += 1;
                    if ((flags & 8) != 0) {
                        flagcount = try source.read(u8, points);
                        if (flagcount >= n - i) return error.InvalidFontData;
                        points += 1;
                    }
                } else {
                    flagcount -= 1;
                }
                vertices.items[off + i].type = @fromBackingInt(@intCast(flags));
            }
        }

        // now load x coordinates
        var x: i32 = 0;
        for (0..n) |i| {
            const flags = @backingInt(vertices.items[off + i].type);
            if ((flags & 2) != 0) {
                const dx: i16 = try source.read(u8, points);
                points += 1;
                x += if ((flags & 16) != 0) dx else -dx;
            } else {
                if ((flags & 16) == 0) {
                    x += try source.read(i16, points);
                    points += 2;
                }
            }
            vertices.items[off + i].x = std.math.cast(i16, x) orelse return error.CoordinateOutOfRange;
        }

        // now load y coordinates
        var y: i32 = 0;
        for (0..n) |i| {
            const flags = @backingInt(vertices.items[off + i].type);
            if ((flags & 4) != 0) {
                const dy: i16 = try source.read(u8, points);
                points += 1;
                y += if ((flags & 32) != 0) dy else -dy;
            } else {
                if ((flags & 32) == 0) {
                    y += try source.read(i16, points);
                    points += 2;
                }
            }
            vertices.items[off + i].y = std.math.cast(i16, y) orelse return error.CoordinateOutOfRange;
        }

        // Keep the original on- and off-curve point order for composite
        // attachments, before inserting implied points or closing contours.
        if (outline_points) |out| {
            const raw = try out.addManyAsSlice(gpa, n);
            for (raw, vertices.items[off..][0..n]) |*point, vertex| {
                point.* = .{ .x = @floatFromInt(vertex.x), .y = @floatFromInt(vertex.y) };
            }
        }

        // now convert them to our format
        var num_vertices: u32 = 0;
        var sx: i32 = 0;
        var sy: i32 = 0;
        var cx: i32 = 0;
        var cy: i32 = 0;
        var scx: i32 = 0;
        var scy: i32 = 0;
        var i: u32 = 0;
        var j: u32 = 0;
        var start_off: bool = false;
        var was_off: bool = false;
        while (i < n) : (i += 1) {
            const flags = @backingInt(vertices.items[off + i].type);
            x = @intCast(vertices.items[off + i].x);
            y = @intCast(vertices.items[off + i].y);

            if (next_move == i) {
                if (i != 0)
                    num_vertices = closeShape(vertices.items, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);

                // now start the new one
                start_off = (flags & 1) == 0;
                if (start_off) {
                    // if we start off with an off-curve point, then when we need to find a point on the curve
                    // where we can start, and we need to save some state for when we wraparound.
                    scx = x;
                    scy = y;
                    const contour_end = try source.read(u16, contours_end_pts + j * 2);
                    if (i == contour_end) {
                        // A one-point off-curve contour must not read the next contour.
                        sx = x;
                        sy = y;
                    } else if ((@backingInt(vertices.items[off + i + 1].type) & 1) == 0) {
                        // next point is also a curve point, so interpolate an on-point curve
                        sx = (x + vertices.items[off + i + 1].x) >> 1;
                        sy = (y + vertices.items[off + i + 1].y) >> 1;
                    } else {
                        // otherwise just use the next point as our start point
                        sx = vertices.items[off + i + 1].x;
                        sy = vertices.items[off + i + 1].y;
                        i += 1; // we're using point i+1 as the starting point, so skip it
                    }
                } else {
                    sx = x;
                    sy = y;
                }
                vertices.items[num_vertices].set(.vmove, sx, sy, 0, 0);
                num_vertices += 1;
                was_off = false;
                next_move = 1 + try source.read(u16, contours_end_pts + j * 2);
                j += 1;
            } else {
                if ((flags & 1) == 0) { // if it's a curve
                    if (was_off) {
                        // two off-curve control points in a row means interpolate an on-curve midpoint
                        vertices.items[num_vertices].set(.vcurve, (cx + x) >> 1, (cy + y) >> 1, cx, cy);
                        num_vertices += 1;
                    }
                    cx = x;
                    cy = y;
                    was_off = true;
                } else {
                    if (was_off)
                        vertices.items[num_vertices].set(.vcurve, x, y, cx, cy)
                    else
                        vertices.items[num_vertices].set(.vline, x, y, 0, 0);
                    num_vertices += 1;
                    was_off = false;
                }
            }
        }
        num_vertices = closeShape(vertices.items, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);
        vertices.shrinkRetainingCapacity(num_vertices);
    } else if (n_contours_signed < 0) {
        // Point numbers span all previously incorporated components.
        var parent_points: ArrayList(OutlinePoint) = .empty;
        defer parent_points.deinit(gpa);
        var more = true;
        var have_instructions = false;
        var comp = g + 10;
        while (more) {
            var mtx: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };

            const flags = try readCursor(u16, bytes, &comp);
            if (@popCount(flags & 0xc8) > 1 or flags & 0x1800 == 0x1800) return error.InvalidCompositeGlyph;
            have_instructions = have_instructions or flags & 0x100 != 0;
            const gidx: GlyphIndex = @fromBackingInt(@intCast(try readCursor(u16, bytes, &comp)));

            var parent_point: u16 = 0;
            var child_point: u16 = 0;
            const xy_values = (flags & 2) != 0;
            if (xy_values) { // XY values
                if ((flags & 1) != 0) { // shorts
                    mtx[4] = @floatFromInt(try readCursor(i16, bytes, &comp));
                    mtx[5] = @floatFromInt(try readCursor(i16, bytes, &comp));
                } else {
                    mtx[4] = @floatFromInt(try readCursor(i8, bytes, &comp));
                    mtx[5] = @floatFromInt(try readCursor(i8, bytes, &comp));
                }
            } else {
                // Point indices are unsigned, unlike XY offsets.
                parent_point = if (flags & 1 != 0) try readCursor(u16, bytes, &comp) else try readCursor(u8, bytes, &comp);
                child_point = if (flags & 1 != 0) try readCursor(u16, bytes, &comp) else try readCursor(u8, bytes, &comp);
            }
            if ((flags & (1 << 3)) != 0) { // WE_HAVE_A_SCALE
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = mtx[0];
            } else if ((flags & (1 << 6)) != 0) { // WE_HAVE_AN_X_AND_YSCALE
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
            } else if ((flags & (1 << 7)) != 0) { // WE_HAVE_A_TWO_BY_TWO
                mtx[0] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[1] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[2] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
                mtx[3] = @as(f32, @floatFromInt(try readCursor(i16, bytes, &comp))) / 16384.0;
            }

            var child_points: ArrayList(OutlinePoint) = .empty;
            defer child_points.deinit(gpa);
            const comp_verts = try shapeInner(tt, gpa, gidx, &child_points, depth + 1, budget);
            defer gpa.free(comp_verts);

            if (xy_values) {
                // The default offset is in parent coordinates. Only an explicit
                // SCALED_COMPONENT_OFFSET applies the matrix to the offset too.
                if (flags & 0x1800 == 0x0800) {
                    const dx = mtx[4];
                    const dy = mtx[5];
                    mtx[4] = mtx[0] * dx + mtx[2] * dy;
                    mtx[5] = mtx[1] * dx + mtx[3] * dy;
                }
            } else {
                if (parent_point >= parent_points.items.len or child_point >= child_points.items.len)
                    return error.InvalidCompositeGlyph;
                const anchor = child_points.items[child_point].transform(mtx);
                mtx[4] = parent_points.items[parent_point].x - anchor.x;
                mtx[5] = parent_points.items[parent_point].y - anchor.y;
            }

            for (comp_verts) |*v| {
                const end = (OutlinePoint{ .x = @floatFromInt(v.x), .y = @floatFromInt(v.y) }).transform(mtx);
                const control = (OutlinePoint{ .x = @floatFromInt(v.cx), .y = @floatFromInt(v.cy) }).transform(mtx);
                v.x = try vertexCoordinate(end.x);
                v.y = try vertexCoordinate(end.y);
                if (v.type == .vcurve) {
                    v.cx = try vertexCoordinate(control.x);
                    v.cy = try vertexCoordinate(control.y);
                }
            }
            try Limits.consume(&budget.vertices, comp_verts.len + child_points.items.len);
            try vertices.appendSlice(gpa, comp_verts);
            for (child_points.items) |point| try parent_points.append(gpa, point.transform(mtx));
            more = (flags & (1 << 5)) != 0;
        }
        if (have_instructions) {
            const length = try readCursor(u16, bytes, &comp);
            _ = try source.span(comp, length);
        }
        if (outline_points) |out| try out.appendSlice(gpa, parent_points.items);
    }
    return vertices.toOwnedSlice(gpa);
}

pub fn data(tt: *const Font, glyph: GlyphIndex) Error!Reader {
    const index: usize = @backingInt(glyph);
    if (index >= tt.glyphs_len) return error.InvalidCompositeGlyph;
    if (tt.index_to_loc_format > 1) return error.InvalidFontData;
    const loca = tt.loca;
    const glyf = tt.glyf;
    const start: u32, const end: u32 = if (tt.index_to_loc_format == 0) .{
        @as(u32, try loca.read(u16, index * 2)) * 2,
        @as(u32, try loca.read(u16, index * 2 + 2)) * 2,
    } else .{
        try loca.read(u32, index * 4),
        try loca.read(u32, index * 4 + 4),
    };
    if (end < start) return error.InvalidFontData;
    const source: Reader = .{ .bytes = try glyf.span(start, end - start) };
    if (source.bytes.len != 0) {
        _ = try source.span(0, 10);
        if (try source.read(i16, 2) > try source.read(i16, 6) or
            try source.read(i16, 4) > try source.read(i16, 8)) return error.InvalidFontData;
    }
    return source;
}

fn vertexCoordinate(value: f32) error{CoordinateOutOfRange}!i16 {
    const rounded = @trunc(value);
    if (!std.math.isFinite(rounded) or rounded < -32768 or rounded > 32767) return error.CoordinateOutOfRange;
    return @intFromFloat(rounded);
}

fn closeShape(
    vertices: []Vertex,
    vertices_len_start: u32,
    was_off: bool,
    start_off: bool,
    sx: i32,
    sy: i32,
    scx: i32,
    scy: i32,
    cx: i32,
    cy: i32,
) u32 {
    var vertices_len = vertices_len_start;
    if (start_off) {
        if (was_off) {
            vertices[vertices_len].set(.vcurve, (cx + scx) >> 1, (cy + scy) >> 1, cx, cy);
            vertices_len += 1;
        }
        vertices[vertices_len].set(.vcurve, sx, sy, scx, scy);
        vertices_len += 1;
    } else {
        if (was_off) {
            vertices[vertices_len].set(.vcurve, sx, sy, cx, cy);
            vertices_len += 1;
        } else {
            vertices[vertices_len].set(.vline, sx, sy, 0, 0);
            vertices_len += 1;
        }
    }
    return vertices_len;
}

fn readCursor(comptime I: type, bytes: []const u8, cursor: *u32) Reader.Error!I {
    const start = cursor.*;
    const result = try (Reader{ .bytes = bytes }).read(I, start);
    cursor.* = start + @sizeOf(I);
    return result;
}
