#!/bin/sh
set -eu
ZIG=${ZIG:-zig}
# Run serially; this compiler can share a fuzz cache identity across filters.
for target in loader queries outlines bitmaps; do
    "$ZIG" build fuzz -Duse-llvm=true -Doptimize=ReleaseSafe \
        -Dtest-filter="fuzz $target" --fuzz=1M --seed=0x3abb56a7 --summary all
done
"$ZIG" build fuzz-replay -Doptimize=ReleaseSafe -- 0x3abb56a7 1000000 all
