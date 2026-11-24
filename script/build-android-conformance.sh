#!/usr/bin/env bash
# Build the native conformance probe for the Android x86_64 emulator.
#
# Usage: build-android-conformance.sh [--out <binary>]
# Requires ANDROID_NDK_HOME and the decoder sources fetched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABI="${ORZ_ANDROID_CONFORMANCE_ABI:-x86_64}"
API="${ORZ_ANDROID_API:-29}"
BUILD="$ROOT/.cmake-build/android-$ABI-conformance"
OUT="${1:-$BUILD/orz_conformance}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
[[ -f "$NDK/build/cmake/android.toolchain.cmake" ]] || { echo "ANDROID_NDK_HOME is required" >&2; exit 2; }
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)}

"$ROOT/script/build-android.sh" --abi "$ABI" --skip-manifest-check
rm -rf "$BUILD"
cmake -S "$ROOT" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
    -DORZ_PROFILE=full -DORZ_BUILD_TESTS=ON -DORZ_BUILD_SHARED=OFF \
    -DORZ_NATIVE_LIB="$ROOT/.wasm-build/native-android-$ABI"
cmake --build "$BUILD" --target orz_conformance -j "$JOBS"
[[ -x "$OUT" ]] || OUT="$BUILD/orz_conformance"
[[ -x "$OUT" ]] || { echo "orz_conformance not produced in $BUILD" >&2; exit 1; }
echo "$OUT"
