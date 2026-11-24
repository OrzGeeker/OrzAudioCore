#!/usr/bin/env bash
# Package a native OrzAudioCore SDK artifact.
#
# Usage: package-sdk.sh [preset] [output-dir]
#   preset defaults to builtin-lite
#
# Canonical asset name: OrzAudioCore-<version>-<platform>-<profile>.tar.gz
# Override platform/profile inference with ORZ_PLATFORM / ORZ_PROFILE_NAME.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${1:-builtin-lite}"
OUT="${2:-$ROOT/.cmake-build/release}"
VERSION="$(node -p "require('$ROOT/decoder-manifest.json').sdkVersion")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

case "$PRESET" in
  macos-arm64)       platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-x86_64)      platform="${ORZ_PLATFORM:-macos-x86_64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-arm64-full)  platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-arm64-lite)  platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-builtin-lite}" ;;
  linux-x86_64)      platform="${ORZ_PLATFORM:-linux-x86_64}"; profile="${ORZ_PROFILE_NAME:-server}" ;;
  linux-arm64)       platform="${ORZ_PLATFORM:-linux-arm64}"; profile="${ORZ_PROFILE_NAME:-server}" ;;
  builtin-lite)
    host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    [[ "$host_os" == darwin ]] && host_os=macos
    platform="${ORZ_PLATFORM:-$host_os-$(uname -m)}"; profile="${ORZ_PROFILE_NAME:-builtin-lite}" ;;
  *) echo "Unknown native package preset: $PRESET" >&2; exit 2 ;;
esac

STAGE="$OUT/OrzAudioCore-$VERSION-$platform-$profile"

"$ROOT/script/build-sdk.sh" "$PRESET"
rm -rf "$STAGE"
mkdir -p "$STAGE/native" "$STAGE/metadata" "$STAGE/licenses" "$STAGE/bin"
cmake --install "$ROOT/.cmake-build/$PRESET" --prefix "$STAGE/native"
if [[ -x "$ROOT/.cmake-build/$PRESET/orz_artifact_probe" ]]; then
  cp "$ROOT/.cmake-build/$PRESET/orz_artifact_probe" "$STAGE/bin/"
fi
"$ROOT/script/collect-licenses.sh" "$STAGE/licenses" "$profile"
cp "$ROOT/Docs/orz-audio-core.md" "$STAGE/README.md"
node "$ROOT/script/generate-release-metadata.mjs" "$STAGE" --profile "$profile" --platform "$platform"
tar -C "$OUT" -czf "$STAGE.tar.gz" "$(basename "$STAGE")"
(cd "$(dirname "$STAGE")" && shasum -a 256 "$(basename "$STAGE").tar.gz") > "$STAGE.tar.gz.sha256"
if [[ "${ORZ_SKIP_VERIFY:-0}" != "1" ]]; then
  probe_args=()
  [[ -x "$STAGE/bin/orz_artifact_probe" ]] && probe_args+=(--run-probe)
  node "$ROOT/script/verify-artifact.mjs" "$STAGE.tar.gz" "${probe_args[@]}"
fi
echo "$STAGE.tar.gz"
