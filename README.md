# TrueType Package for Zig

This project started out as a port of
[stb_truetype](https://github.com/nothings/stb/blob/master/stb_truetype.h)
however it is independently maintained and improved upon by the open source
community.

Contributions welcome.

## Synopsis

```zig
const TrueType = @import("TrueType.zig");
const ttf = try TrueType.load(@embedFile("GoNotoCurrent-Regular.ttf"));
const example_string = "こんにちは!";
const scale = ttf.scaleForPixelHeight(20);

var stdout_buffer: [1024]u8 = undefined;
var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
defer stdout.flush() catch {};

var glyph_buffer: std.ArrayListUnmanaged(u8) = .empty;
defer glyph_buffer.deinit(init.gpa);
var workspace: TrueType.RasterizerWorkspace = .init(init.gpa);
defer workspace.deinit();
var it = std.unicode.Utf8View.initComptime(example_string).iterator();
while (it.nextCodepoint()) |codepoint| {
    const glyph = ttf.codepointGlyphIndex(codepoint);
    std.log.debug("0x{x}: {d}", .{ codepoint, glyph });
    glyph_buffer.clearRetainingCapacity();
    const dims = try ttf.glyphBitmapWithWorkspace(init.gpa, &glyph_buffer, &workspace, glyph, scale, scale);
    const pixels = glyph_buffer.items;
    for (0..dims.height) |j| {
        for (0..dims.width) |i| {
            try stdout.interface.writeByte(" .:ioVM@"[pixels[j * dims.width + i] >> 5]);
        }
        try stdout.interface.writeByte('\n');
    }
}
```

The workspace retains temporary memory between glyphs, including outline,
curve, edge, and scanline buffers. After sufficient capacity has been retained,
subsequent renders that fit it avoid backing-allocator calls for temporary data.
The pixel list owns its memory separately and can retain its capacity too.
Use one workspace per concurrent render; call `workspace.release()` to free its
cached memory early. The original `glyphBitmap` and `glyphBitmapSubpixel` APIs
remain available for one-off rendering.

## Fixed-memory rendering

The same API supports a fixed budget by supplying separate
`std.heap.FixedBufferAllocator` instances for output and workspace scratch.
There is no fallback heap allocator. Insufficient storage returns `OutOfMemory`;
existing pixels survive and the workspace remains reusable. See the compiling
[example](examples/render.zig):

```sh
zig build examples
zig build example -- test/StandardSymbolsPS.otf
```

The example uses 64 KiB output and 256 KiB scratch. These are workload budgets,
not universal capacity estimates. Loading the file in the example uses the
process allocator; the render itself uses only the fixed buffers. The font
parser borrows bytes, so callers can instead supply static font storage too.

Tests compare mixed glyphs at 12/32/96 pixels against one-shot output, check
stable warm buffer usage, and exercise scratch/output exhaustion and release.
Output capacity is independent of workspace capacity. `workspace.release()` is
an explicit retained-memory policy; call it after an unusually large workload or
when idle. Automatic shrinking and capacity estimation are deferred until a
caller needs stronger guarantees. Never reset a fixed allocator while its
workspace or output allocations remain live. Use separate workspaces and output
lists for concurrent renders; immutable font bytes may be shared.

## Rendering benchmarks

Run from a checkout with the compiler version in `build.zig.zon`:

```sh
zig build bench -Doptimize=ReleaseFast > benchmarks/results.csv
```

The benchmark samples 128 evenly spaced nonzero glyph IDs from each bundled
font at 12, 32, and 96 pixels. Each timing sample renders 100 passes (12,800
glyphs), after two warm-up passes. Both APIs retain the output pixel buffer;
only the workspace API retains temporary storage. Seven samples alternate which
API runs first. Font loading, warm-up, bitmap comparison, hashing, and CSV output
are outside the timer. Allocation counters run separately over the same warmed
workload, so instrumentation does not penalize the one-shot timings. Every
warm-up bitmap is compared byte-for-byte across the two APIs and allocator modes.

Results from 2026-10-03 on an AMD Ryzen 7 7840HS, Linux 7.0.0-38-generic,
Zig `0.17.0-dev.2281+83624acf6`, ReleaseFast, using `std.heap.smp_allocator`:

| Font | Pixels | One-shot µs/glyph | Workspace µs/glyph | One-shot alloc calls/glyph | Workspace retained bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| GoNotoCurrent-Regular | 12 | 4.230 | 4.100 | 12.94 | 39,052 |
| GoNotoCurrent-Regular | 32 | 5.739 | 5.969 | 12.39 | 38,064 |
| GoNotoCurrent-Regular | 96 | 11.968 | 11.999 | 12.04 | 27,450 |
| StandardSymbolsPS | 12 | 3.671 | 3.708 | 9.41 | 11,066 |
| StandardSymbolsPS | 32 | 5.776 | 5.859 | 9.44 | 37,996 |
| StandardSymbolsPS | 96 | 11.503 | 11.816 | 9.56 | 21,294 |

Times are medians of seven samples. The warmed workspace made **zero backing
allocator calls** (including resize, remap, and free) in all six scenarios. Its
median time ranged from 3.1% faster to 4.0% slower than one-shot rendering in this
run; these small differences on an unpinned machine do not establish a general
speed advantage. The demonstrated benefit is avoiding allocator traffic while
retaining roughly 11–39 KB of temporary storage per workspace for this workload.

[Raw samples](benchmarks/results.csv) also record peak live requested bytes,
output-buffer capacity, all allocator call counts, and workload checksums.
Retained temporary bytes exclude the output buffer; peak bytes include it.
These are requested allocation sizes, not allocator size classes or process RSS.
Loading costs, cold workspace growth, and workloads with different glyphs or
scales need separate measurements.

## Features and Limitations

* Codepoint to glyph lookup (cmap formats 0, 2, 4, 6, 8, 10, 12, and 13)
* Unicode variation-sequence lookup (format 14) via `codepointVariationGlyphIndex`
* `codepointGlyphIndexChecked` and `codepointVariationGlyphIndexChecked` report
  malformed mapping data; convenience lookups return `.notdef` or null on errors.
* Glyph rendering to bitmap
* CFF fixed-point operands retain signed fractions internally; exported integer
  outline vertices truncate toward zero. Out-of-range coordinates return
  `CoordinateOutOfRange`.
* CFF Type 2 arithmetic and stack operators: `abs`, `add`, `sub`, `div`,
  `neg`, `drop`, `mul`, `sqrt`, `dup`, `exch`, `index`, and `roll`.
  Invalid arithmetic domains or indices return `InvalidCffOperand`; non-finite
  arithmetic results return `CffNumericOverflow`.
* Type 2 transient storage (`put`, `get`), conditionals (`and`, `or`, `not`,
  `eq`, `ifelse`), and deterministic per-glyph `random`. Reading an unwritten
  storage slot returns `UninitializedCffStorage`.
* Type 2 path/flex arity and hint-mask lengths are validated. Hints are parsed
  but not applied; flex curves are rendered without flex-depth adjustment.
  Deprecated `dotsection` is ignored; deprecated endchar composites return
  `UnsupportedCffSeac`, and reserved operator codes return `ReservedOperator`.
* Kerning; `glyphKernAdvanceChecked` reports malformed positioning records,
  while `glyphKernAdvance` returns zero on errors.
* Font shaping and ligatures are not yet implemented.
* Font loading validates directory ranges and required metric-table sizes;
  malformed required data is rejected rather than replaced with guessed counts.
  Font bytes are borrowed and must remain immutable and alive while used.
* Untrusted font files are not supported; table-internal validation is still in progress.

## Checked queries and render inputs

`verticalMetricsChecked`, `glyphHMetricsChecked`, `scaleForPixelHeightChecked`,
`glyphBoxChecked`, `glyphBitmapBoxChecked`, and `glyphBitmapBoxSubpixelChecked`
report errors. Their convenience counterparts return zero metrics/scale, null,
or an empty pixel box on failure. A checked outline box returns null for an
empty outline, including an empty CFF charstring. Mapping and kerning checked
variants follow the same error-reporting policy.

Scales and requested pixel heights must be finite and strictly positive; shifts
must be finite. Invalid parameters return `InvalidRenderParameters` even for
empty glyphs. Pixel boxes must fit `i32`; rendered dimensions must fit `u16` and
origin offsets must fit `i16`, otherwise rendering returns `BitmapTooLarge`.
Empty outlines append no pixels. Errors leave the existing pixel list unchanged
and the workspace reusable. Allocation failure returns `OutOfMemory`.

**Migration:** the unused `-Ddebug-todo` option and implementation-only
`CharstringCtx` alias were removed. Use `glyphShape` and `glyphBoxChecked` for
outlines and bounds. `HMetrics.advance_width` is now `u16`, matching the unsigned hmtx
record. Widen metrics to `i32` before signed layout arithmetic; ascent minus
descent can exceed `i16`. Font objects should be constructed with `load`; their
borrowed bytes must remain immutable for their entire lifetime.

## Resource budgets

`font.withLimits(.{ .max_bitmap_pixels = 1024 * 1024 })` returns a copy of the
borrowed font view with customized per-operation budgets. Other fields retain
these defaults; zero allows none of the corresponding work:

| Limit | Default | Accounting |
| --- | ---: | --- |
| `max_charstring_instructions` | 1,000,000 | Tokens per CFF interpretation pass, including subroutine calls |
| `max_outline_vertices` | 131,072 | CFF vertices, or aggregate TrueType vertex capacity and composite assembly work |
| `max_components` | 4,096 | TrueType glyph visits, including repeated or empty children |
| `max_flattened_points` | 262,144 | Points after subdivision; also bounds edges and contours |
| `max_bitmap_pixels` | 16,777,216 | Bytes appended by one render |
| `max_raster_work` | 1,000,000,000 | Conservative product of flattened points and bitmap pixels |

Exhaustion returns `ResourceLimitExceeded`. TrueType and CFF recursion retain
separate fixed depth guards (64 and 10); subdivision beyond depth 16 also returns
an error. Budgets bound work, not exact allocator overhead. Use fixed-buffer
allocators to impose a strict memory budget. Larger limits permit more work;
they cannot expand the public integer coordinate/dimension representations.
Load validates only the selected base/variation cmap, and caps nested format-14
mapping validation at 1,000,000 records to bound shared-map amplification.

## Fuzzing

Run `zig build fuzz fuzz-replay` for seed checks and a short deterministic
mutation campaign. See [fuzz/README.md](fuzz/README.md) for separate native targets,
input/work limits, and reproducing individual failures.

## Roadmap

See [PLAN.md](PLAN.md) for the implementation sequence, commit-sized slices,
validation criteria, and release gates. CFF numeric/operator fixes, bounded reads, checked queries,
resource budgets, and initial fuzz targets are implemented. The next work covers
module boundaries, broader fixtures, and release evidence.
The broader plan covers predictable memory use, a stable core release, hinting,
and text shaping.

## Why not use FreeType?

FreeType supports a lot more than just TrueType, making it bloated if your use
case is only TrueType fonts. 

FreeType is written in C. By having it written in Zig, we drop a dependency on
a C compiler and allow the code to be in the same compilation unit as the other
Zig code.

Healthy competition between open source projects.

## Why not use HarfBuzz?

HarfBuzz is written in C++, a programming language everyone agrees should be
wiped from the face of the Earth. My personal code of conduct forbids me from
adding libc++ as a runtime dependency to any of my projects.

Healthy competition between open source projects.
