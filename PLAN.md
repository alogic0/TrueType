# TrueType project plan

Status: implementation in progress; unchecked items remain pending.
Baseline: `abc7270`, recorded 2026-10-03.

## 1. Target outcome

Deliver a reliable, maintainable Zig library for loading supported static
TrueType and CFF fonts, looking up glyphs, reading metrics and pair kerning, and
rendering grayscale glyph bitmaps. Make memory ownership explicit, keep repeated
rendering predictable, and provide a tested route for callers with fixed memory
budgets.

Treat a stable core renderer as the first finish line. Hinting, full text shaping,
and additional font technologies have separate milestones and acceptance gates.
A core release should be useful and complete within its published support matrix
without waiting for every OpenType feature.

The priorities are:

1. Correct results for supported inputs.
2. Defined errors and bounded work for invalid or excessive inputs.
3. Stable ownership and public API contracts.
4. Measured rendering quality, allocation behavior, and performance.
5. Broader typography support through explicit, independently testable features.

This document is a proposed implementation sequence, not a claim that its future
features already work. Maintain it as slices land: mark completed items, record
commit IDs and evidence, and revise later milestones when measurements warrant it.

## 2. Current baseline

### Completed foundations

- [x] Extract shared geometry, rasterization, CFF, and character-map code into
  separate modules.
- [x] Support optional GPOS pair-adjustment value fields.
- [x] Bound CFF data by the table-directory length.
- [x] Implement composite glyph attachment by original outline-point indices,
  including nested transforms and recursion limits.
- [x] Extend character-map lookup and add variation-sequence lookup.
- [x] Add a reusable rasterizer workspace with retained temporary storage.
- [x] Fix ownership cleanup when transferring flattened-curve allocations fails.
- [x] Validate CFF indexes, dictionary offsets, FDSelect data, and truncated reads.
- [x] Fix unequal-scale curve flattening and clipped-edge crossings.
- [x] Add independent rasterizer accuracy tests and a rendering benchmark.

The last full verification passed **34 tests in Debug and ReleaseSafe**. This is
baseline evidence from the previous implementation session, not a new test run
performed while writing this document.

