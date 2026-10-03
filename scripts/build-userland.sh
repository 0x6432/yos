#!/bin/sh
# Build the small Zig userland programs into <rootfs>/bin
set -e
ROOT=${1:-build/rootfs}
ZIG=${ZIG:-zig}
mkdir -p "$ROOT/bin" build/userland-cache
for src in userland/*.zig; do
    name=$(basename "$src" .zig)
    "$ZIG" build-exe -target x86_64-linux-none -O ReleaseSmall -fstrip -fsingle-threaded \
        --cache-dir build/userland-cache --global-cache-dir build/userland-cache \
        -femit-bin="$ROOT/bin/$name" "$src"
done
rm -f "$ROOT"/bin/*.o
# extra prebuilt binaries (e.g. bash) dropped into prebuilt/
if [ -d prebuilt ]; then cp -a prebuilt/. "$ROOT/"; fi
