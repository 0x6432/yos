#!/bin/sh
# Build the initrd (USTAR archive) from rootfs/ plus built userland.
set -e
mkdir -p build/rootfs
[ -d rootfs ] && cp -a rootfs/. build/rootfs/
[ -x scripts/build-userland.sh ] && ./scripts/build-userland.sh build/rootfs
(cd build/rootfs && tar --format=ustar -cf ../initrd.tar .)
