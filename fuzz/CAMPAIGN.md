# Initial campaign — 2026-10-03

Environment: Linux x86_64, Zig `0.17.0-dev.2281+83624acf6`, ReleaseSafe.
Core under test: `4a09478`; harness introduced with this record.

- Five seed/triangle tests passed in Debug and ReleaseSafe.
- Deterministic mutation: seed `0x3abb56a7`, 100,000 inputs alternating the
  authored TrueType and existing CFF seeds; no panic or crash. The timed command
  took 18.45 seconds including compilation (17.60 user seconds, peak process RSS
  512,584 KiB including the compiler). This is not a renderer benchmark or a
  claim about harness live allocation usage.
- Native LLVM fuzzing: requested `--fuzz=10K` for loader, queries, outlines, and
  bitmaps. Each command passed. The loader reported 41,214 runs; the three
  explicitly filtered commands reported ranges 1,243→20,487, 0→19,300, and
  20,487→30,739 respectively. These latter runs shared the compiler's fuzz-cache
  identity and ran concurrently; do not sum them as independent unique inputs.
  Their reported execution steps took approximately 0.46–0.47 seconds, excluding
  compilation. Loader execution took approximately one second.
- Raw-font replay, Smith-encoded CFF replay, and mutation-index replay (123 of
  2,000 with seed `0x3abb56a7`) passed.
- No failing input required minimization in this campaign.

Commands and limits are in README.md in this directory. Open coverage work:
expand valid-format seeds, include CID/composite/variation/GPOS cases, use longer
campaigns, and record isolated cache statistics when comparing coverage. The
64 KiB input ceiling deliberately excludes the large bundled Noto font; normal
valid-font regression tests still exercise it. Existing untrusted-font support
limitations remain in place.

## Extended campaign after numeric hardening

Core: `e6b0f25`, same compiler/platform, ReleaseSafe; bitmap inputs now also
exercise extreme finite anisotropy. `scripts/fuzz-long.sh` ran the four native
targets serially with `--fuzz=1M --seed=0x3abb56a7`, then 1,000,000 deterministic
mutations with the same seed. All completed without a failure.

| Native target | Cumulative runs before → after | Execution duration |
| --- | ---: | ---: |
| Loader | 0 → 1,003,194 | 33 s |
| Queries | 1,003,194 → 2,006,781 | 34 s |
| Outlines | 2,006,781 → 3,009,999 | 35 s |
| Bitmaps | 3,009,999 → 4,013,610 | 36 s |

The compiler reports a shared cache identity, 13,545 cumulative unique runs, and
898/11,621 instrumented coverage locations at completion. Serial ranges avoid
the overlap caveat in the initial campaign, but these remain compiler counters,
not proof of exhaustive format coverage. Compilation took about 12 seconds per
filtered target, separate from execution durations. Deterministic replay then
reported all 1,000,000 mutations complete. The unit suite passed 70 tests in
Debug and ReleaseSafe; the numeric regression also passed in ReleaseFast.

The anisotropy assertion was found by an authored parameter test before this
campaign, fixed in `e6b0f25`, and retained in `test/contracts.zig`. No crash from
this extended fuzz campaign required minimization. Input/corpus limits and the
untrusted-font caveat above continue to apply.
