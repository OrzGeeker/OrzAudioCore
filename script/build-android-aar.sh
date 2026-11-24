#!/usr/bin/env bash
# ============================================================================
# Build the official OrzAudioCore Android AAR.
#
# Pipeline:
#   1. script/build-android.sh         -> core + third-party static archives
#   2. script/package-android-sdk.sh   -> merged libOrzAudioCore.a per ABI
#   3. CMake                           -> JNI bridge liborzaudio.so per ABI
#   4. Gradle                          -> AAR + sources jar
#
# Usage: build-android-aar.sh [--abi arm64-v8a] [--release-dir dir]
# Requires ANDROID_NDK_HOME and an Android SDK (ANDROID_HOME or sdkmanager).
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ORZ_RELEASE_DIR:-$ROOT/.cmake-build/release}"
ABIS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi) ABIS+=("$2"); shift 2 ;;
    --release-dir) OUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
(( ${#ABIS[@]} )) || ABIS=(arm64-v8a armeabi-v7a x86_64)
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
[[ -f "$NDK/build/cmake/android.toolchain.cmake" ]] || {
  echo "ANDROID_NDK_HOME must point at an Android NDK (r27+)" >&2; exit 2;
}
ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
[[ -d "$ANDROID_SDK" ]] || { echo "Android SDK not found: $ANDROID_SDK" >&2; exit 2; }
export ANDROID_HOME="$ANDROID_SDK"
API_LEVEL="${ORZ_ANDROID_API:-29}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)}"
VERSION="$(node -p "require('$ROOT/decoder-manifest.json').sdkVersion")"

for abi in "${ABIS[@]}"; do "$ROOT/script/build-android.sh" --abi "$abi"; done

SDK_STAGE="$OUT/android-sdk"
"$ROOT/script/package-android-sdk.sh" "$SDK_STAGE"

mkdir -p "$ROOT/SDK/Android/audio-core/src/main/jniLibs"
for abi in "${ABIS[@]}"; do
  build="$OUT/jni/$abi"
  rm -rf "$build"
  echo "[AAR] building JNI bridge for $abi"
  cmake -S "$ROOT/SDK/Android/audio-core/src/main/cpp" -B "$build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DORZ_PREBUILT_CORE="$SDK_STAGE/OrzAudioCore-$VERSION-android-full/android/$abi/libOrzAudioCore.a" \
    -DORZ_PREBUILT_INCLUDE="$SDK_STAGE/OrzAudioCore-$VERSION-android-full/native/include"
  cmake --build "$build" -j "$JOBS"
  dest="$ROOT/SDK/Android/audio-core/src/main/jniLibs/$abi"
  mkdir -p "$dest"
  cp "$build/liborzaudio.so" "$dest/"
  # JNI-only exports: third-party symbols must stay local.
  unexpected="$(nm -D --defined-only "$dest/liborzaudio.so" | awk '{print $3}' | grep -v '^Java_com_orzgeeker_audiocore_OrzAudioCore_' || true)"
  [[ -z "$unexpected" ]] || { echo "unexpected exported symbols in $abi liborzaudio.so:" >&2; echo "$unexpected" >&2; exit 1; }
done

# Bundle runtime metadata/licenses inside the AAR assets for offline auditing.
ASSETS="$ROOT/SDK/Android/audio-core/src/main/assets/orz"
rm -rf "$ASSETS"
mkdir -p "$ASSETS"
cp -R "$SDK_STAGE/OrzAudioCore-$VERSION-android-full/metadata" "$ASSETS/"
cp -R "$SDK_STAGE/OrzAudioCore-$VERSION-android-full/licenses" "$ASSETS/"

cd "$ROOT/SDK/Android"
./gradlew --no-daemon -PorzAudioCoreVersion="$VERSION" :audio-core:assembleRelease :audio-core:publishReleasePublicationToLocalRepository
# Move the C SDK tarball up to the release directory expected by CI.
mv "$SDK_STAGE"/OrzAudioCore-*.tar.gz "$SDK_STAGE"/OrzAudioCore-*.tar.gz.sha256 "$OUT/" 2>/dev/null || true
AAR="$ROOT/SDK/Android/audio-core/build/outputs/aar/audio-core-release.aar"
[[ -f "$AAR" ]] || { echo "AAR not produced" >&2; exit 1; }
cp "$AAR" "$OUT/OrzAudioCore-$VERSION-android-full.aar"
(cd "$OUT" && shasum -a 256 "OrzAudioCore-$VERSION-android-full.aar" > "OrzAudioCore-$VERSION-android-full.aar.sha256")
echo "$OUT/OrzAudioCore-$VERSION-android-full.aar"
