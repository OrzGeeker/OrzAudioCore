# Windows SDK

Windows x86_64 is a first-class release target with the same **full** profile as
macOS/Linux/Apple/Android/Web:

- `OrzAudioCore-<ver>-windows-x86_64-full.tar.gz`
  - `native/bin/OrzAudioCore.dll` (C ABI, all 23 formats)
  - `native/lib/libOrzAudioCore.dll.a` (MinGW import library)
  - `native/lib/OrzAudioCore.lib` (COFF/MSVC import library when `dlltool` is available)
  - `native/include/orz_audio_core.h`, CMake package, metadata, SBOM, licenses
- `OrzAudioCore-<ver>-windows-x86_64-builtin-lite.tar.gz`
  - static `OrzAudioCore.lib`, 3 formats, no GPL decoder.

## Build

The full profile is built natively with MSYS2/MinGW64 (stock Windows runner),
using the same locked decoder sources as every other platform:

```bash
./script/fetch-decoder-sources.sh
CC=gcc CXX=g++ AR=ar RANLIB=ranlib \
  ORZ_HOST_TRIPLE=x86_64-w64-mingw32 \
  CMAKE_GENERATOR="MinGW Makefiles" CMAKE_PREFIX_PATH=/mingw64 \
  ./script/build-native-libs.sh --strict
CMAKE_GENERATOR="MinGW Makefiles" CMAKE_PREFIX_PATH=/mingw64 \
  ./script/package-sdk.sh windows-x86_64-full release
```

CMake preset `windows-x86_64-full` builds a DLL + import libraries. The DLL
contains the same decoder set and `cacheNamespace` as full macOS/Linux.

## Consume

### CMake / MinGW

```cmake
find_package(OrzAudioCore 1 REQUIRED CONFIG)
target_link_libraries(app PRIVATE OrzAudioCore::OrzAudioCore)
```

Deploy `OrzAudioCore.dll` next to the executable.

### MSVC / clang-cl

Link `native/lib/OrzAudioCore.lib` (import library), include
`native/include/orz_audio_core.h`, and deploy `native/bin/OrzAudioCore.dll`.
The SDK itself is built with MinGW, but the public boundary is the stable C ABI;
no C++ ABI is exposed.

## Verification

CI/release `windows-full` builds all 9 decoders, packages the SDK, runs the
artifact probe (`runtime formatCount=23`), and runs the 23-format conformance
suite on Windows. Its report is compared with the Linux full report before
publishing. `windows-lite` separately covers the builtin-lite profile.

## Licensing

The full Windows DLL statically links GPL-family decoders and is distributed as
GPL-3.0-or-later; the lite archive is Apache-2.0. See
[licensing.md](licensing.md).
