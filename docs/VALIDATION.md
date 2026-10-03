# Validation and CI

The exact tested compiler is pinned in `.zigversion`; the manifest minimum is a
separate downstream compatibility constraint. On Linux x86_64,
`scripts/install-zig.sh` downloads the pin and verifies SHA-256. Other hosts can
install that same version themselves. Local commands use the system `zig` from
`PATH`; `zig version` should match `.zigversion`.

```sh
zig version
sh scripts/check.sh
sh scripts/fuzz-long.sh
python3 scripts/check-package.py
```

The scripts also accept an optional `ZIG` environment override. CI uses that
override to select its downloaded compiler inside the container.

The check script runs formatting, Debug and ReleaseSafe tests, bounded fuzz seed
and mutation checks, example builds, and an isolated consumer assembled solely
from the manifest. It cross-compiles examples for aarch64 Linux, x86_64 Windows,
and aarch64 macOS. Cross-compilation does not establish runtime correctness.

The repository's remote is Codeberg. `.woodpecker.yml` runs the check script on
push/PR/manual/cron events, and extended fuzzing on manual/cron events. It uses
[Woodpecker's event filters](https://woodpecker-ci.org/docs/usage/workflow-syntax).
Hosted activation and a cron schedule must be configured in the repository's
CI service; committing this file does not activate a runner. See
[Codeberg's CI documentation](https://docs.codeberg.org/ci/).
No remote pipeline or non-Linux runtime result is claimed by this checkout.

Benchmark output remains an explicit artifact (`zig build bench
-Doptimize=ReleaseFast > benchmarks/local-results.csv`). A stable benchmark
runner/artifact destination has not been configured. Allocation invariants are
asserted in tests; timing thresholds remain disabled until runner variance is
measured. Keep compiler, CPU, allocator, workload, and sample spread with any
published result.

## Reference scope

The bundled stb reference is only called on supported valid fixtures. The local
header adds extension-positioning traversal; test code compacts selected value
records for its scalar kerning comparison. It does not validate malformed fonts
and is never used by fuzz targets. Composite attachment, Type 2 arithmetic,
variation lookup, resource limits, and API failures have authored expected-value
fixtures. Rasterizer tests independently integrate curve and clipped-triangle
coverage rather than relying solely on pixel agreement with stb.

A second rendering engine remains optional development work: introduce it when
a concrete geometry/coverage disagreement needs an independent resolution, with
matching unhinted settings and an explicit tolerance. It is not a production
runtime dependency.
