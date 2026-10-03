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
var it = std.unicode.Utf8View.initComptime(example_string).iterator();
while (it.nextCodepoint()) |codepoint| {
    const glyph = ttf.codepointGlyphIndex(codepoint);
    std.log.debug("0x{x}: {d}", .{ codepoint, glyph });
    glyph_buffer.clearRetainingCapacity();
    const dims = try ttf.glyphBitmap(gpa, &glyph_buffer, glyph, scale, scale);
    const pixels = glyph_buffer.items;
    for (0..dims.height) |j| {
        for (0..dims.width) |i| {
            try stdout.interface.writeByte(" .:ioVM@"[pixels[j * dims.width + i] >> 5]);
        }
        try stdout.interface.writeByte('\n');
    }
}
```

## Features and Limitations

* Codepoint to glyph lookup (cmap formats 0, 2, 4, 6, 8, 10, 12, and 13)
* Unicode variation-sequence lookup (format 14) via `codepointVariationGlyphIndex`
* Glyph rendering to bitmap
* Kerning
* Font shaping and ligatures are not yet implemented.
* Untrusted font files are not supported.

## Roadmap

* eliminate TODOs
* eliminate heap allocation
* support more advanced text shaping like harfbuzz

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
