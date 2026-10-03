//! Converts glyph outlines into anti-aliased bitmaps.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArrayList = std.ArrayListUnmanaged;
const Vertex = @import("glyph.zig").Vertex;

/// Reusable temporary storage for glyph decoding and rasterization. Use one
/// workspace per concurrent render. Rendering resets it while retaining capacity;
/// deinit or release frees retained memory. Output pixels must live elsewhere.
pub const Workspace = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) Workspace {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(workspace: *Workspace) void {
        workspace.arena.deinit();
        workspace.* = undefined;
    }

    /// Releases cached storage while leaving the workspace ready for reuse.
    pub fn release(workspace: *Workspace) void {
        _ = workspace.arena.reset(.free_all);
    }

    /// Temporary allocations are invalidated when rendering returns.
    pub fn allocator(workspace: *Workspace) Allocator {
        return workspace.arena.allocator();
    }

    pub fn reset(workspace: *Workspace) void {
        // Retaining capacity is an optimization. A failed consolidation still
        // leaves an empty, usable arena and must not fail a completed render.
        _ = workspace.arena.reset(.retain_capacity);
    }
};

pub const Bitmap = struct {
    w: u32,
    h: u32,
    stride: u32,
    pixels: []u8,
};

pub fn rasterize(
    gpa: Allocator,
    result: *Bitmap,
    flatness_in_pixels: f32,
    vertices: []Vertex,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
    off_x: i32,
    off_y: i32,
    invert: bool,
) Allocator.Error!void {
    const scale = @min(scale_x, scale_y);
    var windings = try flattenCurves(gpa, vertices, flatness_in_pixels / scale);
    defer windings.deinit(gpa);
    try rasterizeInner(gpa, result, windings.points, windings.contour_lengths, scale_x, scale_y, shift_x, shift_y, off_x, off_y, invert);
}

const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    invert: bool,

    const Sort = struct {
        fn lessThan(ctx: Sort, a: Edge, b: Edge) bool {
            _ = ctx;
            return a.y0 < b.y0;
        }
    };
};

fn rasterizeInner(
    gpa: Allocator,
    result: *Bitmap,
    pts: []Point,
    wcount: []u32,
    scale_x: f32,
    scale_y: f32,
    shift_x: f32,
    shift_y: f32,
    off_x: i32,
    off_y: i32,
    invert: bool,
) Allocator.Error!void {
    const y_scale_inv: f32 = if (invert) -scale_y else scale_y;

    // now we have to blow out the windings into explicit edge lists
    const edge_alloc_n = n: {
        var n: u32 = 1; // Add an extra one as a sentinel.
        for (wcount) |elem| n += elem;
        break :n n;
    };

    const e = try gpa.alloc(Edge, edge_alloc_n);
    defer gpa.free(e);

    var n: u32 = 0;
    var m: u32 = 0;
    for (wcount) |wcount_elem| {
        const p: []Point = pts[m..];
        m += wcount_elem;
        var j: u32 = wcount_elem - 1;
        var k: u32 = 0;
        while (k < wcount_elem) : ({
            j = k;
            k += 1;
        }) {
            var a = k;
            var b = j;
            // skip the edge if horizontal
            if (p[j].y == p[k].y)
                continue;
            // add edge from j to k to the list
            e[n].invert = false;
            if (if (invert) p[j].y > p[k].y else p[j].y < p[k].y) {
                e[n].invert = true;
                a = j;
                b = k;
            }
            e[n].x0 = p[a].x * scale_x + shift_x;
            e[n].y0 = (p[a].y * y_scale_inv + shift_y);
            e[n].x1 = p[b].x * scale_x + shift_x;
            e[n].y1 = (p[b].y * y_scale_inv + shift_y);
            n += 1;
        }
    }
    // now sort the edges by their highest point (should snap to integer, and then by x)
    std.mem.sortUnstable(Edge, e[0..n], Edge.Sort{}, Edge.Sort.lessThan);

    // now, traverse the scanlines and find the intersections on each scanline, use xor winding rule
    try rasterizeSortedEdges(gpa, result, e[0 .. n + 1], off_x, off_y);
}

const Point = struct {
    x: f32,
    y: f32,
};

