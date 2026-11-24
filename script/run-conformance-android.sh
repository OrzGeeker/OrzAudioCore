#!/usr/bin/env bash
# Run conformance fixtures on a connected Android emulator/device.
#
# Usage: run-conformance-android.sh [--binary path] [--out dir] [--platform android-x86_64]
# The binary defaults to .cmake-build/android-x86_64-conformance/orz_conformance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.cmake-build/android-x86_64-conformance/orz_conformance"
OUT="$ROOT/conformance/android-x86_64"
PLATFORM="android-x86_64"
FRAMES="${ORZ_CONFORMANCE_FRAMES:-8192}"
FIXTURES="${ORZ_CONFORMANCE_FIXTURES:-$ROOT/Tests/conformance/fixtures}"
ADB="${ADB:-adb}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -x "$BINARY" ]] || { echo "missing Android conformance binary: $BINARY" >&2; exit 1; }
"$ADB" wait-for-device
REMOTE="/data/local/tmp/orz-conformance"
"$ADB" shell "rm -rf $REMOTE && mkdir -p $REMOTE"
"$ADB" push "$BINARY" "$REMOTE/orz_conformance" >/dev/null
"$ADB" shell "chmod 755 $REMOTE/orz_conformance"
TARGET="$OUT"; mkdir -p "$TARGET"
INDEX="$TARGET/formats.jsonl"; : > "$INDEX"

node -e '
  const fs=require("fs");
  const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  for (const f of m.formats) if (f.path) console.log(`${f.format}\t${f.path}`);
' "$ROOT/Tests/conformance/manifest.json" > "$TARGET/fixtures.tsv"

while IFS=$'\t' read -r format relative; do
  [[ -n "$format" ]] || continue
  source="$FIXTURES/$relative"
  if [[ ! -f "$source" ]]; then
    # Fetch script stores fixtures under <format>/<basename>.
    source="$(find "$FIXTURES/$format" -maxdepth 1 -type f 2>/dev/null | head -1)"
  fi
  [[ -f "$source" ]] || { echo "missing fixture for $format" >&2; continue; }
  remote_fixture="$REMOTE/fixture.$format"
  "$ADB" push "$source" "$remote_fixture" </dev/null >/dev/null
  if "$ADB" shell "$REMOTE/orz_conformance --format $format --input $remote_fixture --frames $FRAMES" </dev/null > "$TARGET/$format.json" 2>"$TARGET/$format.err"; then
    echo "{\"format\":\"$format\",\"status\":\"ok\"}" >> "$INDEX"
  else
    echo "{\"format\":\"$format\",\"status\":\"error\"}" >> "$INDEX"
    echo "conformance failed for $format; see $TARGET/$format.err" >&2
  fi
done < "$TARGET/fixtures.tsv"

rm -f "$TARGET/fixtures.tsv"
node -e '
  const fs=require("fs"), path=require("path");
  const dir=process.argv[1], platform=process.argv[2];
  const formats={};
  for (const line of fs.readFileSync(path.join(dir,"formats.jsonl"),"utf8").trim().split(/\n+/)) {
    if (!line) continue;
    const entry=JSON.parse(line);
    const report=path.join(dir,`${entry.format}.json`);
    if (!fs.existsSync(report)) { formats[entry.format]={status:"missing"}; continue; }
    try {
      const parsed=JSON.parse(fs.readFileSync(report,"utf8"));
      formats[entry.format]={status: parsed.error ? "error" : "ok", sampleRate: parsed.stream?.sampleRate,
        channels: parsed.stream?.channels, duration: parsed.stream?.duration,
        seekStatus: parsed.seek?.status, cancelStatus: parsed.cancel?.status};
    } catch { formats[entry.format]={status:"error"}; }
  }
  fs.writeFileSync(path.join(dir,"index.json"), JSON.stringify({platform,generatedAt:new Date().toISOString(),formats},null,2)+"\n");
  fs.rmSync(path.join(dir,"formats.jsonl"));
' "$TARGET" "$PLATFORM"
echo "wrote Android conformance reports to $TARGET"
