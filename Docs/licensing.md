# Licensing

OrzAudioCore has two layers with different licenses. Do not collapse them into
one claim.

## Layer 1: OrzAudioCore itself

The C ABI, dispatch layer, `ym6`, `midi`, `soundmon` and the lhasa LHA decoder
are licensed under **Apache-2.0** (lhasa is ISC). `builtin-lite` artifacts
contain only this layer, so they are Apache-2.0.

## Layer 2: full/server artifacts

`full` and `server` artifacts statically link third-party decoders. The combined
binary is distributed under **GPL-3.0-or-later**:

| Component | Formats | License | GPLv3 compatible |
|---|---|---|---|
| libopenmpt | xm mod it s3m mo3 mtm fc13 fc14 | BSD-3-Clause | yes |
| game-music-emu | nsf spc | LGPL-2.1-or-later | yes (upgradeable) |
| libsidplayfp | sid | GPL-2.0-or-later | yes (upgradeable) |
| asap | sap | GPL-2.0-or-later | yes (upgradeable) |
| sc68 | sc68 | GPL-3.0-or-later | yes |
| v2m-player | v2m | Artistic-2.0 | yes |
| ahx2play | ahx thx | BSD-3-Clause | yes |
| libadplug / libbinio | rad d00 hsc amd | LGPL-2.1-or-later | yes (upgradeable) |

The exact license texts are in every release artifact under `licenses/`, with a
component/format table in `licenses/README.md`. `metadata/sbom.cdx.json`
(CycloneDX 1.5) lists decoder names and versions.

## What consumers must do

1. If you ship a **full/server** binary, your distribution must comply with
   GPL-3.0-or-later: provide the corresponding source (at minimum the OrzAudioCore
   tag and the locked third-party sources fetched by
   `script/fetch-decoder-sources.sh`), keep the license notices, and do not add
   restrictions that forbid reverse engineering or relinking.
2. If you cannot accept GPL, use `builtin-lite` (Apache-2.0) and move full
   decoding to a server or the Web/WASM build governed by the same terms.
3. A GPL binary linked into an app does not automatically relicense your app's
   independent code, but the combined work and its distribution are governed by
   GPLv3. Get legal review for your distribution model.

## App Store / GPLv3

Apple's App Store terms impose restrictions (DRM, usage restrictions, device
limits) that are widely considered incompatible with GPLv3. Do **not** submit
the `full` iOS XCFramework to the App Store without a compliance plan. The
`builtin-lite` XCFramework is Apache-2.0 and avoids this conflict.

The same caution applies to any GPL profile bundled in a locked-down store
distribution on other platforms.

## Source availability

Every full release tag points at the exact OrzAudioCore commit and pins decoder
sources with SHA-256 in `script/fetch-decoder-sources.sh`. Publishing that tag
and the fetched source archives satisfies the source-offer obligation; the
release notes link to the tag and the lockfile records the commit.

## No ROMs

No C64 kernal/basic ROM is included. `sid` handles PSID tunes; RSID tunes that
require ROMs are the caller's responsibility.
