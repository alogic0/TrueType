//! Render a glyph using separate fixed output and scratch budgets.
const std = @import("std");
const TrueType = @import("TrueType");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2) return error.ExpectedFontPath;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(32 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const font = try TrueType.load(bytes);
    const scale = try font.scaleForPixelHeightChecked(24);
    // An unsupported variation sequence falls back to the base glyph.
    const glyph = try font.codepointVariationGlyphIndexChecked('A', 0xfe0f) orelse try font.codepointGlyphIndexChecked('A');
    var output_bytes: [64 * 1024]u8 = undefined;
    var scratch_bytes: [256 * 1024]u8 = undefined;
    var output = std.heap.FixedBufferAllocator.init(&output_bytes);
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    var pixels: std.ArrayList(u8) = .empty;
    defer pixels.deinit(output.allocator());
    var workspace: TrueType.RasterizerWorkspace = .init(scratch.allocator());
    defer workspace.deinit();
    const bitmap = font.glyphBitmapWithWorkspace(output.allocator(), &pixels, &workspace, glyph, scale, scale) catch |err| {
        // Existing output is unchanged; the workspace can be reused after errors.
        if (err == error.OutOfMemory) std.log.err("increase the fixed output or scratch budget", .{});
        return err;
    };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    for (0..bitmap.height) |y| {
        for (0..bitmap.width) |x| try stdout.interface.writeByte(" .:ioVM@"[pixels.items[y * bitmap.width + x] >> 5]);
        try stdout.interface.writeByte('\n');
    }
    // Clear output for reuse. release() frees retained scratch independently.
    pixels.clearRetainingCapacity();
    workspace.release();
}
