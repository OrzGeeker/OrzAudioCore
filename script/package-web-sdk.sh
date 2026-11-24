#!/usr/bin/env bash
# Package the Web SDK as a release tarball with canonical naming and metadata.
#
# Usage: package-web-sdk.sh [output-dir]
# Prerequisite: SDK/Web/wasm contains the full + builtin-lite WASM assets and
#               decoder sources are fetched for the full license notices.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.cmake-build/release}"
VERSION="$(node -p "require('$ROOT/decoder-manifest.json').sdkVersion")"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WEB="$ROOT/SDK/Web"
ASSET="OrzAudioCore-$VERSION-web-full.tgz"

[[ -s "$WEB/wasm/orz_audio.wasm" ]] || { echo "missing SDK/Web/wasm/orz_audio.wasm (build WASM first)" >&2; exit 2; }
mkdir -p "$OUT"

rm -rf "$WEB/metadata" "$WEB/licenses"
"$ROOT/script/collect-licenses.sh" "$WEB/licenses" full
node "$ROOT/script/generate-release-metadata.mjs" "$WEB" --profile full --platform web
cp "$ROOT/Docs/web.md" "$WEB/README.md"

(cd "$WEB" && npm pack --pack-destination "$OUT")
PACKED="$(ls -t "$OUT"/orzmusic-audio-core-*.tgz | head -1)"
mv "$PACKED" "$OUT/$ASSET"
(cd "$OUT" && shasum -a 256 "$ASSET" > "$ASSET.sha256")

if [[ "${ORZ_SKIP_VERIFY:-0}" != "1" ]]; then
  node "$ROOT/script/verify-artifact.mjs" "$OUT/$ASSET"
fi
echo "$OUT/$ASSET"
