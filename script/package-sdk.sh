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
IS_MULTI_CONFIG=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_MULTI_CONFIG=true ;; esac

case "$PRESET" in
  macos-arm64)       platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-x86_64)      platform="${ORZ_PLATFORM:-macos-x86_64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-arm64-full)  platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-full}" ;;
  macos-arm64-lite)  platform="${ORZ_PLATFORM:-macos-arm64}"; profile="${ORZ_PROFILE_NAME:-builtin-lite}" ;;
  linux-x86_64)      platform="${ORZ_PLATFORM:-linux-x86_64}"; profile="${ORZ_PROFILE_NAME:-server}" ;;
  linux-arm64)       platform="${ORZ_PLATFORM:-linux-arm64}"; profile="${ORZ_PROFILE_NAME:-server}" ;;
  builtin-lite)
    host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$host_os" in
      darwin) host_os=macos; host_arch="$(uname -m)" ;;
      mingw*|msys*|cygwin*) host_os=windows; host_arch="x86_64" ;;
      *) host_arch="$(uname -m)" ;;
    esac
    platform="${ORZ_PLATFORM:-$host_os-$host_arch}"; profile="${ORZ_PROFILE_NAME:-builtin-lite}" ;;
  *) echo "Unknown native package preset: $PRESET" >&2; exit 2 ;;
esac

STAGE="$OUT/OrzAudioCore-$VERSION-$platform-$profile"

"$ROOT/script/build-sdk.sh" "$PRESET"
rm -rf "$STAGE"
mkdir -p "$STAGE/native" "$STAGE/metadata" "$STAGE/licenses" "$STAGE/bin"
install_args=(--prefix "$STAGE/native")
if $IS_MULTI_CONFIG; then install_args+=(--config Release); fi
cmake --install "$ROOT/.cmake-build/$PRESET" "${install_args[@]}"
probe=""
for candidate in \
  "$ROOT/.cmake-build/$PRESET/orz_artifact_probe" \
  "$ROOT/.cmake-build/$PRESET/Release/orz_artifact_probe.exe" \
  "$ROOT/.cmake-build/$PRESET/Release/orz_artifact_probe"; do
  [[ -x "$candidate" ]] && { probe="$candidate"; break; }
done
if [[ -n "$probe" ]]; then cp "$probe" "$STAGE/bin/"; fi
"$ROOT/script/collect-licenses.sh" "$STAGE/licenses" "$profile"
cp "$ROOT/Docs/orz-audio-core.md" "$STAGE/README.md"
node "$ROOT/script/generate-release-metadata.mjs" "$STAGE" --profile "$profile" --platform "$platform"
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
tar -C "$OUT" -czf "$STAGE.tar.gz" "$(basename "$STAGE")"
printf '%s  %s\n' "$(sha256_file "$STAGE.tar.gz")" "$(basename "$STAGE").tar.gz" > "$STAGE.tar.gz.sha256"
if [[ "${ORZ_SKIP_VERIFY:-0}" != "1" ]]; then
  probe_args=()
  if find "$STAGE/bin" -maxdepth 1 -name 'orz_artifact_probe*' -type f -perm -u+x | grep -q .; then
    probe_args+=(--run-probe)
  fi
  node "$ROOT/script/verify-artifact.mjs" "$STAGE.tar.gz" "${probe_args[@]}"
fi
echo "$STAGE.tar.gz"
