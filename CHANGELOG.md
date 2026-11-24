# Changelog

## 1.4.0

### SDK metadata and cache namespaces

- `orz_build_info()` now returns `profile`, `formats`, `decoders`, `cacheNamespace`
  and the backwards-compatible `fingerprint` (alias of `cacheNamespace`).
- `cacheNamespace = orzaudio-<version>-<profile>-<decoderSetHash>`; decoder
  patches invalidate cached PCM.
- Added `metadata/build-info.json`, `metadata/artifact.json`, SBOM and license
  collection to every artifact, and `orz_artifact_probe` /
  `script/verify-artifact.mjs` for runtime-vs-metadata checks.
- Added the schema-v1 downstream lockfile, `script/generate-lockfile.mjs` and
  `script/verify-lockfile.mjs`; legacy 1.3.x lockfiles remain readable with
  `--allow-legacy`.

### Apple

- Added full-profile iOS device, iOS simulator and macOS arm64 static slices,
  `script/build-ios.sh`, `script/package-apple-sdk.sh` and a generated SwiftPM
  binary-target `Package.swift`.
- Every xcframework slice ships a `module.modulemap`; package archives carry
  metadata, SBOM and licenses.

### Android

- Added official `SDK/Android` AAR (`com.orzgeeker:audio-core-android`) with
  Kotlin API, JNI bridge, consumer rules, 16KB page alignment and bundled
  metadata/licenses. `script/build-android-aar.sh` builds it from the merged
  core archive.

### Web

- Added official `worker` + `worklet` exports and protocol v1 (ring-buffer
  control slots, seek/stop/cancel, underrun accounting) with a transfer-mode
  fallback when SharedArrayBuffer is unavailable.
- Added `buildInfo()` / `supportedFormats()` bindings and protocol tests.

### Conformance

- Added `Tests/conformance` harness, pinned fixture manifest/fetch script and
  `script/run-conformance.mjs` / `script/compare-conformance.mjs`.
- Reports cover probe, stream info, PCM hashes, seek, subsongs, cancel and build
  info for every full-profile format; `thx` shares the ahx fixture.
- Release CI compares native, Apple and Web reports before publishing.

### Docs

- New platform guides: `Docs/apple.md`, `Docs/web.md`, `Docs/windows.md`,
  `Docs/consumer-matrix.md`, `Docs/licensing.md`, `Docs/lockfile.md`, plus an
  artifact decision table in the README.
