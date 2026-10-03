#!/bin/sh
set -eu
ZIG=${ZIG:-zig}
export ZIG
expected=$(cat .zigversion)
actual=$("$ZIG" version)
if [ "$actual" != "$expected" ]; then
    echo "Expected Zig $expected, got $actual" >&2
    exit 1
fi
"$ZIG" fmt --check ./*.zig test/*.zig fuzz/*.zig examples/*.zig
"$ZIG" build test --seed=0x3abb56a7 --summary all
"$ZIG" build test -Doptimize=ReleaseSafe --seed=0x3abb56a7 --summary all
"$ZIG" build fuzz fuzz-replay examples --seed=0x3abb56a7 --summary all
python3 scripts/check-package.py
for target in aarch64-linux x86_64-windows aarch64-macos; do
    "$ZIG" build examples -Dtarget="$target" -Doptimize=ReleaseSafe --summary all
done
