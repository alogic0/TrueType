//! Warm rendering benchmark. Run: zig build bench -Doptimize=ReleaseFast
const std = @import("std");
const builtin = @import("builtin");
const TrueType = @import("TrueType");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const glyph_count = 128;
const passes = 100;
const samples = 7;

// Counts requested live bytes, not allocator size classes or process RSS.
const CountingAllocator = struct {
    child: Allocator = std.heap.smp_allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn resetCounts(self: *CountingAllocator) void {
        self.alloc_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
        self.peak = self.live;
    }

    fn changed(self: *CountingAllocator, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        const result = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.changed(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        if (!self.child.rawResize(memory, alignment, len, ra)) return false;
        self.changed(memory.len, len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remap_calls += 1;
        const result = self.child.rawRemap(memory, alignment, len, ra) orelse return null;
        self.changed(memory.len, len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_calls += 1;
        self.child.rawFree(memory, alignment, ra);
        self.changed(memory.len, 0);
    }
};

const Renderer = struct {
    counter: CountingAllocator = .{},
    pixels: std.ArrayList(u8) = .empty,
    workspace: ?TrueType.RasterizerWorkspace = null,
    gpa: Allocator = std.heap.smp_allocator,

    // Initialize in place: a counting allocator points back into this struct.
    fn init(self: *Renderer, tracked: bool, reuse: bool) void {
        self.* = .{};
        if (tracked) self.gpa = self.counter.allocator();
        if (reuse) self.workspace = .init(self.gpa);
    }

    fn deinit(self: *Renderer) void {
        if (self.workspace) |*workspace| workspace.deinit();
        self.pixels.deinit(self.gpa);
        if (self.counter.live != 0) @panic("benchmark allocation accounting did not balance");
    }

    fn render(self: *Renderer, font: *const TrueType, glyph: TrueType.GlyphIndex, scale: f32) !void {
        self.pixels.clearRetainingCapacity();
        if (self.workspace) |*workspace| {
            _ = try font.glyphBitmapWithWorkspace(self.gpa, &self.pixels, workspace, glyph, scale, scale);
        } else {
            _ = try font.glyphBitmap(self.gpa, &self.pixels, glyph, scale, scale);
        }
        std.mem.doNotOptimizeAway(self.pixels.items);
    }

    fn run(self: *Renderer, font: *const TrueType, glyphs: []const TrueType.GlyphIndex, scale: f32) !void {
        for (0..passes) |_| {
            for (glyphs) |glyph| try self.render(font, glyph, scale);
        }
    }

    fn measure(self: *Renderer, io: std.Io, out: *std.Io.Writer, name: []const u8, height: u32, sample: usize, font: *const TrueType, glyphs: []const TrueType.GlyphIndex, checksum: u64, profile: *const Renderer) !void {
        const scale = font.scaleForPixelHeight(@floatFromInt(height));
        const start = std.Io.Clock.awake.now(io);
        try self.run(font, glyphs, scale);
        const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        // Allocation statistics come from a separate, identically warmed run.
        // The timed renderer calls smp_allocator directly, without counters.
        const counter = profile.counter;
        try out.print("{s},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{x}\n", .{
            name,                    height,             if (self.workspace != null) "workspace" else "one_shot", sample,
            passes * glyphs.len,     elapsed,            counter.alloc_calls,                                     counter.resize_calls,
            counter.remap_calls,     counter.free_calls, counter.peak,                                            counter.live - profile.pixels.capacity,
            profile.pixels.capacity, checksum,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &stdout.interface;
    try out.print("# zig={s}, optimize={t}, arch={t}, os={t}, allocator=smp_allocator\n", .{ builtin.zig_version_string, builtin.mode, builtin.cpu.arch, builtin.os.tag });
    try out.print("# glyphs={d}, passes={d}, samples={d}, warmup_passes=2, clock=awake\n", .{ glyph_count, passes, samples });
    try out.writeAll("# allocation statistics are from a separate run; timing uses the unwrapped allocator\n");
    try out.writeAll("font,pixel_height,mode,sample,glyph_renders,elapsed_ns,alloc_calls,resize_calls,remap_calls,free_calls,peak_requested_bytes,retained_temp_bytes,pixel_capacity_bytes,checksum\n");
    const fonts = .{
        .{ "GoNotoCurrent-Regular", @embedFile("test/GoNotoCurrent-Regular.ttf") },
        .{ "StandardSymbolsPS", @embedFile("test/StandardSymbolsPS.otf") },
    };
    inline for (fonts) |entry| {
        const font = try TrueType.load(entry[1]);
        var glyphs: [glyph_count]TrueType.GlyphIndex = undefined;
        for (&glyphs, 0..) |*glyph, i| glyph.* = @fromBackingInt(@as(u16, @intCast(1 + i * (font.glyphs_len - 1) / glyph_count)));
        for ([_]u32{ 12, 32, 96 }) |height| {
            const scale = font.scaleForPixelHeight(@floatFromInt(height));
            var one_shot: Renderer = undefined;
            one_shot.init(false, false);
            defer one_shot.deinit();
            var workspace: Renderer = undefined;
            workspace.init(false, true);
            defer workspace.deinit();
            var counted_one_shot: Renderer = undefined;
            counted_one_shot.init(true, false);
            defer counted_one_shot.deinit();
            var counted_workspace: Renderer = undefined;
            counted_workspace.init(true, true);
            defer counted_workspace.deinit();

            // Warm output lists and workspaces with the whole workload. Compare
            // every bitmap before timing; hashing is also outside the timer.
            var checksum: std.hash.Wyhash = .init(0);
            for (0..2) |_| {
                for (glyphs) |glyph| {
                    try one_shot.render(&font, glyph, scale);
                    for ([_]*Renderer{ &workspace, &counted_one_shot, &counted_workspace }) |renderer| {
                        try renderer.render(&font, glyph, scale);
                        if (!std.mem.eql(u8, one_shot.pixels.items, renderer.pixels.items)) return error.BitmapMismatch;
                    }
                    checksum.update(one_shot.pixels.items);
                }
            }
            for ([_]*Renderer{ &counted_one_shot, &counted_workspace }) |renderer| {
                renderer.counter.resetCounts();
                try renderer.run(&font, &glyphs, scale);
            }
            for (0..samples) |sample| {
                // Alternate which API runs first to reduce ordering bias.
                const order: [2]*Renderer = if (sample % 2 == 0) .{ &one_shot, &workspace } else .{ &workspace, &one_shot };
                for (order) |renderer| {
                    const profile = if (renderer.workspace != null) &counted_workspace else &counted_one_shot;
                    try renderer.measure(init.io, out, entry[0], height, sample, &font, &glyphs, checksum.final(), profile);
                }
                try out.flush();
            }
        }
    }
    try out.flush();
}
