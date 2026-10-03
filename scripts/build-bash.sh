#!/bin/sh
# Build a static GNU bash for yos with `zig cc` (musl) and install it into prebuilt/bin/bash.
set -e
VER=5.2.37
ZIG=${ZIG:-zig}
TOP=$(pwd)
mkdir -p build/bash prebuilt/bin build/zcc
cat > build/zcc/cc <<EOS
#!/bin/sh
exec $(command -v $ZIG) cc -target x86_64-linux-musl "\$@"
EOS
cat > build/zcc/ar <<EOS
#!/bin/sh
exec $(command -v $ZIG) ar "\$@"
EOS
cat > build/zcc/ranlib <<EOS
#!/bin/sh
exec $(command -v $ZIG) ranlib "\$@"
EOS
chmod +x build/zcc/*
cd build/bash
[ -d bash-$VER ] || curl -sL https://ftp.gnu.org/gnu/bash/bash-$VER.tar.gz | tar xz
cd bash-$VER
CFLAGS="-O2 -std=gnu17 -w -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"
[ -f Makefile ] || CC=$TOP/build/zcc/cc AR=$TOP/build/zcc/ar RANLIB=$TOP/build/zcc/ranlib CC_FOR_BUILD=gcc CFLAGS="$CFLAGS" \
    ./configure --enable-static-link --without-bash-malloc --disable-nls
make -j"$(nproc)" LDFLAGS_FOR_BUILD="-rdynamic" CFLAGS="$CFLAGS"
cp bash "$TOP/prebuilt/bin/bash"
strip "$TOP/prebuilt/bin/bash" 2>/dev/null || true
ln -sf bash "$TOP/prebuilt/bin/sh"
echo "bash installed to prebuilt/bin/bash"
