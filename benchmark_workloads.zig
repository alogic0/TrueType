//! Additional workloads and separately instrumented stage diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const TrueType = @import("TrueType.zig");
const rasterizer = @import("rasterizer.zig");
const Counter = @import("benchmark_support.zig").CountingAllocator;
const gpa = std.heap.smp_allocator;
const Workload = enum { cold_text, warm_text, mixed_sizes, complex_glyphs };
const passes = 50;
const samples = 7;
const glyph_count = 16;

const Runner = struct {
    counter: Counter = .{},
    allocator: std.mem.Allocator = gpa,
    workspace: ?TrueType.RasterizerWorkspace = null,
    pixels: std.ArrayList(u8) = .empty,
    fn init(self: *Runner, tracked: bool, reuse: bool) void {
        self.* = .{};
        if (tracked) self.allocator = self.counter.allocator();
        if (reuse) self.workspace = .init(self.allocator);
    }
    fn deinit(self: *Runner) void {
        if (self.workspace) |*workspace| workspace.deinit();
        self.pixels.deinit(self.allocator);
        if (self.counter.live != 0) @panic("unbalanced benchmark allocations");
    }
    fn render(self: *Runner, font: *const TrueType, glyph: TrueType.GlyphIndex, scale: f32, cold: bool) !TrueType.GlyphBitmap {
        if (cold) {
            if (self.workspace) |*workspace| workspace.release();
            self.pixels.deinit(self.allocator);
            self.pixels = .empty;
        } else self.pixels.clearRetainingCapacity();
        const result = if (self.workspace) |*workspace|
            try font.glyphBitmapWithWorkspace(self.allocator, &self.pixels, workspace, glyph, scale, scale)
        else
            try font.glyphBitmap(self.allocator, &self.pixels, glyph, scale, scale);
        std.mem.doNotOptimizeAway(self.pixels.items);
        return result;
    }
    fn run(self: *Runner, font: *const TrueType, glyphs: []const TrueType.GlyphIndex, workload: Workload) !void {
        for (0..passes) |_| for (glyphs, 0..) |glyph, i| {
            _ = try self.render(font, glyph, scaleAt(font, workload, i), workload == .cold_text);
        };
    }
};

fn scaleAt(font: *const TrueType, workload: Workload, i: usize) f32 {
    return font.scaleForPixelHeight(if (workload == .mixed_sizes) ([_]f32{ 12, 96, 24, 48 })[i % 4] else 32);
}

fn selectGlyphs(font: *const TrueType, workload: Workload) ![glyph_count]TrueType.GlyphIndex {
    var result: [glyph_count]TrueType.GlyphIndex = @splat(.notdef);
    if (workload != .complex_glyphs) {
        for ([_]u21{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'Z', 'i', 'g', '!', ' ', 0x3a9, 0x416, 0x65e5, 0x672c }, 0..) |cp, i| result[i] = font.codepointGlyphIndex(cp);
        return result;
    }
    var sizes: [glyph_count]usize = @splat(0);
    for (0..128) |i| {
        const glyph: TrueType.GlyphIndex = @fromBackingInt(@as(u16, @intCast(1 + i * (font.glyphs_len - 1) / 128)));
        const vertices = try font.glyphShape(gpa, glyph);
        defer gpa.free(vertices);
        for (0..glyph_count) |rank| {
            if (vertices.len > sizes[rank]) {
                var slot: usize = glyph_count - 1;
                while (slot > rank) : (slot -= 1) {
                    sizes[slot] = sizes[slot - 1];
                    result[slot] = result[slot - 1];
                }
                sizes[rank] = vertices.len;
                result[rank] = glyph;
                break;
            }
        }
    }
    return result;
}

