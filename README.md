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
* Glyph rendering to bitmap
* CFF fixed-point operands retain signed fractions internally; exported integer
  outline vertices truncate toward zero. Out-of-range coordinates return
  `CoordinateOutOfRange`.
* CFF Type 2 arithmetic and stack operators: `abs`, `add`, `sub`, `div`,
  `neg`, `drop`, `mul`, `sqrt`, `dup`, `exch`, `index`, and `roll`.
  Invalid arithmetic domains or indices return `InvalidCffOperand`; non-finite
  arithmetic results return `CffNumericOverflow`.
* Kerning
* Font shaping and ligatures are not yet implemented.
* Untrusted font files are not supported.

## Roadmap

See [PLAN.md](PLAN.md) for the implementation sequence, commit-sized slices,
validation criteria, and release gates. The immediate priorities are CFF numeric
correctness, missing Type 2 operators, bounded font reads, and reproducible fuzzing.
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
