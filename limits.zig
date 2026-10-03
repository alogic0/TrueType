//! Per-operation budgets. Zero disables the corresponding work, not the limit.
const Limits = @This();

max_charstring_instructions: u32 = 1_000_000,
/// Aggregate TrueType vertex capacity/assembly work, or CFF emitted vertices.
max_outline_vertices: u32 = 131_072,
/// Total glyph visits, including repeated composite children and empty glyphs.
max_components: u32 = 4096,
/// Flattened points also bound contours and edges.
max_flattened_points: u32 = 262_144,
max_bitmap_pixels: u32 = 16 * 1024 * 1024,
/// Conservative bound: flattened points times bitmap pixels.
max_raster_work: u64 = 1_000_000_000,

pub const Error = error{ResourceLimitExceeded};

pub fn consume(remaining: *u32, amount: usize) Error!void {
    if (amount > remaining.*) return error.ResourceLimitExceeded;
    remaining.* -= @intCast(amount);
}
