# Changelog

## 3.0.0-dev — unreleased

- Checked sfnt/table/glyph reads, checked metadata/mapping/kerning/bounds queries,
  public render-input validation, and configurable resource budgets.
- Correct signed CFF fixed-point operands and Type 2 arithmetic, stack,
  transient-storage, conditional, and deterministic random operators.
- TrueType composite attachment and transform support, broader cmap/variation
  lookup, and scalar GPOS pair adjustment handling.
- Reusable workspace and tested fixed-memory rendering, bounded fuzz targets,
  replay, compiler pin, local/Codeberg CI configuration, and downstream checks.
- Rendering/outline modules split by ownership. Explicit static-font support
  matrix and font/reference provenance accompany the package.

### Migration

- `HMetrics.advance_width` is unsigned `u16`; widen to `i32` for signed layout
  arithmetic. Vertical ascent minus descent also needs a wider integer.
- Scales/heights must be finite and positive; shifts must be finite. Invalid
  inputs now return errors instead of relying on assertions or numeric traps.
- Checked query variants distinguish malformed data. Convenience variants use
  documented zero/null/empty fallbacks. Empty CFF bounds now return null.
- Strict validation can reject malformed fonts accepted accidentally before.
  Deprecated CFF seac composites explicitly return `UnsupportedCffSeac`.
- Rendering can return `ResourceLimitExceeded`; customize `withLimits` when a
  trusted workload requires a larger budget. `OutOfMemory` remains distinct.
- The unsupported `CharstringCtx` implementation alias, unused `debug-todo`
  build option, and obsolete `Unimplemented` error were removed. Use public
  outline/bounds APIs and construct fonts with `load`.
- Font bytes are borrowed and immutable. Output and scratch ownership remain
  separate; never reset a backing allocator while allocations are live.

The library remains under development. Untrusted-font support, hosted runtime
coverage beyond the local Linux host, hinting, shaping, and additional font
technologies are not implied by this release note. See PLAN.md for open gates.
