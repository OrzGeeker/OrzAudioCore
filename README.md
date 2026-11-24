# OrzAudioCore

OrzAudioCore is the cross-platform decoding SDK used by OrzMusic. It exposes a
stable, versioned C ABI and official Swift and TypeScript bindings. Decoder
instances are isolated and different instances can render concurrently.

## Which artifact do I need?

| Need | Profile | Artifact |
|---|---|---|
| Apache-2.0, YM/MIDI/SoundMon only | `builtin-lite` | SwiftPM source, lite XCFramework, `-builtin-lite` tarball |
| All 23 formats, self-hosted/server | `full`/`server` | macOS/Linux/Windows tarball, iOS full XCFramework, Android AAR |
| Browser playback | `full` + `builtin-lite` | `@orzmusic/audio-core` npm tarball |

The full/server artifacts are GPL-3.0-or-later because they statically link GPL
decoders; the lite artifacts are Apache-2.0. Read [Docs/licensing.md](Docs/licensing.md)
and [Docs/consumer-matrix.md](Docs/consumer-matrix.md) before choosing.

## Build

The dependency-free builtin profile (YM, MIDI and SoundMon BP):

```bash
cmake --preset builtin-lite
cmake --build --preset builtin-lite
ctest --test-dir .cmake-build/builtin-lite --output-on-failure
swift test
```

The `full` and `server` profiles require the locked native decoder archives in
`Libraries/OrzAudioKit/native`. Build those archives with
`script/build-native-libs.sh`, then select the matching CMake preset.

Android cross builds use the same archives script with a different toolchain:
`./script/build-android.sh` (needs `ANDROID_NDK_HOME`) produces
`libOrzAudioCore.so`/`.a` for `arm64-v8a`, `armeabi-v7a` and `x86_64`.

The stable public API is documented in [Docs/orz-audio-core.md](Docs/orz-audio-core.md).
Format, profile, decoder versions and cache namespaces are generated from
`decoder-manifest.json`; `orz_build_info()` and release `metadata/build-info.json`
share that contract. Platform guides: [apple](Docs/apple.md), [Android](Docs/android.md),
[Web](Docs/web.md), [consumer matrix](Docs/consumer-matrix.md),
[licensing](Docs/licensing.md) and [lockfile schema](Docs/lockfile.md).

Before tagging a release, validate every package projection and generated file:

```bash
node script/check-release-readiness.mjs
node script/generate-decoder-manifest.mjs --check
node --test script/lib/manifest.test.mjs
```

After packaging, verify every asset and the generated lockfile:

```bash
node script/verify-release.mjs ./release --require macos-arm64,linux-x86_64,android,web,apple
```

Cross-platform PCM conformance uses the pinned fixture corpus (files are fetched,
not committed):

```bash
node script/fetch-conformance-fixtures.mjs
node script/run-conformance.mjs --binary .cmake-build/macos-arm64/orz_conformance \
  --out conformance --platform macos-arm64 --require-all
node script/compare-conformance.mjs conformance/macos-arm64 conformance/linux-x86_64
```

## Packages

- C/C++: CMake install package and pkg-config metadata.
- Swift: source package and iOS XCFramework for builtin-lite; versioned full-profile macOS SDK tarball.
- Web: `SDK/Web`, published as `@orzmusic/audio-core` with versioned WASM assets
  and the official worker/AudioWorklet bridge. Package with
  `script/package-web-sdk.sh`; see [Docs/web.md](Docs/web.md).
- Apple: full-profile XCFramework with modulemap, SwiftPM binary target and
  metadata. Build with `script/build-ios.sh` and `script/package-apple-sdk.sh`;
  see [Docs/apple.md](Docs/apple.md).
- Android: `full` profile shared/static library per ABI plus headers, manifest,
  SBOM and license texts. Build with `script/build-android.sh`, package the C SDK
  with `script/package-android-sdk.sh`, or build the official AAR with
  `script/build-android-aar.sh`; see [Docs/android.md](Docs/android.md).

OrzAudioCore contains decoding, probing, metadata, seek and PCM rendering only.
Playback devices, queues, HTTP, CAS and UI remain responsibilities of consumers.

## License

OrzAudioCore is licensed under Apache-2.0. Bundled decoder dependencies retain
their respective licenses; release artifacts include their notices and SBOM.
