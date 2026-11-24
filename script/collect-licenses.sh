#!/usr/bin/env bash
# Collect the license texts that must ship with an OrzAudioCore artifact.
#
# Usage: collect-licenses.sh <output-dir> [builtin-lite|full|server]
#
# The full/server profiles statically link third-party decoders whose licenses
# require their notices to travel with the binary. Sources are read from the
# pinned tree produced by script/fetch-decoder-sources.sh; missing notices are
# a hard error so a release cannot silently lose a license file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: collect-licenses.sh <output-dir> [profile]}"
PROFILE="${2:-full}"
SRC_DIR="${ORZ_DECODER_SRC_DIR:-$ROOT/.wasm-build/src}"

log() { printf '[LICENSES] %s\n' "$*"; }
err() { printf '[LICENSES] %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"
cp "$ROOT/LICENSE" "$OUT/OrzAudioCore-LICENSE"
cp "$ROOT/Sources/OrzAudioKitCXX/ym6/lhasa/COPYING.md" "$OUT/lhasa-COPYING.md"

if [[ "$PROFILE" == "builtin-lite" ]]; then
  cat > "$OUT/README.md" <<'EOF'
# Licenses

The builtin-lite profile only contains OrzAudioCore (Apache-2.0) and lhasa
(ISC). No GPL decoder is linked into this artifact.
EOF
  log "builtin-lite licenses written to $OUT"
  exit 0
fi

copy_license() {
  local name="$1" path="$2" target="$3"
  [[ -f "$SRC_DIR/$path" ]] || err "missing $name license: $SRC_DIR/$path (run script/fetch-decoder-sources.sh)"
  cp "$SRC_DIR/$path" "$OUT/$target"
}

copy_license libopenmpt   libopenmpt/LICENSE                  libopenmpt-LICENSE
copy_license libgme       game-music-emu/license.txt          game-music-emu-LICENSE
copy_license libgme       game-music-emu/license.gpl2.txt     game-music-emu-GPL2.txt
copy_license libbinio     libbinio/COPYING                    libbinio-COPYING
copy_license libadplug    adplug/COPYING                      libadplug-COPYING
copy_license libsidplayfp libsidplayfp/COPYING                libsidplayfp-COPYING
copy_license asap         asap/COPYING                        asap-COPYING
copy_license sc68         sc68/README                         sc68-README-GPL3.txt
copy_license v2m          v2m/LICENSE                         v2m-player-LICENSE
copy_license ahx2play     ahx2play/LICENSE                    ahx2play-LICENSE

cat > "$OUT/README.md" <<'EOF'
# Licenses

The full/server profile statically links the components below. Each entry's
license text is in this directory. The combined binary is distributed under
GPL-3.0-or-later (GPL-2.0-or-later and LGPL components may be upgraded under
their "or later" clauses; Artistic-2.0 and BSD-3-Clause are GPLv3-compatible).

| Component | Formats | License | Text |
|---|---|---|---|
| OrzAudioCore | C ABI, ym, mid, bp | Apache-2.0 | OrzAudioCore-LICENSE |
| lhasa | LHA decompression for ym6 | ISC | lhasa-COPYING.md |
| libopenmpt | xm mod it s3m mo3 mtm fc13 fc14 | BSD-3-Clause | libopenmpt-LICENSE |
| game-music-emu | nsf spc | LGPL-2.1-or-later | game-music-emu-LICENSE / GPL2 |
| libsidplayfp | sid | GPL-2.0-or-later | libsidplayfp-COPYING |
| asap | sap | GPL-2.0-or-later | asap-COPYING |
| sc68 | sc68 | GPL-3.0-or-later | sc68-README-GPL3.txt |
| v2m-player | v2m | Artistic-2.0 | v2m-player-LICENSE |
| ahx2play | ahx thx | BSD-3-Clause | ahx2play-LICENSE |
| libadplug / libbinio | rad d00 hsc amd | LGPL-2.1-or-later | libadplug-COPYING / libbinio-COPYING |

No C64 kernal/basic ROM is included. RSID tunes that require ROMs are the
caller's responsibility.
EOF
log "full-profile licenses written to $OUT"
