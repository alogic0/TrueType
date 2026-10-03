# Cold, text, mixed-size, and complex-glyph baseline

Recorded 2026-10-03 on Linux x86_64, AMD Ryzen 7 7840HS, Zig
`0.17.0-dev.2281+83624acf6`, ReleaseFast, `smp_allocator`. Library baseline:
`529b170`; this slice adds profiling without changing normal rendering behavior.

```sh
zig build bench-workloads -Doptimize=ReleaseFast > benchmarks/workloads.csv
python3 scripts/summarize-workloads.py benchmarks/workloads.csv
```

Each workload renders 16 glyphs 50 times per sample, with seven samples and
alternating API order. Text uses `Hello, Zig!` plus Greek, Cyrillic, and Japanese
codepoints; unsupported characters use `.notdef`. Warm text is 32 pixels; mixed
sizes cycle through 12/96/24/48. Complex glyphs are the 16 largest decoded vertex
counts among the original 128 uniformly sampled glyph IDs, also at 32 pixels.
Selection and font loading are outside timing. Cold mode releases both output
and scratch before every glyph; warm modes retain both, after two warm-up passes.

All bitmap metadata and pixels are compared across API/allocator modes before
timing. Timers use the unwrapped allocator. Allocation counts and requested
peak/final retained bytes come from a separate matching run. Final retained
scratch is not peak scratch; an empty final glyph can leave cold scratch at zero.

Stage diagnostics run separately for 160 glyphs per workload. Decode includes
outline allocation; flatten includes flattened-buffer construction; edges
includes edge construction/sort; coverage includes scan conversion and edge
cleanup. Each diagnostic bitmap is checked against the public renderer. Stages
exclude font lookup, bounds queries, output allocation, and some cleanup, so
summing them does not reproduce end-to-end timing. Diagnostic clock overhead
matters for short stages. Production rendering specializes the observer to void,
with no clock calls or profiling callbacks.

Linux perf sampling was unavailable (`perf_event_paranoid=4`); no system settings
were changed. These are local measurements, not a stable CI performance gate.
| Font / workload | One-shot median (min–max), ns/glyph | Workspace median (min–max), ns/glyph | Workspace backing calls | Scratch bytes |
| --- | ---: | ---: | ---: | ---: |
| Noto / cold_text | 1182 (1146–1519) | 1206 (1174–1228) | 4350 | 5462 |
| Noto / complex_glyphs | 6494 (6405–7554) | 6818 (6783–6930) | 0 | 23686 |
| Noto / mixed_sizes | 1669 (1659–1682) | 1679 (1656–1686) | 0 | 9672 |
| Noto / warm_text | 1333 (1260–1712) | 1173 (1153–1856) | 0 | 7280 |
| Symbols / cold_text | 2977 (2959–3048) | 3289 (3259–3357) | 4750 | 0 |
| Symbols / complex_glyphs | 7965 (7853–8215) | 8167 (7956–8361) | 0 | 35030 |
| Symbols / mixed_sizes | 3548 (3530–3569) | 3656 (3647–3674) | 0 | 34492 |
| Symbols / warm_text | 2955 (2942–3016) | 3032 (3026–3110) | 0 | 8644 |

The warm workspace made zero backing allocation/resize/remap calls in all six
warm workloads. Cold workspaces allocated repeatedly and offered no measured
benefit. Timing differences remain workload dependent; the Noto warm-text sample
has substantial spread. Coverage and edges dominate the measured Noto stages.
CFF decoding is a substantial contributor for Symbols, particularly its complex
glyphs. Rendering currently interprets CFF for shape counting, shape emission,
and again for bounds; reusing bounds from the counting pass is a concrete next
experiment. No caching or typed-buffer redesign is justified by these results.

## CFF bounds reuse experiment

`workloads-cff-bounds.csv` repeats the same workload and settings after returning
bounds together with the CFF outline. Bitmap checksums and every allocation,
peak-memory, retained-memory, and output-capacity column match the baseline.
Symbols medians improved 11.2–14.7% for one-shot rendering and 11.6–12.5% for
workspace rendering across the four workloads. Noto medians changed -3.6% to
+2.1%, consistent with local run variation; its decoding path is unchanged.
This supports retaining this specific removal of a redundant CFF interpretation
pass. It does not establish a general speedup for workspaces or other fonts.

## Final numeric checks

`workloads-checked.csv` records the final rasterizer after numeric assertions
became recoverable errors (`e6b0f25`). All output hashes and allocation/memory
columns still match the baseline. Compared with `workloads.csv`, local Noto
medians increased about 12–17%; Symbols medians remain about 3–12% lower. The
narrow CFF bounds experiment above isolates the optimization; the final timings
also include the cost of runtime numeric checks. Correctness takes precedence
over recovering that cost. Further optimization needs stage evidence and must
preserve the extreme-scale error/recovery contract.