The [recorded benchmark](benchmarks/results.csv) covers both bundled fonts at
12, 32, and 96 pixels. A warmed workspace made no backing-allocator calls and
retained approximately 11–39 KB of temporary memory. Median timing differences
were small and mixed; the measurement does not establish a general speedup.
See [README.md](README.md#rendering-benchmarks) for the method and results.

### Known gaps

| Area | Current gap | Consequence |
| --- | --- | --- |
| CFF numbers | The `255` operand path divides an unsigned integer before floating-point conversion. | Negative values and fractional operands are decoded incorrectly. |
| CFF interpreter | Escaped operators outside the implemented flex family return `Unimplemented`. | Some otherwise valid charstrings cannot render. |
| Font parsing | Several non-CFF paths read offsets and counts directly from the full byte slice. | Existing CFF checks do not make the whole parser suitable for untrusted fonts. |
| Rendering inputs | Scale assertions, integer coordinate conversions, and bitmap-size arithmetic need explicit contracts. | Invalid or extreme parameters can produce traps or excessive allocations. |
| Memory guarantees | Retained workspace reuse is tested; general cold-render and fixed-budget guarantees are not documented. | “Eliminate heap allocation” remains too broad to serve as an acceptance criterion. |
| Typography | Hinting, flex-depth behavior, and text shaping remain incomplete. | Small-size rendering and complex-script layout have limitations. |
| Maintenance | The root module still combines loading, metrics, kerning, and TrueType outline decoding. | Future changes can become difficult to review without further targeted extraction. |
| Automation | There is no repository `.github` workflow directory at this baseline. | CI coverage needs to be established or documented for the actual hosting platform. |

## 3. Delivery rules

- Make one coherent, reviewable commit per slice. A slice includes its regression
  tests and relevant documentation; do not combine unrelated feature changes.
- For a discovered bug, first capture a failing case, then implement the fix.
- Keep behavior-preserving extraction separate from behavior changes when practical.
- Keep the library usable without mandatory C/C++ runtime dependencies. Reference
  engines and diagnostic tools may be development-only dependencies.
- Preserve existing one-shot and workspace entry points where practical. Record
  intentional API changes and migrations before a stable release.
- Treat borrowed font bytes as caller-owned, immutable data with an explicit
  lifetime. Workspace scratch and output pixels must have distinct ownership.
- Every remaining TODO should link to a planned item or describe an intentional
  limitation. Deleting the comment is not completion.
- Update the support matrix and this plan when a feature is implemented, deferred,
  or deliberately rejected.

Effort labels below express relative complexity, not calendar promises:
**S** is a localized change; **M** crosses a module or public contract; **L** spans
multiple modules and needs several commits.

## 4. Immediate implementation queue

These are the four priorities from the preceding discussion. Bounds checking is
large enough to require several slices; it should not be forced into one commit.

### Q1 — Correct signed and fractional CFF operands [S]

- [x] Decode byte-255 operands as signed fixed-point values before converting to
  the interpreter's numeric representation.
- [x] Add cases for positive and negative fractions, zero, boundary values, and
  truncated encodings. Include repeated fractional deltas whose accumulated
  movement reaches an integer coordinate.
- [x] Check coordinate conversion at the outline boundary. Keep the existing
  integer `Vertex` contract explicit; preserving fractional operands internally
  does not by itself provide fractional public vertices.
- [x] Reject out-of-range conversions through a defined error, or document and
  test the supported range before extending it.

**Done when:** synthetic charstrings demonstrate correct signs and accumulated
fractional movement, existing font rendering remains correct, and failures clean
up allocations.

Suggested commit: `Fix signed fixed-point CFF operand decoding`.

### Q2 — Extend the Type 2 interpreter [L]

Use the [Type 2 specification](https://adobe-type-tools.github.io/font-tech-notes/pdfs/5177.Type2.pdf)
to inventory arithmetic, stack, storage, and conditional operators. Implement
these in cohesive groups rather than adding isolated switch cases without stack
semantics.

- [x] Add arithmetic operations with explicit operand-count and result checks.
- [x] Add stack manipulation with underflow, overflow, and index validation.
- [x] Add per-glyph transient storage and conditional operations; prevent state
  from leaking between glyphs or the bounds and outline passes.
- [x] Define reproducible random-state initialization if `random` is supported.
  Both interpretation passes must produce consistent geometry.
- [x] Classify valid-but-unsupported operators separately from reserved or
  malformed encodings. Keep the supported-operator list in the documentation.
- [x] Audit supported path operators for operand-group sizes and subroutine
  behavior while adding interpreter coverage.

**Done when:** each newly supported operator has an independently specified
result, invalid stack/storage access returns an error, and bounds and outline
passes agree. Unsupported behavior is documented precisely.

Suggested commits:

1. `Implement Type 2 arithmetic and stack operators`
2. `Implement Type 2 transient storage and conditional operators`
3. `Validate Type 2 operator arity and interpretation consistency`

### Q3 — Establish bounded font reads [L]

Start with table ownership and ranges, then migrate each consumer. Bounds must be
relative to the enclosing table or glyph, not merely the whole file. The
[OpenType file format](https://learn.microsoft.com/en-us/typography/opentype/spec/otff)
defines the directory and table ranges used by this work.

- [x] Introduce a small checked binary-reader/table-view abstraction, with
  subtraction-based span checks and checked count/size arithmetic.
- [x] Validate the font header, directory extent, consumed table ranges, and
  required table sizes. Define handling of duplicate tags, unsupported versions,
  missing required data, and empty optional tables.
- [x] Validate the relationships between glyph counts, horizontal metric counts,
  metric records, and short/long location entries.
- [x] Bound each glyph to its own `loca` interval within `glyf`; validate contour
  endpoints, instructions, flag repeats, coordinate streams, and component data.
- [x] Apply the same approach to character maps, variation maps, legacy kerning,
  GPOS lookups, coverage tables, and class definitions.
- [x] Validate cross-table relationships, including CFF CharStrings counts and
  declared glyph counts, without inventing fallback values for malformed data.
- [x] Decide whether existing non-error-returning queries rely on validation at
  load time or gain checked variants. Keep this policy consistent across modules.

**Done when:** every supported public operation reads through a validated span,
malformed count/offset fixtures return documented outcomes, and all existing
valid-font fixtures still work. This milestone alone does not establish a broad
untrusted-font guarantee.

Suggested commits:

1. `Validate font directory ranges and metric tables`
2. `Bound TrueType glyph decoding by location intervals`
3. `Validate character map and variation subtable reads`
4. `Validate kerning and GPOS table reads`
5. `Enforce cross-table counts and document checked query behavior`

### Q4 — Add reproducible parser fuzzing [M]

- [ ] Add separate targets for loading, glyph lookup/metrics, outline decoding,
  and bounded bitmap rendering. Start the loader target after directory checks;
  extend targets as Q2 and Q3 land.
- [ ] Use the pinned compiler's supported fuzzing interface after inspecting its
  local implementation. Add replay of individual inputs and deterministic seeded
  mutation tests for fast CI coverage.
- [ ] Seed with small synthetic fonts and the bundled fixtures where licenses
  permit. Mutate lengths, counts, offsets, flags, instruction bytes, and recursion.
- [ ] Limit input size, interpreter work, decoded geometry, bitmap dimensions,
  and allocation budget in the harness. Enforce production limits separately.
- [ ] Run a bounded campaign, minimize failures, and check in regression cases
  with the fixing commit. Record duration, configuration, corpus, and open issues.
- [ ] Exclude the C reference parser from malformed-input fuzz targets; it is
  useful for comparing supported valid fonts, not as a safety oracle.

**Done when:** failures can be replayed with a documented command, a clean
checkout can run the targets, and the completed campaign has an evidence record.
A finite fuzz run supplements review and tests; it does not prove parser safety.

Suggested commits:

1. `Add font parser fuzz targets and deterministic replay`
2. Separate fixes for discovered defects, each with its minimized regression.

## 5. Milestone A — Reliable static-font core

Dependencies: Q1–Q3; Q4 should run continuously as coverage grows.

### A1 — Public input and error contracts [M]

- [x] Define supported scales, shifts, glyph indices, and pixel dimensions.
  Explicitly decide behavior for zero, negative, non-finite, and extreme values.
- [x] Check bitmap dimensions and byte-count multiplication before allocation.
- [ ] Distinguish missing glyphs, empty outlines, unsupported features, malformed
  data, exhausted memory, and exceeded resource limits where callers need it.
- [x] Preserve pre-existing output pixels on failed renders and leave workspaces
  reusable after failure.
- [x] Decide how checked bounding-box queries report malformed glyphs; currently
  an optional box can hide a parsing failure as an absent box.

**Exit evidence:** table-driven parameter tests, error-path tests, and public
API documentation covering each outcome.

### A2 — Resource limits and numeric behavior [M]

- [ ] Retain recursion guards and add total-work limits where shallow but repeated
  calls/components can still expand excessively.
- [ ] Bound interpreter instructions, emitted vertices, contour/edge counts, and
  requested bitmap memory using a coherent limits policy.
- [ ] Audit integer accumulation, float-to-integer conversion, transformed bounds,
  and extreme curve subdivision. Preserve endpoints at subdivision limits or
  return a defined error.
- [ ] Test that limits terminate excessive inputs while allowing the representative
  valid-font corpus. Document defaults and any caller overrides.

**Exit evidence:** deterministic tests for recursion, expansion, arithmetic
extremes, and allocation limits; no accidental reliance on Debug assertions for
public input validation.

### A3 — Module boundaries [M]

Refactor where the preceding changes reveal a coherent responsibility:

| Module responsibility | Intended ownership |
| --- | --- |
| Public facade | Public API, borrowed font lifetime, compatibility wrappers |
| Font container / checked reader | Table ranges and binary access |
| TrueType outlines | `loca`/`glyf` decoding and composite assembly |
| CFF | CFF structure validation and Type 2 interpretation |
| Character maps | Base and variation-sequence glyph lookup |
| Metrics and kerning | Metric records and supported positioning queries |
| Rasterizer | Flattening, coverage, scratch lifetime, bitmap generation |

- [ ] Extract TrueType outlines from the public facade once bounded table views
  provide a stable interface.
- [x] Extract metrics/kerning when their checked reads are established.
- [ ] Keep helpers with their owning module; avoid a general utility module that
  obscures which table or allocation a function owns.
- [ ] Remove or repurpose the currently unused `debug-todo` build option with a
  documented compatibility decision.

**Exit evidence:** behavior-preserving test results and a dependency structure
with no circular ownership or newly required global state.

### A4 — Broader correctness corpus [M]

- [ ] Add small synthetic fixtures for format branches, not only large fonts.
- [ ] Expand valid-font coverage across TrueType/CFF, CID subroutines, composites,
  supplementary mappings, empty glyphs, and placement/advance records.
- [ ] Record font provenance, redistribution permission, and checksums. Prefer
  compact extracted fixtures where permitted; keep large optional corpora external.
- [ ] Retain independent geometry/area tests. Use stb comparisons only within its
  supported behavior and document local reference adaptations.
- [ ] Add a second development-only rendering reference where it resolves a real
  coverage gap, with matching hinting and scale settings and justified tolerances.

**Exit evidence:** a feature-to-test matrix and explicit explanations for
intentional reference differences.

## 6. Milestone B — Predictable memory and measured performance

Dependencies: stable ownership contracts from A1; preserve correctness gates.

### B1 — Make allocation goals testable [M]

Replace the broad heap-allocation roadmap item with three distinct guarantees:

| Mode | Intended guarantee |
| --- | --- |
| One-shot rendering | Caller-supplied allocator; all temporary allocations released on success and failure |
| Reused workspace | No backing-allocator calls for a warmed workload that fits retained capacity |
| Fixed-budget rendering | Caller-provided output and scratch storage; no fallback heap allocation; defined exhaustion error |

- [ ] Demonstrate fixed-buffer allocators with the existing API before designing
  a new scratch interface. Test both sufficient and insufficient storage.
- [ ] Document whether zero backing calls include output growth; output reuse must
  be stated independently from temporary workspace reuse.
- [ ] Test mixed glyphs, size changes, large-then-small workloads, release, and
  recovery after exhaustion. Use separate workspaces for concurrent callers.
- [ ] Evaluate a retained-memory cap/release policy based on those measurements.
  Preserve existing defaults unless an API change is justified.
- [ ] Add scratch-capacity estimation only if callers need a stronger guarantee
  than a fixed budget and a recoverable exhaustion error.

**Exit evidence:** executable examples and allocation-count/failure tests for all
advertised modes. “Heap-free” must name the mode and storage assumptions.

### B2 — Profile before optimizing [M]

- [ ] Extend measurements to cold rendering, real text, changing sizes, and
  difficult glyphs. Keep warm/cold results separate.
- [ ] Measure decoding, flattening, edge processing, and coverage work to find
  the dominant costs. Keep profiling instrumentation outside published timings.
- [ ] Record median and spread, compiler/build settings, allocator, CPU, glyph
  selection, output equivalence, and retained/peak requested memory.
- [ ] Optimize one measured bottleneck per commit, then compare against the saved
  baseline under the same workload and build settings.
- [ ] Evaluate typed reusable buffers, fewer passes, or contour caching only when
  profiles support them. Define cache keys, ownership, bounds, and invalidation
  before adding any cache; avoid hidden process-wide caches.

**Exit evidence:** reproducible measurements supporting each retained
optimization. Correctness regressions or unexplained memory growth block it.
There is no fixed speedup target before a bottleneck has been measured.

## 7. Milestone C — Stable core release

Dependencies: A and B's documented memory contracts; bounded fuzzing evidence.
Performance work may continue after release when no correctness issue remains.

### C1 — Automation and portability [M]

- [ ] Pin a tested Zig toolchain in CI. Keep the manifest's minimum version
  distinct from an exact supported development-build pin.
- [ ] Run formatting, Debug tests, ReleaseSafe tests, and short deterministic
  malformed-input/fuzz-replay checks on each change.
- [ ] Add longer fuzz campaigns as scheduled or manually invoked jobs.
- [ ] Test Linux, macOS, and Windows where runners are available; include x86_64
  and aarch64 coverage. Report cross-compilation separately from runtime tests.
- [ ] Record benchmark artifacts on a stable runner. Use timing thresholds only
  after normal variance is understood; enforce exact allocation invariants in tests.
- [ ] Verify that a downstream package can import the library and build examples
  using only the files included in the package manifest.

### C2 — API, documentation, and packaging [M]

- [ ] Publish a support matrix for containers, outline formats, cmap formats,
  positioning, hinting, and unsupported font technologies.
- [ ] Add compiling examples for one-shot rendering, workspace reuse, variation
  selectors, fixed-budget rendering, and error recovery.
- [ ] Document font-byte lifetime, scratch/output ownership, thread usage,
  coordinate conventions, supported inputs, limits, and error behavior.
- [ ] Audit public implementation details such as `CharstringCtx` and decide
  whether to support, deprecate, or internalize them before API stabilization.
- [ ] Review package contents, reference/font licenses, versioning, changelog,
  migration notes, and toolchain support.

### Core release gate

- [ ] All advertised static-font features have fixtures and documented outcomes.
- [ ] All selected CI gates pass on the declared supported targets.
- [ ] No known crashes, leaks, unchecked supported-parser reads, or unbounded
  input-driven expansion remain in the release scope.
- [ ] Fuzz regressions are fixed or explicitly block the affected feature.
- [ ] Workspace and fixed-budget claims have executable evidence.
- [ ] A clean downstream consumer can build and run the documented examples.
- [ ] Compatibility changes and remaining limitations are visible to users.

Keep the current untrusted-font limitation until the complete supported parsing
surface and resource limits have been reviewed and tested. Any later support
claim must state its scope and residual limitations; fuzzing alone is not enough.

## 8. Milestone D — Small-size rendering and hinting

This is a distinct rendering-quality project after the core release gates are
stable. CFF hinting and the TrueType instruction engine need separate designs.

- [ ] Establish image-quality fixtures at small pixel sizes and document the
  current unhinted baseline, including fractional shifts and unequal scales.
- [ ] Decide how hinting is selected and which coordinate stage receives it.
  Preserve an explicit unhinted mode for compatibility and reference comparisons.
- [ ] Implement scale-aware CFF flex behavior with focused shallow-curve tests.
- [ ] Design CFF stem/mask hint application, then implement in testable stages.
- [ ] Scope a TrueType instruction engine separately, including state, arithmetic,
  resource budgets, error policy, and valid-font conformance fixtures.
- [ ] Compare with an appropriate reference at matching settings; document
  intentional rendering differences instead of adjusting tests to hide them.

**Exit gate:** the support matrix identifies the exact hinting subset; quality
improvements are demonstrated without breaking unhinted rendering or limits.
Full hinting should not be hidden inside a generic “remove TODOs” commit.

## 9. Milestone E — Text shaping and layout

A glyph rasterizer and a text shaper have different responsibilities. Build a
separate layer that produces positioned glyph runs and feeds the existing
renderer. The
[OpenType layout common structures](https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2)
provide the script/language/feature selection framework for layout tables.

### E1 — Integration contract [M]

- [ ] Define a shaped glyph run with glyph IDs, advances, offsets, source-cluster
  mapping, direction, and font identity.
- [ ] Document the boundary between shaping, bidirectional ordering, font fallback,
  line breaking, and glyph rasterization. Assign each responsibility explicitly.
- [ ] Add an example consuming externally shaped runs without making an external
  shaping library a required runtime dependency of the renderer.

### E2 — Incremental native shaping [L]

- [ ] Establish script/language/feature selection and bounded layout-table readers.
- [ ] Implement a narrow first subset with substitution and positioning fixtures,
  such as selected Latin ligatures and pair positioning.
- [ ] Extend positioning beyond the current scalar kerning query through the glyph
  run API, including offsets and both glyphs' adjustments where applicable.
- [ ] Add contextual substitution, marks, and script-specific processing only with
  a declared coverage goal and conformance corpus for each expansion.
- [ ] Use a mature shaper as a development reference; preserve cluster mapping
  and test reordered/combined glyph sequences, not only rendered screenshots.

**Exit gate for each subset:** supported scripts/features, input conventions, and
unsupported behavior are documented and tested. General HarfBuzz-level coverage
is a long-term program, not a prerequisite for a stable bitmap-rendering library.

## 10. Later extensions and explicit scope decisions

Evaluate these against actual users and a dedicated proposal before adding them
to the active queue:

| Extension | Required decision before implementation |
| --- | --- |
| Font collections | Face-selection API, shared-table ownership, and validation model |
| Variable fonts and CFF2 | Variation coordinates, outline/metric changes, and cache identity |
| Color glyphs | Supported formats and a richer rendering/output contract |
| WOFF/WOFF2 containers | Decompression dependencies and decoded-size limits |
| Atlas packing and bitmap caching | Whether this belongs in a companion package or example; memory budget and eviction |
| Fractional public outlines | Versioned geometry representation and compatibility with current integer vertices |
| Vertical text | Metrics, positioning, and shaping responsibilities |

These extensions are not implicit requirements for the core release. Once one
is selected, give it the same scope, fixtures, resource limits, and exit gate as
other milestones.

## 11. Validation commands and evidence

Use the exact currently tested compiler, `0.17.0-dev.2281+83624acf6`, until a
separate toolchain-update slice changes it. The commands below assume `zig`
resolves to that compiler; the system default in the current development
environment was previously too old.

Existing commands:

```sh
zig version
zig build test -Dtest-filter=CFF --summary all
zig build test -Dtest-filter=rasterizer --summary all
zig build test --seed=0x3abb56a7 --summary all
zig build test -Doptimize=ReleaseSafe --seed=0x3abb56a7 --summary all
zig build bench -Doptimize=ReleaseFast > benchmarks/local-results.csv
```

Format touched Zig files and run `git diff --check` before committing. Keep local
benchmark output separate from the recorded baseline unless intentionally
updating it. Fuzz/replay and example-build commands are deliverables of future
slices; they do not exist yet and must be documented when added.

Choose checks according to the change:

| Change | Required evidence |
| --- | --- |
| Parser/interpreter | Targeted valid and malformed fixtures; allocation failures where applicable; Debug and ReleaseSafe suites |
| Rasterizer | Independent geometry/coverage checks, affected valid-font comparisons, allocation regressions |
| Ownership/workspace | Exhaustion, cleanup, output lifetime, recovery, and allocation-count tests |
| Refactoring | Existing behavior checks and affected public entry points compiled |
| Performance | Correct output plus comparable before/after timing and memory results |
| Public API/package | Compiling downstream examples, ownership/error docs, and migration notes |
| Documentation only | Correct paths, links, commands, and consistency with implemented behavior |

Do not treat the existing 34-test count as a permanent quota. Add tests for new
behavior and failures; a larger number alone is not evidence of broader coverage.

## 12. Execution order and next action

1. Finish Q1 and the first Q2 operator group as small correctness commits.
2. Start Q3's directory/metric validation; bring up Q4's loader/replay harness.
3. Complete Q2/Q3 coverage while Q4 preserves discovered regressions.
4. Close Milestone A's public contracts, resource limits, module boundaries, and
   corpus gaps.
5. Establish B1's documented memory modes; use B2 measurements to select optional
   optimizations.
6. Complete CI, examples, packaging, and the core release checklist in C.
7. Select D, E, or a later extension based on the next concrete rendering or
   typography requirement. Keep those releases independently usable.

**Next implementation slice:** Q3, font directory and metric validation.

For every completed slice, append a short record here or link its commit with:
what changed, the regression/acceptance evidence, any public behavior change,
and the next unresolved dependency.

## Implementation record

- Q1: signed 16.16 operands now retain fractions in an `f64` interpreter; public
  integer vertices still truncate toward zero. Coordinates outside the `i16`
  vertex range return `CoordinateOutOfRange` in the counting pass. Regression
  fixtures reproduce the previous negative-value crashes and cover fractional
  accumulation, fixed-point extremes, and endpoint/control-point overflow.
  `CharstringCtx` coordinate fields now use `f64`; consumers relying on that
  implementation type should migrate to `glyphShape` and `glyphBox`.
  Validation: 34 font/API tests passed in Debug and ReleaseSafe; the three
  rasterizer tests remained cached and unchanged (37 tests across both roots).

- Q2 arithmetic/stack slice: implemented `abs`, `add`, `sub`, `div`, `neg`,
  `drop`, `mul`, `sqrt`, `dup`, `exch`, `index`, and `roll` in `type2.zig`.
  Invalid numeric domains/indices return `InvalidCffOperand`; non-finite results
  return `CffNumericOverflow`. Subroutine indices now require checked integers.
  Independent charstring fixtures cover results, preserved operands, signed
  rotation, fractions, stack overflow/underflow, and arithmetic overflow.
  Validation: 36 font/API tests passed in Debug and ReleaseSafe; three unchanged
  rasterizer tests remained cached (39 tests across both roots).

- Q2 storage/conditionals slice: added 32 checked transient slots, `put`, `get`,
  `and`, `or`, `not`, `eq`, `ifelse`, and deterministic per-glyph `random`.
  Uninitialized reads return `UninitializedCffStorage`; state is fresh for each
  interpretation pass and shared only by that pass's subroutines. Tests cover
  last-slot access, invalid indices, stack arity, all conditional branches,
  random reproducibility, and subroutine stack/storage sharing.
  Validation: 39 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (42 tests across both roots).

- Q2 arity slice: path/flex operators now require complete operand groups;
  optional width is consumed once; drawing requires a preceding move; stem
  counts and mask use are checked. Reserved escape codes return
  `ReservedOperator`, deprecated dotsection is ignored, and the deprecated
  endchar composite form returns `UnsupportedCffSeac` instead of a blank outline.
  Tests cover excess operands, width-bearing operators, invalid masks,
  missing endchar, return outside subroutines, and unsupported composites.
  Validation: 42 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (45 tests across both roots).

- Q3 directory/metrics slice: added `reader.zig` for checked spans, records, and
  big-endian reads, and `sfnt.zig` for directory/metadata validation. Font loading
  retains table lengths, requires coherent maxp/hhea/hmtx/loca sizes, validates
  cmap encoding-record bounds, and checks CFF glyph-count agreement. Supported
  container signatures are sfnt TrueType, OTTO, and legacy `true`; consumed
  duplicate tags are rejected. Empty optional tables require a valid directory
  offset; their contents remain subject to the later table-reader slices.
  Regression fixtures cover truncated headers/tables, bad offsets, duplicate
  tags, missing metadata, metric counts, and escaping cmap records.
  Validation: 45 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (48 tests across both roots).

- Q3 TrueType glyph slice: all outline reads are bounded by the glyph's own
  `loca` interval. Contour endpoints, flag repeats, instructions, component
  transforms, and coordinate conversions are checked. One-point off-curve
  contours no longer read a following point. Truncation fixtures put another
  valid glyph immediately after the truncated one to verify isolation.
  Synthetic direct-struct fixtures now supply table lengths; callers should
  construct fonts with `load`, not fill implementation fields manually.
  Validation: 48 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (51 tests across both roots).

- Q3 cmap slice: load-time validation checks subtable lengths, sorted ranges,
  nested records, and format-specific array spans. Lookup reads are bounded to
  each subtable; format 4 derives its search from segment counts instead of
  trusting search hints. Added `codepointGlyphIndexChecked` and
  `codepointVariationGlyphIndexChecked`; convenience APIs return `.notdef`/null
  on errors, while checked variants distinguish malformed data and reject
  out-of-range glyph IDs. The shared reader handles encoded 24-bit values as
  three bytes. Tests cover truncated arrays, huge counts, escaped offsets,
  malformed search hints, and checked/convenience error behavior.
  Validation: 51 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (54 tests across both roots). A new huge-count
  regression exposed a remaining format-14 arithmetic overflow during this slice;
  the final implementation checks record extent before searching.

- Q3 kerning slice: moved scalar kerning into `kerning.zig` with bounded
  GPOS lookup/extension, pair, coverage, class, and legacy kern reads. Added
  `glyphKernAdvanceChecked`; the convenience API retains a zero fallback.
  Unsupported lookup kinds retain the existing skip policy. Empty coverage
  searches use half-open intervals, and legacy pairs cannot escape their
  declared subtable. Prefix truncations and a maximal extension offset are
  covered by regression tests.
  Validation: 53 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (56 tests across both roots).

- Q3/A1 checked-query slice: extracted bounded metrics into `metrics.zig`, added
  checked metric/scale/outline/pixel-box queries, and documented convenience
  fallbacks. Horizontal advances now preserve the full unsigned u16 range;
  vertical scale arithmetic widens before subtraction. Rendering validates
  finite positive scales and finite shifts, checks pixel-box/dimension/offset
  representations before allocating, and preserves caller output on errors.
  Empty CFF bounds now return null consistently with empty TrueType outlines.
  Regression tests cover metric extremes, truncated metrics, invalid glyphs,
  non-finite/negative/zero parameters, oversized bitmaps, and workspace recovery.
  Validation: 56 font/API tests passed in Debug and ReleaseSafe, plus three
  unchanged cached rasterizer tests (59 tests across both roots).
