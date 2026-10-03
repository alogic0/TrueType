# Static-core release readiness

The current version remains `3.0.0-dev`. Local evidence includes strict parser
fixtures, bounded fuzzing, allocation/exhaustion tests, a manifest-only consumer,
compiling examples, and cross-compilation. This document does not publish a
release or declare all work in PLAN.md complete.

Before a stable tag:

- Activate the checked-in CI configuration on the repository's actual service
  and collect its results. Add native runtime runners before declaring macOS,
  Windows, or aarch64 runtime support; current results there are compilation only.
- Review the recorded four-million-execution native campaign and one million
  deterministic mutations; expand isolated coverage and review unsupported/untrusted-font
  wording against the complete supported surface. Preserve every failing case.
- Configure a stable benchmark runner and artifact destination before adopting
  timing regression thresholds. Allocation invariants already have exact tests.
- Review versioning and migration notes; preserve source, reference, and font
  licenses. The package excludes font binaries and C reference sources.
- Run `scripts/check.sh` from a clean checkout with the pinned compiler and
  inspect every result; then tag/publish only when the release is authorized.

Hinting and shaping are separate projects. Milestones D/E in PLAN.md require
quality/script requirements and independent designs; they are not silently
included in the static-glyph renderer's support claim.
