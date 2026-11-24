# Consumer matrix

Last updated for SDK 1.4.0. "Formats" is the runtime format count; the
`decoder-manifest.json` profile list is the source of truth.

## Platform × profile

| Platform | Profile | Formats | Artifact | Official binding |
|---|---|---|---|---|
| macOS arm64/x86_64 | `full` | 23 | `OrzAudioCore-<ver>-macos-<arch>-full.tar.gz` | Swift source package, C ABI |
| macOS arm64/x86_64 | `builtin-lite` | 3 | `OrzAudioCore-<ver>-macos-<arch>-builtin-lite.tar.gz` | Swift source package, C ABI |
| Linux x86_64/arm64 | `server` | 23 | `OrzAudioCore-<ver>-linux-<arch>-server.tar.gz` | C ABI, CMake package |
| iOS device/simulator | `full` | 23 | `OrzAudioCore-<ver>-apple-full.xcframework.zip` | Swift binary target |
| iOS device/simulator | `builtin-lite` | 3 | `OrzAudioCore-<ver>-apple-builtin-lite.xcframework.zip` | Swift source/binary target |
| Android arm64-v8a/armeabi-v7a/x86_64 | `full` | 23 | `OrzAudioCore-<ver>-android-full.tar.gz`, `OrzAudioCore-<ver>-android-full.aar` | Kotlin `com.orzgeeker:audio-core-android` |
| Web (Chrome/Safari/Firefox) | `full` + `builtin-lite` | 23 / 3 | `OrzAudioCore-<ver>-web-full.tgz` | npm `@orzmusic/audio-core` |
| Windows x86_64 | `full` | 23 | `OrzAudioCore-<ver>-windows-x86_64-full.tar.gz` | C ABI (DLL + import lib) |
| Windows x86_64 | `builtin-lite` | 3 | `OrzAudioCore-<ver>-windows-x86_64-builtin-lite.tar.gz` | C ABI (see [windows.md](windows.md)) |

`server` and `full` contain the same formats and decoder versions but have
different `cacheNamespace` values (`orzaudio-…-server-…` vs `…-full-…`) because
the profile participates in the hash. Do not mix server-decoded PCM caches with
client-side full-profile caches.

## Format × profile

| Decoder | Formats | License | builtin-lite | full/server |
|---|---|---|---|---|
| libopenmpt | xm mod it s3m mo3 mtm fc13 fc14 | BSD-3-Clause | — | ✓ |
| gme | nsf spc | LGPL-2.1-or-later | — | ✓ |
| sidplayfp | sid | GPL-2.0-or-later | — | ✓ |
| asap | sap | GPL-2.0-or-later | — | ✓ |
| sc68 | sc68 | GPL-3.0-or-later | — | ✓ |
| v2m-player | v2m | Artistic-2.0 | — | ✓ |
| ahx2play | ahx thx | BSD-3-Clause | — | ✓ |
| adplug/libbinio | rad d00 hsc amd | LGPL-2.1-or-later | — | ✓ |
| ym6 (lhasa) | ym | Apache-2.0 / ISC | ✓ | ✓ |
| midi | mid | Apache-2.0 | ✓ | ✓ |
| soundmon | bp | Apache-2.0 | ✓ | ✓ |

Counts: builtin-lite 3, full/server 23.

## Binding surface

| Capability | C ABI | Swift | Kotlin | TypeScript |
|---|---|---|---|---|
| ABI/build info | `orz_build_info()` | `AudioDecoder.buildInfoObject` | `OrzAudioCore.buildInfoObject` | `buildInfo(module)` |
| Profile / formats | `orz_get_format_info()` | `supportedFormats` | `supportedFormats` | `supportedFormats(module)` |
| Cache namespace | JSON `cacheNamespace` | `AudioDecoder.cacheNamespace` | `OrzAudioCore.cacheNamespace` | `buildInfo().cacheNamespace` |
| Probe | `orz_probe()` | `AudioDecoder.probe` | `OrzAudioCore.probe` | use `createDecoder` / binding |
| Render/seek/subsong/cancel | v1 handle API | `AudioDecoder` | `AudioDecoder` | `AudioDecoder` |
| Streaming bridge | — | app-owned | `PcmStream` | `worker` + `worklet` |

## Cross-platform gates

Every release attaches `conformance/<platform>/` JSON reports for every fixture
in `Tests/conformance/manifest.json`. `script/compare-conformance.mjs` compares
native, Apple and Web reports. Expected platform differences are recorded in the
manifest (`thx` shares the ahx fixture; SID RSID ROM tunes are out of scope).

See [apple.md](apple.md), [android.md](android.md), [web.md](web.md) and
[licensing.md](licensing.md) for per-platform setup.
