#!/usr/bin/env bash
# ============================================================================
# Android 交叉编译 —— full profile(23 个格式)的 libOrzAudioCore
# ============================================================================
# 产物:
#   .wasm-build/native-android-<abi>/lib*.a          第三方解码库(静态)
#   .cmake-build/android-<abi>/libOrzAudioCore.so    核心库(shared)
#   .cmake-build/android-<abi>/libOrzAudioCore.a     核心库(static,给 JNI 嵌入)
#
# 依赖:
#   · Android NDK r27+      → ANDROID_NDK_HOME
#   · 已跑过 ./script/fetch-decoder-sources.sh
#
# 用法:
#   ./script/build-android.sh                      # arm64-v8a + armeabi-v7a
#   ./script/build-android.sh --abi arm64-v8a
#   ./script/build-android.sh --abi x86_64         # 模拟器
#   ./script/build-android.sh --clean
#   ./script/build-android.sh --skip-manifest-check
#
# Windows 原生 Git Bash 下 NDK 的 autotools 路径转换不可靠,脚本会拒绝执行;
# 用 WSL2 / Linux / macOS。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.wasm-build"
CMAKE_DIR="$ROOT/.cmake-build"
API_LEVEL="${ORZ_ANDROID_API:-29}"
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf "${GREEN}[ANDROID]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[ANDROID]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ANDROID]${NC} %s\n" "$*" >&2; exit 1; }

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        err "Windows 原生 Git Bash 不支持(NDK 的 autotools/路径转换)。请用 WSL2 / Linux / macOS。" ;;
esac

ABIS=()
CLEAN=false
SKIP_MANIFEST_CHECK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi) ABIS+=("$2"); shift 2 ;;
        --clean) CLEAN=true; shift ;;
        --skip-manifest-check) SKIP_MANIFEST_CHECK=true; shift ;;
        *) err "未知参数:$1" ;;
    esac
done
(( ${#ABIS[@]} == 0 )) && ABIS=(arm64-v8a armeabi-v7a)

if $CLEAN; then
    log "清理 Android 构建产物..."
    for abi in "${ABIS[@]}"; do
        rm -rf "$CMAKE_DIR/android-$abi" "$CMAKE_DIR/android-$abi-static" "$BUILD_DIR/native-android-$abi" "$BUILD_DIR"/build-*-"android-$abi"
    done
    rm -rf "$BUILD_DIR"/sc68-obj-android-*
    log "完成。"
    exit 0
fi

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
[[ -n "$NDK" && -f "$NDK/build/cmake/android.toolchain.cmake" ]] \
    || err "找不到 Android NDK:设置 ANDROID_NDK_HOME"

case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    *)      HOST_TAG="linux-x86_64" ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
[[ -d "$TOOLCHAIN" ]] || err "NDK toolchain 目录不存在:$TOOLCHAIN"

# ABI → (autotools --host triple, clang wrapper 前缀)
abi_triple() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
        x86)         echo "i686-linux-android" ;;
        *) err "不支持的 ABI:$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1) 第三方解码库(静态,.a)