const FlattenedCurves = struct {
    points: []Point,
    contour_lengths: []u32,

    const empty: FlattenedCurves = .{
        .points = &.{},
        .contour_lengths = &.{},
    };

    fn deinit(fc: *FlattenedCurves, gpa: Allocator) void {
        gpa.free(fc.points);
        gpa.free(fc.contour_lengths);
        fc.* = undefined;
    }
};

fn flattenCurves(
    gpa: Allocator,
    vertices: []const Vertex,
    objspace_flatness: f32,
) error{OutOfMemory}!FlattenedCurves {
    var points: ArrayList(Point) = .empty;
    defer points.deinit(gpa);
    var contour_lengths: ArrayList(u32) = .empty;
    defer contour_lengths.deinit(gpa);

    const objspace_flatness_squared = objspace_flatness * objspace_flatness;

    var start: u32 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    for (vertices) |v| {
        sw: switch (v.type) {
            .vmove => {
                if (points.items.len > 0) {
                    try contour_lengths.append(gpa, @intCast(points.items.len - start));
                    start = @intCast(points.items.len);
                }

                continue :sw .vline;
            },
            .vline => {
                x = @floatFromInt(v.x);
                y = @floatFromInt(v.y);
                try points.append(gpa, .{ .x = x, .y = y });
            },
            .vcurve => {
                try tesselateCurve(
                    gpa,
                    &points,
                    x,
                    y,
                    @floatFromInt(v.cx),
                    @floatFromInt(v.cy),
                    @floatFromInt(v.x),
                    @floatFromInt(v.y),
                    objspace_flatness_squared,
                    0,
                );
                x = @floatFromInt(v.x);
                y = @floatFromInt(v.y);
            },
            .vcubic => {
                try tesselateCubic(
                    gpa,
                    &points,
                    x,
                    y,
                    @floatFromInt(v.cx),
                    @floatFromInt(v.cy),
                    @floatFromInt(v.cx1),
                    @floatFromInt(v.cy1),
                    @floatFromInt(v.x),
                    @floatFromInt(v.y),
                    objspace_flatness_squared,
                    0,
                );
                x = @floatFromInt(v.x);
                y = @floatFromInt(v.y);
            },
            _ => continue,
        }
    }
    try contour_lengths.append(gpa, @intCast(points.items.len - start));

    const owned_points = try points.toOwnedSlice(gpa);
    errdefer gpa.free(owned_points);
    return .{
        .points = owned_points,
        .contour_lengths = try contour_lengths.toOwnedSlice(gpa),
    };
}

/// tessellate until threshold p is happy... @TODO warped to compensate for non-linear stretching
fn tesselateCurve(
    gpa: Allocator,
    points: *ArrayList(Point),
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    objspace_flatness_squared: f32,
    n: u32,
) Allocator.Error!void {
    // midpoint
    const mx: f32 = (x0 + 2 * x1 + x2) / 4;
    const my: f32 = (y0 + 2 * y1 + y2) / 4;
    // versus directly drawn line
    const dx: f32 = (x0 + x2) / 2 - mx;
    const dy: f32 = (y0 + y2) / 2 - my;
    if (n > 16) // 65536 segments on one curve better be enough!
        return;
    if (dx * dx + dy * dy > objspace_flatness_squared) { // half-pixel error allowed... need to be smaller if AA
        try tesselateCurve(gpa, points, x0, y0, (x0 + x1) / 2.0, (y0 + y1) / 2.0, mx, my, objspace_flatness_squared, n + 1);
        try tesselateCurve(gpa, points, mx, my, (x1 + x2) / 2.0, (y1 + y2) / 2.0, x2, y2, objspace_flatness_squared, n + 1);
    } else {
        try points.append(gpa, .{ .x = x2, .y = y2 });
    }
}