fn stages(io: std.Io, out: *std.Io.Writer, name: []const u8, font: *const TrueType, glyphs: []const TrueType.GlyphIndex, workload: Workload) !void {
    var times: [4]i96 = @splat(0);
    var reference: Runner = undefined;
    reference.init(false, false);
    defer reference.deinit();
    for (0..10) |_| for (glyphs, 0..) |glyph, i| {
        const scale = scaleAt(font, workload, i);
        const before = std.Io.Clock.awake.now(io);
        const vertices = try font.glyphShape(gpa, glyph);
        times[0] += before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        defer gpa.free(vertices);
        if (vertices.len == 0) continue;
        const expected = try reference.render(font, glyph, scale, false);
        if (expected.width == 0 or expected.height == 0) continue;
        const pixels = try gpa.alloc(u8, @as(usize, expected.width) * expected.height);
        defer gpa.free(pixels);
        var bitmap: rasterizer.Bitmap = .{ .w = expected.width, .h = expected.height, .stride = expected.width, .pixels = pixels };
        const measured = try rasterizer.profileStages(io, gpa, &bitmap, vertices, scale, expected.off_x, expected.off_y);
        if (!std.mem.eql(u8, pixels, reference.pixels.items)) return error.ProfileBitmapMismatch;
        times[1] += measured.flatten_ns;
        times[2] += measured.edges_ns;
        times[3] += measured.coverage_ns;
    };
    try out.print("# stages font={s} workload={t} renders={d} decode_ns={d} flatten_ns={d} edges_ns={d} coverage_ns={d}\n", .{ name, workload, glyphs.len * 10, times[0], times[1], times[2], times[3] });
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("# zig={s} optimize={t} arch={t} os={t} allocator=smp_allocator passes={d} samples={d}\n", .{ builtin.zig_version_string, builtin.mode, builtin.cpu.arch, builtin.os.tag, passes, samples });
    try out.writeAll("font,workload,mode,sample,renders,elapsed_ns,alloc_calls,resize_calls,remap_calls,free_calls,peak_bytes,retained_scratch_bytes,pixel_capacity,checksum\n");
    inline for (.{ .{ "Noto", @embedFile("test/GoNotoCurrent-Regular.ttf") }, .{ "Symbols", @embedFile("test/StandardSymbolsPS.otf") } }) |entry| {
        const font = try TrueType.load(entry[1]);
        for (std.enums.values(Workload)) |workload| {
            const glyphs = try selectGlyphs(&font, workload);
            var runners: [4]Runner = undefined;
            for (&runners, 0..) |*runner, i| runner.init(i >= 2, i % 2 == 1);
            defer for (&runners) |*runner| runner.deinit();
            var hash = std.hash.Wyhash.init(0);
            for (0..2) |_| for (glyphs, 0..) |glyph, i| {
                const expected = try runners[0].render(&font, glyph, scaleAt(&font, workload, i), workload == .cold_text);
                for (runners[1..]) |*runner| {
                    const actual = try runner.render(&font, glyph, scaleAt(&font, workload, i), workload == .cold_text);
                    if (!std.meta.eql(expected, actual) or !std.mem.eql(u8, runners[0].pixels.items, runner.pixels.items)) return error.BitmapMismatch;
                }
                hash.update(runners[0].pixels.items);
            };
            for (runners[2..]) |*runner| {
                runner.counter.resetCounts();
                try runner.run(&font, &glyphs, workload);
            }
            for (0..samples) |sample| {
                for (0..2) |order| {
                    const i = (order + sample) % 2;
                    const start = std.Io.Clock.awake.now(init.io);
                    try runners[i].run(&font, &glyphs, workload);
                    const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
                    const profile = &runners[i + 2];
                    const c = profile.counter;
                    try out.print("{s},{t},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{x}\n", .{ entry[0], workload, if (i == 0) "one_shot" else "workspace", sample, passes * glyph_count, elapsed, c.alloc_calls, c.resize_calls, c.remap_calls, c.free_calls, c.peak, c.live - profile.pixels.capacity, profile.pixels.capacity, hash.final() });
                }
            }
            try stages(init.io, out, entry[0], &font, &glyphs, workload);
            try out.flush();
        }
    }
}
