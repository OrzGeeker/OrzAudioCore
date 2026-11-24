#!/usr/bin/env bash
# Build OrzAudioCore.xcframework.
#
# Usage: build-xcframework.sh [output-dir] [--profile full|builtin-lite]
#
# full: iOS device arm64, iOS simulator arm64+x86_64 and macOS arm64 static
#       slices built from the locked decoder archives (run build-ios.sh first
#       or let this script build it).
# builtin-lite: dependency-free iOS device/simulator slices.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.cmake-build/xcframework}"
PROFILE="builtin-lite"
if [[ "${1:-}" == --* ]]; then OUT="$ROOT/.cmake-build/xcframework"; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

log() { printf '[XCFRAMEWORK] %s\n' "$*"; }
err() { printf '[XCFRAMEWORK] %s\n' "$*" >&2; exit 1; }

HEADERS="$ROOT/.cmake-build/apple-headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$ROOT/Sources/OrzAudioKitCXX/include/orz_audio_core.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module OrzAudioCore {
  header "orz_audio_core.h"
  export *
}
EOF

# Clear any stale xcframework so xcodebuild cannot append duplicate slices.
rm -rf "$OUT/OrzAudioCore.xcframework"
mkdir -p "$OUT"

merge_static() {
  local core="$1" deps="$2" output="$3"
  local archives=("$core")
  for lib in openmpt gme sidplayfp binio adplug sc68 asap v2m ahx2play; do
    [[ -f "$deps/lib$lib.a" ]] || err "missing $deps/lib$lib.a"
    archives+=("$deps/lib$lib.a")
  done
  # A static OrzAudioCore archive does not embed its dependencies. Merge them
  # so SwiftPM/CMake consumers link one file, exactly like the Android asset.
  libtool -static -o "$output" "${archives[@]}"
}

if [[ "$PROFILE" == "full" ]]; then
  if [[ ! -f "$ROOT/.cmake-build/macos-arm64-full/libOrzAudioCore.a" ||
        ! -f "$ROOT/.cmake-build/ios-device-full/libOrzAudioCore.a" ||
        ! -f "$ROOT/.cmake-build/ios-simulator-full/libOrzAudioCore.a" ]]; then
    "$ROOT/script/build-ios.sh" --profile full
  fi
  DEVICE="$ROOT/.cmake-build/ios-device-full/libOrzAudioCore.a"
  SIMULATOR="$ROOT/.cmake-build/ios-simulator-full/libOrzAudioCore.a"
  MACOS="$ROOT/.cmake-build/macos-arm64-full/libOrzAudioCore.a"
  for library in "$DEVICE" "$SIMULATOR" "$MACOS"; do
    [[ -f "$library" ]] || err "missing static slice: $library"
  done
  log "Merging decoder archives into the static slices"
  rm -rf "$OUT/merged"
  mkdir -p "$OUT/merged/ios-device" "$OUT/merged/ios-simulator" "$OUT/merged/macos"
  merge_static "$DEVICE" "$ROOT/.cmake-build/apple/deps/ios-device" "$OUT/merged/ios-device/libOrzAudioCore.a"
  merge_static "$SIMULATOR" "$ROOT/.cmake-build/apple/deps/ios-simulator" "$OUT/merged/ios-simulator/libOrzAudioCore.a"
  merge_static "$MACOS" "$ROOT/.cmake-build/apple/deps/macos-arm64" "$OUT/merged/macos/libOrzAudioCore.a"
  log "Creating full-profile xcframework (device/simulator/macOS)"
  xcodebuild -create-xcframework \
    -library "$OUT/merged/ios-device/libOrzAudioCore.a" -headers "$HEADERS" \
    -library "$OUT/merged/ios-simulator/libOrzAudioCore.a" -headers "$HEADERS" \
    -library "$OUT/merged/macos/libOrzAudioCore.a" -headers "$HEADERS" \
    -output "$OUT/OrzAudioCore.xcframework"
else
  "$ROOT/script/build-sdk.sh" ios-device-lite
  "$ROOT/script/build-sdk.sh" ios-simulator-lite
  DEVICE="$ROOT/.cmake-build/ios-device-lite/libOrzAudioCore.a"
  SIMULATOR="$ROOT/.cmake-build/ios-simulator-lite/libOrzAudioCore.a"
  log "Creating builtin-lite xcframework (device/simulator)"
  xcodebuild -create-xcframework \
    -library "$DEVICE" -headers "$HEADERS" \
    -library "$SIMULATOR" -headers "$HEADERS" \
    -output "$OUT/OrzAudioCore.xcframework"
fi

# xcodebuild copies Headers, but older Xcode versions drop the modulemap when
# the headers directory is shared; assert and repair every slice.
for slice in "$OUT/OrzAudioCore.xcframework"/*; do
  [[ -d "$slice" ]] || continue
  mkdir -p "$slice/Headers"
  cp "$ROOT/Sources/OrzAudioKitCXX/include/orz_audio_core.h" "$slice/Headers/"
  cp "$HEADERS/module.modulemap" "$slice/Headers/"
done

log "Wrote $OUT/OrzAudioCore.xcframework"