fn tesselateCubic(
    gpa: Allocator,
    points: *ArrayList(Point),
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    objspace_flatness_squared: f32,
    n: u32,
) Allocator.Error!void {
    // According to Dougall Johnson, this "flatness" calculation is just
    // made-up nonsense that seems to work well enough.
    const dx0 = x1 - x0;
    const dy0 = y1 - y0;
    const dx1 = x2 - x1;
    const dy1 = y2 - y1;
    const dx2 = x3 - x2;
    const dy2 = y3 - y2;
    const dx = x3 - x0;
    const dy = y3 - y0;
    const longlen = @sqrt(dx0 * dx0 + dy0 * dy0) + @sqrt(dx1 * dx1 + dy1 * dy1) + @sqrt(dx2 * dx2 + dy2 * dy2);
    const shortlen = @sqrt(dx * dx + dy * dy);
    const flatness_squared = longlen * longlen - shortlen * shortlen;

    if (n > 16) // 65536 segments on one curve better be enough!
        return;

    if (flatness_squared > objspace_flatness_squared) {
        const x01 = (x0 + x1) / 2;
        const y01 = (y0 + y1) / 2;
        const x12 = (x1 + x2) / 2;
        const y12 = (y1 + y2) / 2;
        const x23 = (x2 + x3) / 2;
        const y23 = (y2 + y3) / 2;

        const xa = (x01 + x12) / 2;
        const ya = (y01 + y12) / 2;
        const xb = (x12 + x23) / 2;
        const yb = (y12 + y23) / 2;

        const mx = (xa + xb) / 2;
        const my = (ya + yb) / 2;

        try tesselateCubic(gpa, points, x0, y0, x01, y01, xa, ya, mx, my, objspace_flatness_squared, n + 1);
        try tesselateCubic(gpa, points, mx, my, xb, yb, x23, y23, x3, y3, objspace_flatness_squared, n + 1);
    } else {
        try points.append(gpa, .{ .x = x3, .y = y3 });
    }
}

fn sizedTrapezoidArea(height: f32, top_width: f32, bottom_width: f32) f32 {
    assert(top_width >= 0);
    assert(bottom_width >= 0);
    return (top_width + bottom_width) / 2.0 * height;
}

fn positionTrapezoidArea(height: f32, tx0: f32, tx1: f32, bx0: f32, bx1: f32) f32 {
    return sizedTrapezoidArea(height, tx1 - tx0, bx1 - bx0);
}

fn sizedTriangleArea(height: f32, width: f32) f32 {
    return height * width / 2;
}

const ActiveEdge = struct {
    next: ?*ActiveEdge,
    fx: f32,
    fdx: f32,
    fdy: f32,
    direction: f32,
    sy: f32,
    ey: f32,
};

/// Directly anti-alias rasterize edges without supersampling.
fn rasterizeSortedEdges(
    gpa: Allocator,
    result: *Bitmap,
    edges: []Edge,
    off_x: i32,
    off_y: i32,
) Allocator.Error!void {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var active: ?*ActiveEdge = null;

    const scanline_buffer = try arena.alloc(f32, result.w * 2 + 1);
    const scanline = scanline_buffer[0..result.w];
    const scanline2 = scanline_buffer[result.w..][0 .. result.w + 1];

    var y: i32 = off_y;
    edges[edges.len - 1].y0 = @floatFromInt((off_y + @as(i32, @intCast(result.h))) + 1);

    var j: u32 = 0;
    var e: u32 = 0;
    while (j < result.h) {
        // find center of pixel for this scanline
        const scan_y_top: f32 = @floatFromInt(y);
        const scan_y_bottom: f32 = @floatFromInt(y + 1);
        var step: *?*ActiveEdge = &active;

        @memset(scanline, 0);
        @memset(scanline2, 0);

        // update all active edges;
        // remove all active edges that terminate before the top of this scanline
        while (step.*) |z| {
            if (z.ey <= scan_y_top) {
                step.* = z.next; // delete from list
                assert(z.direction != 0);
                z.direction = 0;
                arena.destroy(z);
            } else {
                step = &z.next; // advance through list
            }
        }

        // insert all edges that start before the bottom of this scanline
        while (edges[e].y0 <= scan_y_bottom) {
            if (edges[e].y0 != edges[e].y1) {
                const z: *ActiveEdge = try newActive(arena, edges[e], off_x, scan_y_top);
                if (j == 0 and off_y != 0) {
                    z.ey = @max(z.ey, scan_y_top);
                }
                // If we get really unlucky a tiny bit of an edge can be
                // out of bounds.
                assert(z.ey >= scan_y_top);

                // Insert at front.
                z.next = active;
                active = z;
            }
            e += 1;
        }

        if (active) |a| fillActiveEdges(scanline, scanline2, result.w, a, scan_y_top);

        {
            var sum: f32 = 0;
            for (scanline, scanline2[0..result.w], result.pixels[j * result.stride ..][0..result.w]) |s, s2, *p| {
                sum += s2;
                p.* = @intFromFloat(@min(@abs(s + sum) * 255 + 0.5, 255));
            }
        }
        // advance all the edges
        step = &active;
        while (step.*) |z| {
            z.fx += z.fdx; // advance to position for current scanline
            step = &z.next; // advance through list
        }

        y += 1;
        j += 1;
    }
}

