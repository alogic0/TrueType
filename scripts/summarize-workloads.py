#!/usr/bin/env python3
"""Summarize uninstrumented samples; stage diagnostics stay separate."""
import csv
from collections import defaultdict
from pathlib import Path
import statistics
import sys

path = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmarks/workloads.csv")
groups = defaultdict(list)
with path.open() as source:
    for row in csv.DictReader(line for line in source if not line.startswith("#")):
        groups[row["font"], row["workload"], row["mode"]].append(row)
print("| Font / workload | One-shot median (min–max), ns/glyph | Workspace median (min–max), ns/glyph | Workspace backing calls | Scratch bytes |")
print("| --- | ---: | ---: | ---: | ---: |")
for font, workload in sorted({key[:2] for key in groups}):
    cells = []
    for mode in ("one_shot", "workspace"):
        rows = groups[font, workload, mode]
        samples = [int(row["elapsed_ns"]) / int(row["renders"]) for row in rows]
        cells.append(f"{statistics.median(samples):.0f} ({min(samples):.0f}–{max(samples):.0f})")
    row = groups[font, workload, "workspace"][0]
    calls = sum(int(row[name]) for name in ("alloc_calls", "resize_calls", "remap_calls"))
    print(f"| {font} / {workload} | {' | '.join(cells)} | {calls} | {row['retained_scratch_bytes']} |")
