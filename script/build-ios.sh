#!/usr/bin/env bash
# ============================================================================
# Apple cross build: iOS device, iOS simulator and macOS static slices.
#
# Usage:
#   ./script/build-ios.sh [--profile full|builtin-lite] [--out dir] [--skip-deps]
#
# full: cross-compiles the nine locked decoder archives for
#       arm64-apple-ios, arm64/x86_64-apple-ios-simulator and macOS arm64,
#       then builds a static OrzAudioCore for each slice.
# builtin-lite: builds the dependency-free slices directly.
#
# Requires Xcode command line tools. The third-party sources must be present:
#   ./script/fetch-decoder-sources.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ORZ_APPLE_OUT:-$ROOT/.cmake-build/apple}"
PROFILE="full"
SKIP_DEPS=false
IOS_MIN="${ORZ_IOS_DEPLOYMENT_TARGET:-15.0}"
MACOS_MIN="${ORZ_MACOS_DEPLOYMENT_TARGET:-13.0}"
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --skip-deps) SKIP_DEPS=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "build-ios.sh requires macOS" >&2; exit 2; }
[[ "$PROFILE" == "full" || "$PROFILE" == "builtin-lite" ]] || { echo "profile must be full or builtin-lite" >&2; exit 2; }

log() { printf '[APPLE] %s\n' "$*"; }
err() { printf '[APPLE] %s\n' "$*" >&2; exit 1; }

for tool in xcrun xcodebuild cmake; do
    command -v "$tool" >/dev/null 2>&1 || err "$tool is required"
done

SDK_DEVICE="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_SIM="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDK_MACOS="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OUT/toolchains" "$OUT/wrappers" "$OUT/deps"

make_toolchain() {
    local path="$1" sdk="$2" arch="$3" system="$4" minimum="$5"
    cat > "$path" <<EOF
set(CMAKE_SYSTEM_NAME "$system")
set(CMAKE_OSX_SYSROOT "$sdk")
set(CMAKE_OSX_ARCHITECTURES "$arch")
set(CMAKE_OSX_DEPLOYMENT_TARGET "$minimum")
set(CMAKE_C_COMPILER "$OUT/wrappers/clang")
set(CMAKE_CXX_COMPILER "$OUT/wrappers/clang++")
set(CMAKE_AR "$(xcrun --find ar)")
set(CMAKE_RANLIB "$(xcrun --find ranlib 2>/dev/null || command -v ranlib)")
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
}

# `xcrun --sdk <sdk> clang` is used by the wrapper; the target triple is added
# through CFLAGS/CXXFLAGS so autotools and CMake agree on the SDK.
cat > "$OUT/wrappers/clang" <<'EOF'
#!/usr/bin/env bash
exec xcrun --sdk "$ORZ_APPLE_SDK" clang "$@"
EOF
cat > "$OUT/wrappers/clang++" <<'EOF'
#!/usr/bin/env bash
exec xcrun --sdk "$ORZ_APPLE_SDK" clang++ "$@"
EOF
chmod +x "$OUT/wrappers/clang" "$OUT/wrappers/clang++"

build_deps_for() {
    local name="$1" sdk="$2" triple="$3" target="$4" tag="$5"
    local deps="$OUT/deps/$name"
    if [[ -f "$deps/.complete" ]]; then
        log "$name decoder archives already built"
        return 0
    fi
    log "Cross-compiling decoder archives for $name ($target)"
    mkdir -p "$deps"
    local toolchain="$OUT/toolchains/$name.cmake"
    local system="iOS" minimum="$IOS_MIN"
    if [[ "$name" == macos-* ]]; then system="Darwin"; minimum="$MACOS_MIN"; fi
    make_toolchain "$toolchain" "$sdk" "${target%%-*}" "$system" "$minimum"
    (
        export ORZ_APPLE_SDK="$sdk"
        export CC="$OUT/wrappers/clang" CXX="$OUT/wrappers/clang++"
        export AR="$(xcrun --find ar)" RANLIB="$(xcrun --find ranlib 2>/dev/null || command -v ranlib)"
        export CFLAGS="-O2 -target $target -isysroot $sdk"
        export CXXFLAGS="$CFLAGS"
        export ORZ_HOST_TRIPLE="$triple"
        export ORZ_BUILD_TAG="$tag"
        export ORZ_NATIVE_OUT="$deps"
        export ORZ_INSTALL_HOST_LIBS=0
        export ORZ_CMAKE_TOOLCHAIN="$toolchain"
        export ORZ_CMAKE_EXTRA_ARGS="-DCMAKE_SYSTEM_NAME=$system -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum -DCMAKE_OSX_ARCHITECTURES=${target%%-*}"
        export JOBS
        "$ROOT/script/build-native-libs.sh" --strict
    )
    for lib in openmpt gme sidplayfp binio adplug sc68 asap v2m ahx2play; do
        [[ -f "$deps/lib$lib.a" ]] || err "$name is missing lib$lib.a"
    done
    : > "$deps/.complete"
}

build_deps() {
    build_deps_for ios-device "$SDK_DEVICE" "aarch64-apple-darwin" "arm64-apple-ios$IOS_MIN" "ios-device-full"
    build_deps_for ios-sim-arm64 "$SDK_SIM" "aarch64-apple-darwin" "arm64-apple-ios$IOS_MIN-simulator" "ios-sim-arm64-full"
    build_deps_for ios-sim-x86_64 "$SDK_SIM" "x86_64-apple-darwin" "x86_64-apple-ios$IOS_MIN-simulator" "ios-sim-x86_64-full"
    build_deps_for macos-arm64 "$SDK_MACOS" "aarch64-apple-darwin" "arm64-apple-macos$MACOS_MIN" "macos-arm64-full"

    local deps="$OUT/deps/ios-simulator"
    if [[ ! -f "$deps/.complete" ]]; then
        mkdir -p "$deps"
        log "Creating universal iOS simulator decoder archives"
        for lib in openmpt gme sidplayfp binio adplug sc68 asap v2m ahx2play; do
            lipo -create "$OUT/deps/ios-sim-arm64/lib$lib.a" "$OUT/deps/ios-sim-x86_64/lib$lib.a" -output "$deps/lib$lib.a"
        done
        : > "$deps/.complete"
    fi
}

build_core() {
    local preset="$1" native_lib="$2" sdk="$3" profile="$4"
    log "Building $preset"
    local zlib_args=()
    if [[ "$profile" == "full" && -n "$sdk" ]]; then
        # CMake's FindZLIB cannot always see the iOS SDK when the toolchain
        # restricts find_root_path; point it at the .tbd explicitly.
        zlib_args=(-DZLIB_LIBRARY="$sdk/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$sdk/usr/include")
    fi
    cmake --preset "$preset" -S "$ROOT" \
        -DORZ_NATIVE_LIB="$native_lib" \
        "${zlib_args[@]}"
    cmake --build --preset "$preset" -j "$JOBS"
}

mkdir -p "$OUT"
if [[ "$PROFILE" == "full" ]]; then
    $SKIP_DEPS || build_deps
    build_core ios-device-full "$OUT/deps/ios-device" "$SDK_DEVICE" full
    build_core ios-simulator-full "$OUT/deps/ios-simulator" "$SDK_SIM" full
    build_core macos-arm64-full "$OUT/deps/macos-arm64" "$SDK_MACOS" full
else
    build_core ios-device-lite "" "" builtin-lite
    build_core ios-simulator-lite "" "" builtin-lite
fi

log "Apple build complete: $OUT"