# ---------------------------------------------------------------------------
build_deps() {
    local abi="$1"
    local triple native_out
    triple="$(abi_triple "$abi")"
    native_out="$BUILD_DIR/native-android-$abi"

    local cc="$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang"
    [[ -x "$cc" ]] || err "clang wrapper 不存在:$cc"
    local cxx="$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang++"

    if [[ -f "$native_out/.complete" ]]; then
        log "第三方库已就绪($abi),跳过"
        return 0
    fi

    log "交叉编译第三方解码库($abi, API $API_LEVEL)..."
    mkdir -p "$native_out"
    (
        export CC="$cc" CXX="$cxx"
        export AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
        export STRIP="$TOOLCHAIN/bin/llvm-strip"
        export CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC"
        export ORZ_HOST_TRIPLE="$triple"
        export ORZ_BUILD_TAG="android-$abi"
        export ORZ_NATIVE_OUT="$native_out"
        export ORZ_INSTALL_HOST_LIBS=0
        export ORZ_CMAKE_TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
        export ORZ_CMAKE_EXTRA_ARGS="-DANDROID_ABI=$abi -DANDROID_PLATFORM=android-$API_LEVEL -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=MinSizeRel"
        export JOBS
        "$ROOT/script/build-native-libs.sh" --strict
    )
    # 逐个库确认产物存在,silent 缺失会在链接阶段变成难懂的 undefined reference
    local missing=()
    for lib in openmpt gme sidplayfp binio adplug sc68 asap v2m ahx2play; do
        [[ -f "$native_out/lib$lib.a" ]] || missing+=("lib$lib.a")
    done
    (( ${#missing[@]} == 0 )) || err "$abi 缺少第三方归档:${missing[*]}"
    : > "$native_out/.complete"
    log "第三方库完成($abi):$(ls "$native_out"/*.a | wc -l) 个归档"
}

# ---------------------------------------------------------------------------
# 2) 核心库(shared + static)
# ---------------------------------------------------------------------------
build_core() {
    local abi="$1"
    local native_out="$BUILD_DIR/native-android-$abi"

    log "构建 OrzAudioCore(full profile, $abi)..."
    cmake --preset "android-$abi" -S "$ROOT" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DORZ_NATIVE_LIB="$native_out" \
        -DCMAKE_ANDROID_ARCH_ABI="$abi"
    cmake --build --preset "android-$abi" -j "$JOBS"

    local build_dir="$CMAKE_DIR/android-$abi"
    [[ -f "$build_dir/libOrzAudioCore.so" ]] || err "缺少 $build_dir/libOrzAudioCore.so"

    # 只导出 orz_*:第三方符号泄漏会让 JNI 侧出现符号冲突
    "$ROOT/script/verify-elf-exports.sh" "$build_dir/libOrzAudioCore.so"
    log "导出符号符合 ABI(1.0)"
}

# ---------------------------------------------------------------------------
# 2b) 静态归档(同一个 CMakeLists,只改 ORZ_BUILD_SHARED=OFF)
#     消费方(如 OrzMusic)把它和自己的 JNI 胶水编进单个 .so
# ---------------------------------------------------------------------------
build_core_static() {
    local abi="$1"
    local native_out="$BUILD_DIR/native-android-$abi"
    local build_dir="$CMAKE_DIR/android-$abi-static"

    log "构建 OrzAudioCore 静态归档($abi)..."
    rm -rf "$build_dir"
    cmake -S "$ROOT" -B "$build_dir" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DORZ_PROFILE=full \
        -DORZ_BUILD_SHARED=OFF \
        -DORZ_BUILD_TESTS=OFF \
        -DORZ_NATIVE_LIB="$native_out" \
        -DZLIB_LIBRARY="$TOOLCHAIN/sysroot/usr/lib/$(abi_triple "$abi")/$API_LEVEL/libz.so" \
        -DZLIB_INCLUDE_DIR="$TOOLCHAIN/sysroot/usr/include" \
        > "$build_dir.configure.log" 2>&1 \
        || { tail -30 "$build_dir.configure.log"; err "$abi 静态配置失败"; }
    cmake --build "$build_dir" -j "$JOBS" > "$build_dir.build.log" 2>&1 \
        || { tail -40 "$build_dir.build.log"; err "$abi 静态编译失败"; }

    [[ -f "$build_dir/libOrzAudioCore.a" ]] || err "缺少 $build_dir/libOrzAudioCore.a"
    log "静态归档:$(du -h "$build_dir/libOrzAudioCore.a" | cut -f1)"
}

# ---------------------------------------------------------------------------
# 3) 主流程
# ---------------------------------------------------------------------------
if ! $SKIP_MANIFEST_CHECK; then
    if command -v node >/dev/null 2>&1; then
        node "$ROOT/script/generate-decoder-manifest.mjs" --check
    else
        warn "没有 node,跳过 decoder-manifest 一致性检查(CI 会跑)"
    fi
fi

for abi in "${ABIS[@]}"; do
    build_deps "$abi"
    build_core "$abi"
    build_core_static "$abi"
done

log "=== Android 构建完成 ==="
for abi in "${ABIS[@]}"; do
    ls -lh "$CMAKE_DIR/android-$abi/libOrzAudioCore.so" \
           "$CMAKE_DIR/android-$abi-static/libOrzAudioCore.a" 2>/dev/null || true
done
echo ""
log "打包:./script/package-android-sdk.sh <输出目录>"
