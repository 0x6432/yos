#!/bin/sh
# Fetch build-time dependencies that are not vendored (Limine binaries).
set -e
mkdir -p deps
if [ ! -d deps/limine ]; then
    git clone --depth 1 --branch v9.x-binary https://github.com/limine-bootloader/limine.git deps/limine
fi
make -C deps/limine
