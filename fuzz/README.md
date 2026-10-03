# Parser fuzzing and replay

Use Zig `0.17.0-dev.2281+83624acf6`. These targets do not compile or call stb.

```sh
zig build fuzz                         # corpus smoke tests, plus triangle check
zig build fuzz-replay                  # 2,000 deterministic mutations
zig build fuzz-replay -- font.ttf      # raw input, at most 64 KiB
zig build fuzz-replay -- --smith input # Smith slice serialization
zig build fuzz-replay -- 0x3abb56a7 100000 all
zig build fuzz-replay -- 0x3abb56a7 100000 123 # replay just mutation 123
```

Run each native target explicitly: a shared iteration limit can be consumed by
one test before the others get time. The limit is approximate; inspect the
reported runs. LLVM is required for native instrumentation on this toolchain.

```sh
zig build fuzz -Duse-llvm=true -Doptimize=ReleaseSafe -Dtest-filter='fuzz loader' --fuzz=10K
zig build fuzz -Duse-llvm=true -Doptimize=ReleaseSafe -Dtest-filter='fuzz queries' --fuzz=10K
zig build fuzz -Duse-llvm=true -Doptimize=ReleaseSafe -Dtest-filter='fuzz outlines' --fuzz=10K
zig build fuzz -Duse-llvm=true -Doptimize=ReleaseSafe -Dtest-filter='fuzz bitmaps' --fuzz=10K
```

`fuzz_tests.zig` uses the installed `std.testing.Smith.slice` interface. Corpus
entries are a little-endian u32 length followed by bytes. Keep the compiler's
reported failing input and reproduce it before minimizing; check minimized raw
fixtures into the relevant regression suite with their fix. Mutation-run panics
print their seed and iteration before the normal panic trace. Mutations change
bytes, bit flags, four-byte words, and truncation lengths in alternating seeds.

The authored 569-byte TrueType seed contains an empty glyph, a triangle, metrics,
and a format-0 cmap. The CFF seed reuses `test/StandardSymbolsPS.otf`; this adds no
new font asset. Font provenance/license review remains tracked in PLAN.md before
release or distributing a new standalone corpus.

Inputs are capped at 64 KiB. Each accepted font exercises five glyph IDs, five
codepoints, variation lookup, and kerning. Outlines/renders use a 2 MiB fixed
allocator, no heap fallback, 4,096 CFF tokens, 4,096 outline-work units, 64 glyph
visits, 8,192 flattened points, 65,536 pixels, and 2,000,000 coverage-work units.
Normal parser/resource/allocation errors are accepted; traps and panics fail.
The production defaults are separately documented in the root README. Existing
allocator-failure tests check cleanup; the bounded fuzz allocator does not serve
as a leak detector.

This initial corpus does not exercise every valid format or large font. Native
coverage totals include all compiled branches and are not a parser-completeness
percentage. A finite campaign is evidence, not a safety proof.
