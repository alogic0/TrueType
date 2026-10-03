# Static-font support and test matrix

| Area | Supported behavior | Evidence / limits |
| --- | --- | --- |
| Containers | Single sfnt TrueType (`0x00010000`, legacy `true`) and OTTO CFF1 | `test/sfnt.zig`; TTC/OTC, WOFF/WOFF2, CFF2 unsupported |
| TrueType outlines | Simple quadratic contours, composites, point attachments, component transforms | `test/composite.zig`, Noto differential tests; instructions skipped |
| CFF1 outlines | Type 2 lines/curves/flex geometry, local/global subroutines, CID FDSelect 0/3 | `test/cff.zig`, `test/type2.zig`; authored CID fixture selects distinct private subroutines |
| Type 2 computation | Signed fixed point, arithmetic, stack, transient, conditional, deterministic random | Authored expected-coordinate/error fixtures; deprecated seac unsupported |
| Character maps | Formats 0/2/4/6/8/10/12/13 and supplemental format 14 | `test/cmap.zig`, bundled-font lookup comparisons, authored format-0 fuzz seed |
| Metrics | Checked hhea/hmtx, unsigned advances, vertical scaling | `test/contracts.zig`, bundled-font comparisons |
| Kerning | First matching base X advance from GPOS pair 1/2, extension 9→2, first horizontal kern format-0 subtable | `test/test.zig`; ignores placement, second-glyph/device/variation adjustments and script/language/feature selection |
| Rasterization | Unhinted 8-bit grayscale coverage, positive unequal scales, fractional shifts | Independent integrated-curve and clipped-triangle tests plus valid-font stb comparisons |
| Memory | Caller allocator, reusable workspace, separate fixed output/scratch budgets | `test/allocation.zig`, `test/workspace.zig`, `test/fixed_buffer.zig` |
| Malformed/excessive inputs | Checked reads, documented errors, resource budgets | Truncation/count/offset fixtures and bounded fuzz campaign; broad untrusted-font support is not yet claimed |
| Typography beyond glyph rendering | Caller supplies glyph selection/layout | Hinting, flex-depth behavior, shaping/ligatures/bidi, variations, color, SVG/bitmap strikes are outside the current core |

Coordinates are font units in outlines (positive Y up); bitmap coordinates are
pixels (positive Y down). Exported outline vertices use i16 coordinates. CFF
fractions truncate toward zero; pixel boxes floor minima and ceil maxima. Glyph
zero is `.notdef`, not an error. Empty outlines produce no pixels; malformed data
is reported by checked queries and render APIs. The README documents convenience
fallbacks and numeric/resource limits.

Font bytes remain borrowed and immutable. Returned outline slices belong to the
caller and must be freed with the allocator passed to `glyphShape`. Pixel lists
belong to the caller independently of workspace lifetime. Workspaces are mutable
and require one instance per concurrent render.

The primary correctness corpus uses authored expected values plus two bundled
fonts. See [font provenance](../test/FONTS.md) and [reference scope](VALIDATION.md).
A second engine has not been added: no unresolved rendering discrepancy currently
requires it. Broader external corpora and isolated long fuzz campaigns remain
useful release evidence; they must retain provenance and matching render settings.
