#!/usr/bin/env bash
# Builds libUE4SS.so so that it loads on an old-glibc game server container.
# Run inside the image from Dockerfile, with the UE4SS source tree at /src and
# an output directory at /out:
#
#   docker build -t ue4ss-oldglibc .
#   docker run --rm -v /path/to/RE-UE4SS-Linux:/src -v "$PWD/out":/out \
#       -v "$PWD/build.sh":/build.sh ue4ss-oldglibc bash /build.sh
set -euo pipefail

TARGET_GLIBC="${TARGET_GLIBC:-2.28}"
BUILD_DIR="${BUILD_DIR:-build_linux}"

# libc++ is stricter than libstdc++ about transitive includes, and although
# this build uses libstdc++, force-including the standard headers costs nothing
# and removes a whole class of failure when the source tree drifts.
FORCE_INCLUDES="
-include cstdint -include cstddef -include type_traits -include utility
-include mutex -include memory -include string -include stdexcept
-include functional -include optional -include variant -include filesystem
-include span -include algorithm -include limits -include atomic
-include thread -include chrono -include vector -include array
-include unordered_map -include numeric -include ctime"

# Clang reports __cpp_concepts as 201907 because it has not implemented P2113,
# and libstdc++ 13 uses that value to gate all of C++23, including
# <expected>, which glaze requires. -std=c++23 has to be in the flags too, or
# CMake's own compiler check compiles at the default standard and chokes on the
# `requires` that the forced macro exposes.
CONCEPTS="-std=c++23 -Wno-builtin-macro-redefined -D__cpp_concepts=202002L"

echo "==> build host: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version | head -1)"

cd /src
rm -rf "$BUILD_DIR"

cmake -S . -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_C_COMPILER=clang-18 \
    -DCMAKE_CXX_COMPILER=clang++-18 \
    -DCMAKE_BUILD_TYPE=Game__Shipping__Linux \
    -DUE4SS_GUI=OFF \
    -DUE4SS_BUILD_TESTS=OFF \
    -DCMAKE_CXX_FLAGS="--gcc-toolchain=/usr -stdlib=libstdc++ ${CONCEPTS} ${FORCE_INCLUDES}" \
    -DCMAKE_SHARED_LINKER_FLAGS="--gcc-toolchain=/usr -stdlib=libstdc++ -static-libstdc++ -static-libgcc -pthread -ldl -lrt" \
    -DCMAKE_EXE_LINKER_FLAGS="--gcc-toolchain=/usr -stdlib=libstdc++ -static-libstdc++ -static-libgcc -pthread -ldl -lrt"

# Only the library is needed. The dev test executables link against a static
# libc++ that wants pthread symbols this old distro keeps in libpthread.
cmake --build "$BUILD_DIR" --target UE4SS --parallel "$(nproc)"

artifact="$(find "$BUILD_DIR" -name libUE4SS.so | head -1)"
test -n "$artifact"

cp "$artifact" /out/libUE4SS.debug.so
cp "$artifact" /out/libUE4SS.so
strip --strip-debug --strip-unneeded /out/libUE4SS.so

echo "==> stripped: $(stat -c%s /out/libUE4SS.so) bytes"
echo "==> debug symbols kept at /out/libUE4SS.debug.so"

# Lower the remaining glibc requirement. Building on 2.31 still leaves a few
# 2.29 references (exp, log, pow), and polyfill-glibc rewrites them to versions
# an older loader provides.
if [[ "${SKIP_POLYFILL:-0}" != "1" ]]; then
    if [[ ! -x /opt/polyfill-glibc/polyfill-glibc ]]; then
        echo "==> building polyfill-glibc"
        git clone --depth 1 -q https://github.com/corsix/polyfill-glibc.git /opt/polyfill-glibc
        (cd /opt/polyfill-glibc && ninja polyfill-glibc >/dev/null)
    fi
    /opt/polyfill-glibc/polyfill-glibc --target-glibc="$TARGET_GLIBC" /out/libUE4SS.so
    echo "==> retargeted to glibc ${TARGET_GLIBC}: $(stat -c%s /out/libUE4SS.so) bytes"
fi

echo "==> highest glibc still required:"
readelf -V /out/libUE4SS.so | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1