fn newActive(arena: Allocator, e: Edge, off_x: i32, start_point: f32) Allocator.Error!*ActiveEdge {
    const z = try arena.create(ActiveEdge);
    const dxdy: f32 = (e.x1 - e.x0) / (e.y1 - e.y0);
    z.* = .{
        .fdx = dxdy,
        .fdy = if (dxdy != 0.0) (1.0 / dxdy) else 0.0,
        .fx = (e.x0 + dxdy * (start_point - e.y0)) - @as(f32, @floatFromInt(off_x)),
        .direction = if (e.invert) 1.0 else -1.0,
        .sy = e.y0,
        .ey = e.y1,
        .next = null,
    };
    return z;
}

fn fillActiveEdges(scanline: []f32, scanline_fill: []f32, len: u32, start_edge: *ActiveEdge, y_top: f32) void {
    const y_bottom: f32 = y_top + 1;
    var opt_e: ?*ActiveEdge = start_edge;
    while (opt_e) |e| : (opt_e = e.next) {
        // brute force every pixel

        // compute intersection points with top & bottom
        assert(e.ey >= y_top);

        if (e.fdx == 0) {
            const x0 = e.fx;
            if (x0 < @as(f32, @floatFromInt(len))) {
                if (x0 >= 0) {
                    handleClippedEdge(scanline, @intFromFloat(x0), e, x0, y_top, x0, y_bottom);
                    handleClippedEdge(scanline_fill, @as(u32, @intFromFloat(x0)) + 1, e, x0, y_top, x0, y_bottom);
                } else {
                    handleClippedEdge(scanline_fill, 0, e, x0, y_top, x0, y_bottom);
                }
            }
        } else {
            var x0: f32 = e.fx;
            var dx: f32 = e.fdx;
            var xb: f32 = x0 + dx;
            var dy: f32 = e.fdy;
            assert(e.sy <= y_bottom);
            assert(e.ey >= y_top);

            // Compute endpoints of line segment clipped to this scanline (if the
            // line segment starts on this scanline. x0 is the intersection of the
            // line with y_top, but that may be off the line segment.
            var x_top: f32, var sy0: f32 = if (e.sy > y_top) .{
                x0 + dx * (e.sy - y_top),
                e.sy,
            } else .{
                x0,
                y_top,
            };

            var x_bottom: f32, var sy1: f32 = if (e.ey < y_bottom) .{
                x0 + dx * (e.ey - y_top),
                e.ey,
            } else .{
                xb,
                y_bottom,
            };

            if (x_top >= 0 and x_bottom >= 0 and
                x_top < @as(f32, @floatFromInt(len)) and x_bottom < @as(f32, @floatFromInt(len)))
            {
                // from here on, we don't have to range check x values

                if (@trunc(x_top) == @trunc(x_bottom)) {
                    // simple case, only spans one pixel
                    const x: u32 = @intFromFloat(x_top);
                    const height: f32 = (sy1 - sy0) * e.direction;
                    assert(x < len);
                    scanline[x] += positionTrapezoidArea(height, x_top, @floatFromInt(x + 1), x_bottom, @floatFromInt(x + 1));
                    scanline_fill[x + 1] += height; // everything right of this pixel is filled
                } else {
                    // covers 2+ pixels
                    if (x_top > x_bottom) {
                        // flip scanline vertically; signed area is the same
                        sy0 = y_bottom - (sy0 - y_top);
                        sy1 = y_bottom - (sy1 - y_top);
                        std.mem.swap(f32, &sy0, &sy1);
                        std.mem.swap(f32, &x_bottom, &x_top);
                        dx = -dx;
                        dy = -dy;
                        std.mem.swap(f32, &x0, &xb);
                    }
                    assert(dy >= 0);
                    assert(dx >= 0);

                    const x1: u32 = @intFromFloat(x_top);
                    const x2: u32 = @intFromFloat(x_bottom);
                    const x1p1f: f32 = @floatFromInt(x1 + 1);
                    const x2f: f32 = @floatFromInt(x2);
                    // compute intersection with y axis at x1+1
                    var y_crossing: f32 = y_top + dy * (x1p1f - x0);

                    // compute intersection with y axis at x2
                    var y_final: f32 = y_top + dy * (x2f - x0);

                    //           x1    x_top                            x2    x_bottom
                    //     y_top  +------|-----+------------+------------+--------|---+------------+
                    //            |            |            |            |            |            |
                    //            |            |            |            |            |            |
                    //       sy0  |      Txxxxx|............|............|............|............|
                    // y_crossing |            *xxxxx.......|............|............|............|
                    //            |            |     xxxxx..|............|............|............|
                    //            |            |     /-   xx*xxxx........|............|............|
                    //            |            | dy <       |    xxxxxx..|............|............|
                    //   y_final  |            |     \-     |          xx*xxx.........|............|
                    //       sy1  |            |            |            |   xxxxxB...|............|
                    //            |            |            |            |            |            |
                    //            |            |            |            |            |            |
                    //  y_bottom  +------------+------------+------------+------------+------------+
                    //
                    // goal is to measure the area covered by '.' in each pixel

                    // if x2 is right at the right edge of x1, y_crossing can blow up, github #1057
                    // @TODO: maybe test against sy1 rather than y_bottom?
                    if (y_crossing > y_bottom)
                        y_crossing = y_bottom;

                    const sign: f32 = e.direction;

                    // area of the rectangle covered from sy0..y_crossing
                    var area: f32 = sign * (y_crossing - sy0);

                    // area of the triangle (x_top,sy0), (x1+1,sy0), (x1+1,y_crossing)
                    scanline[x1] += sizedTriangleArea(area, x1p1f - x_top);

                    // check if final y_crossing is blown up; no test case for this
                    if (y_final > y_bottom) {
                        y_final = y_bottom;
                        dy = (y_final - y_crossing) / (x2f - x1p1f); // if denom=0, y_final = y_crossing, so y_final <= y_bottom
                    }

                    // in second pixel, area covered by line segment found in first pixel
                    // is always a rectangle 1 wide * the height of that line segment; this
                    // is exactly what the variable 'area' stores. it also gets a contribution
                    // from the line segment within it. the THIRD pixel will get the first
                    // pixel's rectangle contribution, the second pixel's rectangle contribution,
                    // and its own contribution. the 'own contribution' is the same in every pixel except
                    // the leftmost and rightmost, a trapezoid that slides down in each pixel.
                    // the second pixel's contribution to the third pixel will be the
                    // rectangle 1 wide times the height change in the second pixel, which is dy.

                    const step: f32 = sign * dy * 1; // dy is dy/dx, change in y for every 1 change in x,
                    // which multiplied by 1-pixel-width is how much pixel area changes for each step in x
                    // so the area advances by 'step' every time

                    for (scanline[x1 + 1 .. x2]) |*s| {
                        s.* += area + step / 2; // area of trapezoid is 1*step/2
                        area += step;
                    }
                    assert(@abs(area) <= 1.01); // accumulated error from area += step unless we round step down
                    assert(sy1 > y_final - 0.01);

                    // area covered in the last pixel is the rectangle from all the pixels to the left,
                    // plus the trapezoid filled by the line segment in this pixel all the way to the right edge
                    scanline[x2] += area + sign * positionTrapezoidArea(sy1 - y_final, x2f, x2f + 1.0, x_bottom, x2f + 1.0);

                    // the rest of the line is filled based on the total height of the line segment in this pixel
                    scanline_fill[x2 + 1] += sign * (sy1 - sy0);
                }
            } else {
                // if edge goes outside of box we're drawing, we require
                // clipping logic. since this does not match the intended use
                // of this library, we use a different, very slow brute
                // force implementation
                // note though that this does happen some of the time because
                // x_top and x_bottom can be extrapolated at the top & bottom of
                // the shape and actually lie outside the bounding box
                for (0..len) |x_usize| {
                    const x: u32 = @intCast(x_usize);
                    // cases:
                    //
                    // there can be up to two intersections with the pixel. any intersection
                    // with left or right edges can be handled by splitting into two (or three)
                    // regions. intersections with top & bottom do not necessitate case-wise logic.
                    //
                    // the old way of doing this found the intersections with the left & right edges,
                    // then used some simple logic to produce up to three segments in sorted order
                    // from top-to-bottom. however, this had a problem: if an x edge was epsilon
                    // across the x border, then the corresponding y position might not be distinct
                    // from the other y segment, and it might ignored as an empty segment. to avoid
                    // that, we need to explicitly produce segments based on x positions.

                    // rename variables to clearly-defined pairs
                    const y0: f32 = y_top;
                    const x1: f32 = @floatFromInt(x);
                    const x2: f32 = @floatFromInt(x + 1);
                    const x3: f32 = xb;
                    const y3: f32 = y_bottom;

                    // x = e.x + e.dx * (y-y_top)
                    // (y-y_top) = (x - e.x) / e.dx
                    // y = (x - e.x) / e.dx + y_top
                    const y1: f32 = (x1 - x0) / dx + y_top;
                    const y2: f32 = (x1 + 1 - x0) / dx + y_top;

                    if (x0 < x1 and x3 > x2) { // three segments descending down-right
                        handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                        handleClippedEdge(scanline, x, e, x1, y1, x2, y2);
                        handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                    } else if (x3 < x1 and x0 > x2) { // three segments descending down-left
                        handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                        handleClippedEdge(scanline, x, e, x2, y2, x1, y1);
                        handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x0 < x1 and x3 > x1) { // two segments across x, down-right
                        handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                        handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x3 < x1 and x0 > x1) { // two segments across x, down-left
                        handleClippedEdge(scanline, x, e, x0, y0, x1, y1);
                        handleClippedEdge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x0 < x2 and x3 > x2) { // two segments across x+1, down-right
                        handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                        handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                    } else if (x3 < x2 and x0 > x2) { // two segments across x+1, down-left
                        handleClippedEdge(scanline, x, e, x0, y0, x2, y2);
                        handleClippedEdge(scanline, x, e, x2, y2, x3, y3);
                    } else { // one segment
                        handleClippedEdge(scanline, x, e, x0, y0, x3, y3);
                    }
                }
            }
        }
    }
}

