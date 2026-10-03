const std = @import("std");
const rasterizer = @import("../rasterizer.zig");
const Vertex = @import("../glyph.zig").Vertex;

fn vertex(kind: Vertex.Type, x: i16, y: i16, cx: i16, cy: i16, cx1: i16, cy1: i16) Vertex {
    return .{ .type = kind, .x = x, .y = y, .cx = cx, .cy = cy, .cx1 = cx1, .cy1 = cy1 };
}

test "rasterizer stretched quadratic and cubic curves match integrated coverage" {
    for ([_]bool{ false, true }) |cubic| {
        for ([_]bool{ false, true }) |transpose| {
            var vertices = [_]Vertex{
                vertex(.vmove, 0, 0, 0, 0, 0, 0),
                if (cubic) vertex(.vcubic, 96, 0, 32, 96, 64, 96) else vertex(.vcurve, 96, 0, 48, 96, 0, 0),
            };
            if (transpose) for (&vertices) |*v| {
                std.mem.swap(i16, &v.x, &v.y);
                std.mem.swap(i16, &v.cx, &v.cy);
                std.mem.swap(i16, &v.cx1, &v.cy1);
            };
            const height: u32 = if (cubic) 72 else 48;
            var storage: [12 * 72]u8 = @splat(0);
            var bitmap: rasterizer.Bitmap = .{
                .w = if (transpose) height else 12,
                .h = if (transpose) 12 else height,
                .stride = if (transpose) height else 12,
                .pixels = &storage,
            };
            try rasterizer.rasterize(std.testing.allocator, &bitmap, 0.35, &vertices, if (transpose) 1 else 0.125, if (transpose) 0.125 else 1, 0, 0, 0, 0, false);
            var error_area: f64 = 0;
            for (0..height) |y| {
                for (0..12) |x| {
                    // x(t) is linear for both curves. Integrate the area below
                    // y(t) inside each pixel, independently of tessellation.
                    var coverage: f64 = 0;
                    for (0..1024) |sample| {
                        const t = (@as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sample)) + 0.5) / 1024) / 12;
                        const top = (if (cubic) @as(f64, 288) else 192) * t * (1 - t);
                        coverage += std.math.clamp(top - @as(f64, @floatFromInt(y)), 0, 1) / 1024;
                    }
                    const index = if (transpose) x * height + y else y * 12 + x;
                    error_area += @abs(@as(f64, @floatFromInt(storage[index])) / 255 - coverage);
                }
            }
            // Total absolute error, in pixel areas, including byte quantization.
            try std.testing.expect(error_area < 2);
        }
    }
}

const Point = struct { x: f64, y: f64 };

// Clip a polygon to a pixel and measure its area in double precision.
fn pixelArea(triangle: [3]Point, x: f64, y: f64) f64 {
    var a: [12]Point = undefined;
    var b: [12]Point = undefined;
    @memcpy(a[0..3], &triangle);
    var count: usize = 3;
    for (0..4) |side| {
        if (count == 0) return 0;
        const bound = switch (side) {
            0 => x,
            1 => x + 1,
            2 => y,
            else => y + 1,
        };
        var out: usize = 0;
        var previous = a[count - 1];
        for (a[0..count]) |current| {
            const p = if (side < 2) previous.x else previous.y;
            const c = if (side < 2) current.x else current.y;
            const p_in = if (side % 2 == 0) p >= bound else p <= bound;
            const c_in = if (side % 2 == 0) c >= bound else c <= bound;
            if (p_in != c_in) {
                const t = (bound - p) / (c - p);
                b[out] = .{ .x = previous.x + t * (current.x - previous.x), .y = previous.y + t * (current.y - previous.y) };
                out += 1;
            }
            if (c_in) {
                b[out] = current;
                out += 1;
            }
            previous = current;
        }
        @memcpy(a[0..out], b[0..out]);
        count = out;
    }
    if (count == 0) return 0;
    var area: f64 = 0;
    var previous = a[count - 1];
    for (a[0..count]) |p| {
        area += previous.x * p.y - previous.y * p.x;
        previous = p;
    }
    return @abs(area) / 2;
}

test "rasterizer clipped edges match analytic triangle coverage" {
    for ([_]f32{ -4, -0.7, -0.2, -0.00000006, 0.00000006, 0.01, 0.2, 0.7, 1.5, 4 }) |sx| {
        for ([_]f32{ 0.13, 0.65, 1.7 }) |sy| {
            for ([_]f32{ -0.1, 0.99999994, 1, 1.1 }) |shift| {
                for ([_]bool{ false, true }) |reverse| {
                    var vertices = [_]Vertex{
                        vertex(.vmove, -4, 0, 0, 0, 0, 0),
                        vertex(.vline, 0, 0, 0, 0, 0, 0),
                        vertex(.vline, 1, 1, 0, 0, 0, 0),
                    };
                    if (reverse) std.mem.swap(Vertex, &vertices[1], &vertices[2]);
                    var pixels: [8]u8 = @splat(0);
                    var bitmap: rasterizer.Bitmap = .{ .w = 4, .h = 2, .stride = 4, .pixels = &pixels };
                    try rasterizer.rasterize(std.testing.allocator, &bitmap, 0.35, &vertices, sx, sy, shift, 0.25, 0, 0, false);
                    var triangle: [3]Point = undefined;
                    for (vertices, &triangle) |v, *p| {
                        // Match the renderer's transformed endpoints, then
                        // compute reference intersections and areas in f64.
                        p.* = .{ .x = @as(f32, @floatFromInt(v.x)) * sx + shift, .y = @as(f32, @floatFromInt(v.y)) * sy + 0.25 };
                    }
                    for (pixels, 0..) |pixel, i| {
                        const coverage = pixelArea(triangle, @floatFromInt(i % 4), @floatFromInt(i / 4));
                        try std.testing.expectApproxEqAbs(coverage, @as(f64, @floatFromInt(pixel)) / 255, 1.5 / 255.0);
                    }
                }
            }
        }
    }
}
