# Windows status

Windows x86_64 now has an official **builtin-lite** release artifact and CI:
`OrzAudioCore-<ver>-windows-x86_64-builtin-lite.tar.gz` (MSVC, static library,
`ym`/`mid`/`bp`). The full profile is still built with POSIX autotools and is not
released for Windows; use Web/WASM or the server for the other 20 formats.

## What works today

- `builtin-lite` (`ym`, `mid`, `bp`) via CMake:

  ```bat
  cmake -S . -B build -DORZ_PROFILE=builtin-lite -DORZ_BUILD_TESTS=ON
  cmake --build build --config Release
  ctest --test-dir build -C Release --output-on-failure
  ```

- The `OrzAudioCore::OrzAudioCore` CMake package and C header.
- Web/WASM and server decoding remain the recommended Windows playback path
  until a native full profile is published.

## Verified in CI

`windows-lite` builds with MSVC, runs the ABI/consumer tests, packages the SDK,
runs the lite conformance probe and compares its PCM against the Linux lite
build (with bounded float drift).

## Gaps for a Windows full-profile release

1. Build the nine decoder archives with MSVC/clang-cl (or vcpkg) and add a
   `windows-x86_64` CMake preset with `ORZ_NATIVE_LIB`.
2. Add `ORZ_AUDIO_CORE_SHARED` exports/version resource for a DLL build.
3. Add `windows-latest` CI for lite ABI + consumer smoke; full profile needs a
   locked dependency build story.
4. Add a package artifact `OrzAudioCore-<ver>-windows-x86_64-full.zip` with
   manifest/SBOM/licenses and a conformance report.
5. Verify `orz_build_info()` link flags and UTF-8 path handling on MSVC.

Until then, treat Windows as source-only and do not claim it in the consumer
matrix.
