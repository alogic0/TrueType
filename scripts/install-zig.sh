#!/bin/sh
set -eu
# CI bootstrap for the declared Linux x86_64 runner. Other hosts install the pin
# in .zigversion themselves; cross-compilation is handled by check.sh.
version=$(cat .zigversion)
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) ;;
    *) echo 'Install the .zigversion compiler for this host manually.' >&2; exit 1 ;;
esac
archive="zig-x86_64-linux-$version.tar.xz"
mkdir -p .toolchain
curl --fail --location --retry 3 "https://ziglang.org/builds/$archive" -o ".toolchain/$archive"
printf '%s  %s\n' '9268a41aa95338b37f9e80694d458ddbbd3d975687c1b2b2d4082612a7cc1e30' ".toolchain/$archive" | sha256sum -c -
tar -xJf ".toolchain/$archive" -C .toolchain
".toolchain/zig-x86_64-linux-$version/zig" version
