# Apple SDK

Two Apple products are published. Pick by the formats you need, not by platform:

| Product | Profile | Formats | Distribution |
|---|---|---|---|
| `OrzAudioCore` source package / lite XCFramework | `builtin-lite` | `ym` `mid` `bp` | SwiftPM source (Apache-2.0) |
| `OrzAudioCore-<ver>-apple-full.xcframework.zip` | `full` | all 23 manifest formats | Release asset + generated `Package.swift` |

The lite product has no GPL dependency. The full product statically links
`libopenmpt`, `gme`, `sidplayfp`, `asap`, `sc68`, `adplug`, `v2m` and
`ahx2play`, so the combined binary is GPL-3.0-or-later. Read
[licensing.md](licensing.md) before shipping it to the App Store.

## Full XCFramework layout

```
OrzAudioCore.xcframework/
  ios-arm64/OrzAudioCore.framework? -> static lib + Headers
  ios-arm64_x86_64-simulator/
  macos-arm64/
  Info.plist
metadata/{decoder-manifest.json,build-info.json,sbom.cdx.json,artifact.json}
licenses/*
README.md
```

Every slice contains `Headers/orz_audio_core.h` and `Headers/module.modulemap`,
so SwiftPM and CMake consumers can `import OrzAudioCore` without editing
search paths. The zip root contains the xcframework plus metadata/licenses;
SwiftPM binary targets find the xcframework at the archive root.

Minimum deployment targets are iOS 15.0 and macOS 13.0. The archives are static
(no dylib, no rpath work) and are built with the current Xcode toolchain.

## SwiftPM binary target

`script/package-apple-sdk.sh --profile full` writes
`OrzAudioCore-<ver>-apple-full.swift` next to the zip:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrzAudioCoreFull",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "OrzAudioCore", targets: ["OrzAudioCore"])],
    targets: [
        .binaryTarget(
            name: "OrzAudioCore",
            url: "https://github.com/OrzGeeker/OrzAudioCore/releases/download/v<ver>/OrzAudioCore-<ver>-apple-full.xcframework.zip",
            checksum: "<sha256 of the zip>"
        )
    ]
)
```

Rename/copy it to `Package.swift` in a consumer package and add the library as
a dependency. The checksum is the SHA-256 already published in the `.sha256`
sidecar. A consumer executable target must link the static archive's system
dependencies:

```swift
.executableTarget(
    name: "App",
    dependencies: ["OrzAudioCore"],
    linkerSettings: [.linkedLibrary("z"), .linkedLibrary("c++")]
)
```

The merged static slice contains all decoders, but not zlib/libc++ themselves.

## CMake consumers

```cmake
find_library(ORZ_CORE OrzAudioCore PATHS "${ORZ_APPLE_DIR}" REQUIRED)
target_link_libraries(app PRIVATE "${ORZ_CORE}")
target_include_directories(app PRIVATE "${ORZ_APPLE_DIR}/Headers")
```

For iOS, link the matching slice from the xcframework and add
`-Wl,-z,max-page-size=16384` only on Android; it is not needed on Apple.

## Building (maintainers)

```bash
./script/fetch-decoder-sources.sh
./script/build-ios.sh --profile full            # decoder archives + 3 slices
./script/package-apple-sdk.sh --profile full    # zip + checksum + Package.swift
./script/build-xcframework.sh --profile builtin-lite
```

`build-ios.sh` cross-compiles the locked archives for `arm64-apple-ios`,
`arm64/x86_64-apple-ios-simulator` and macOS arm64. It uses `xcrun` sysroots and
requires macOS with Xcode. The lite slices can be built without any third-party
source.

Apple release smoke tests link the device slice, decode a `.mod` fixture in the
simulator and run a macOS probe. The conformance report is attached to the same
release; see [consumer-matrix.md](consumer-matrix.md).

## App Store notes

- Do not submit the `full` profile unless you have a GPL compliance plan; the
  safer path is the lite XCFramework plus server/WASM decoding.
- Bitcode is deprecated and not produced.
- The archive is not code-signed; Xcode signs the host app. No entitlements are
  required by the SDK.
- `orz_build_info()` reports `profile`, `formats`, `decoders` and
  `cacheNamespace`; persist the latter with decoded PCM caches.
