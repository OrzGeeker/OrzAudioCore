#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-builtin-lite}"

case "$PROFILE" in
  builtin-lite|macos-arm64|macos-x86_64|macos-arm64-full|linux-x86_64|linux-arm64|ios-device-lite|ios-simulator-lite|ios-device-full|ios-simulator-full|wasm-full|wasm-lite) ;;
  *) echo "Unknown SDK preset: $PROFILE" >&2; exit 2 ;;
esac

IS_MULTI_CONFIG=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_MULTI_CONFIG=true ;; esac

node "$ROOT/script/generate-decoder-manifest.mjs" --check
cmake --preset "$PROFILE" -S "$ROOT"
build_args=()
if $IS_MULTI_CONFIG; then build_args+=(--config Release); fi
cmake --build --preset "$PROFILE" ${build_args[@]+"${build_args[@]}"}
if [[ "$PROFILE" != wasm-* && "$PROFILE" != ios-* ]]; then
  test_args=()
  if $IS_MULTI_CONFIG; then test_args+=(-C Release); fi
  ctest --test-dir "$ROOT/.cmake-build/$PROFILE" --output-on-failure ${test_args[@]+"${test_args[@]}"}
fi