/// The edge passed in here does not cross the vertical line at x or the
/// vertical line at x+1 (i.e. it has already been clipped to those).
fn handleClippedEdge(
    scanline: []f32,
    x: u32,
    e: *ActiveEdge,
    x0_start: f32,
    y0_start: f32,
    x1_start: f32,
    y1_start: f32,
) void {
    var x0 = x0_start;
    var y0 = y0_start;
    var x1 = x1_start;
    var y1 = y1_start;
    if (y0 == y1) return;
    assert(y0 < y1);
    assert(e.sy <= e.ey);
    if (y0 > e.ey) return;
    if (y1 < e.sy) return;
    if (y0 < e.sy) {
        x0 += (x1 - x0) * (e.sy - y0) / (y1 - y0);
        y0 = e.sy;
    }
    if (y1 > e.ey) {
        x1 += (x1 - x0) * (e.ey - y1) / (y1 - y0);
        y1 = e.ey;
    }

    const xf: f32 = @floatFromInt(x);

    if (x0 == xf)
        assert(x1 <= xf + 1)
    else if (x0 == xf + 1)
        assert(x1 >= xf)
    else if (x0 <= xf)
        assert(x1 <= xf)
    else if (x0 >= xf + 1)
        assert(x1 >= xf + 1)
    else {
        assert(x1 >= xf);
        assert(x1 <= xf + 1);
    }

    if (x0 <= xf and x1 <= xf) {
        scanline[x] += e.direction * (y1 - y0);
    } else if (x0 >= xf + 1 and x1 >= xf + 1) {
        // Do nothing.
    } else {
        assert(x0 >= xf);
        assert(x0 <= xf + 1);
        assert(x1 >= xf);
        assert(x1 <= xf + 1);
        // coverage = 1 - average x position
        scanline[x] += e.direction * (y1 - y0) * (1 - ((x0 - xf) + (x1 - xf)) / 2);
    }
}
