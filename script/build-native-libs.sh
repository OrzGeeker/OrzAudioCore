#!/usr/bin/env bash
# ============================================================================
# OrzAudioKit Native Library Build Script
# ============================================================================
# Compiles audio decoder libraries from source for the host platform.
# Reuses downloaded sources from .wasm-build/ (shared with WASM build).
# Outputs .a files to .wasm-build/native/ for SPM static linking.
#
# Zero system dependency — no brew install, no apt install.
# Version-locked — same versions as WASM build (libopenmpt 0.8.0, etc.)
# Cross-platform — same script works on macOS ARM/x64 and Linux.
#
# Usage:
#   ./script/build-native-libs.sh              # Build all libraries
#   ./script/build-native-libs.sh --only-openmpt # Build only libopenmpt
#   ./script/build-native-libs.sh --clean       # Clean native artifacts
#
# Cross-compilation (used by script/build-android.sh) — every override is optional
# and defaults to the host-native behaviour:
#   ORZ_BUILD_TAG=<tag>             build-<lib>-<tag> directory suffix (default: native)
#   ORZ_NATIVE_OUT=<dir>            where the .a files land (default: $BUILD_DIR/native)
#   ORZ_HOST_TRIPLE=<triple>        configure --host (default: detected host)
#   ORZ_CMAKE_TOOLCHAIN=<file>      passed as -DCMAKE_TOOLCHAIN_FILE to the cmake libs
#   ORZ_CMAKE_EXTRA_ARGS=<args>     extra -D flags for the cmake libs (space separated)
#   ORZ_INSTALL_HOST_LIBS=0         do not copy archives into Libraries/OrzAudioKit/native
# ============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.wasm-build"
SRC_DIR="$BUILD_DIR/src"
NATIVE_DIR="$BUILD_DIR/native"
CACHE_DIR="$BUILD_DIR/cache"
INSTALL_DIR="$PROJECT_DIR/Libraries/OrzAudioKit/native"

# 交叉编译覆盖项(默认值与原生构建完全一致)
BUILD_TAG=${ORZ_BUILD_TAG:-native}
NATIVE_DIR=${ORZ_NATIVE_OUT:-$BUILD_DIR/native}
INSTALL_HOST_LIBS=${ORZ_INSTALL_HOST_LIBS:-1}
CMAKE_CROSS_ARGS=()
if [ -n "${ORZ_CMAKE_TOOLCHAIN:-}" ]; then
    CMAKE_CROSS_ARGS+=("-DCMAKE_TOOLCHAIN_FILE=$ORZ_CMAKE_TOOLCHAIN")
fi
if [ -n "${ORZ_CMAKE_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206  # 有意按空格切分:-D 列表由调用方拼好
    CMAKE_CROSS_ARGS+=(${ORZ_CMAKE_EXTRA_ARGS})
fi

JOBS=${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)}
# Cross builds must archive with the target toolchain. Using the host `ar` on
# ELF objects produces an archive the target linker cannot read.
AR_TOOL="${AR:-ar}"
RANLIB_TOOL="${RANLIB:-ranlib}"
HOST_CC=${CC:-clang}
HOST_CXX=${CXX:-clang++}
NATIVE_CFLAGS=${CFLAGS:-}
NATIVE_CXXFLAGS=${CXXFLAGS:-}
if [ "$(uname -s)" = "Darwin" ]; then
    # Only inject the macOS deployment target for host builds. iOS/Android
    # cross builds provide their own -target/-mios-version-min via CC/CXX.
    if [ -z "${ORZ_HOST_TRIPLE:-}" ]; then
        MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
        export MACOSX_DEPLOYMENT_TARGET
        NATIVE_CFLAGS="$NATIVE_CFLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        NATIVE_CXXFLAGS="$NATIVE_CXXFLAGS -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    fi
else
    # Full/server SDK produces a shared object on Linux, so every archive
    # linked into it (including TLS-based AHX state) must be position independent.
    NATIVE_CFLAGS="$NATIVE_CFLAGS -fPIC"
    NATIVE_CXXFLAGS="$NATIVE_CXXFLAGS -fPIC"
fi

# Detect host architecture for --host flag in configure
detect_host() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$arch" in
        x86_64)  echo "x86_64-unknown-${os}-gnu" ;;
        arm64)   echo "aarch64-apple-${os}" ;;
        aarch64) echo "aarch64-unknown-${os}-gnu" ;;
        *)       echo "$arch-unknown-${os}" ;;
    esac
}
HOST="${ORZ_HOST_TRIPLE:-$(detect_host)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { printf "${GREEN}[BUILD]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERR]${NC} %s\n" "$*"; exit 1; }

CLEAN=false
ONLY_LIB=""
STRICT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=true; shift ;;
        --strict) STRICT=true; shift ;;
        --only-*) ONLY_LIB="${1#--only-}"; shift ;;
        *) err "Unknown option: $1" ;;
    esac
done

mkdir -p "$NATIVE_DIR"

install_native_libraries() {
    # 交叉编译时不写仓库内的 host 归档(会污染 Libraries/OrzAudioKit/native)。
    [ "$INSTALL_HOST_LIBS" = "1" ] || return 0
    mkdir -p "$INSTALL_DIR"
    local library basename
    for library in "$NATIVE_DIR"/*.a; do
        [ -f "$library" ] || continue
        basename="${library##*/}"
        [ "$basename" = "liblibbinio.a" ] && basename="libbinio.a"
        cp "$library" "$INSTALL_DIR/$basename"
    done
}

# Configure systems do not reliably rebuild existing objects when only the
# deployment target/flags change. Native build directories are disposable, so
# start each library from a clean directory to keep archive metadata honest.
prepare_build_directory() {
    rm -rf "$1"
    mkdir -p "$1"
}

if $CLEAN; then
    log "Cleaning native build artifacts..."
    rm -rf "$NATIVE_DIR" "$BUILD_DIR/build-*-$BUILD_TAG"
    log "Done."
    exit 0
fi

# ============================================================================
# libopenmpt (autotools) — XM, MOD, IT, S3M, MO3, MTM, FC13, FC14
# ============================================================================
build_libopenmpt() {
    log "Building libopenmpt..."
    local src_dir="$SRC_DIR/libopenmpt"
    local build_dir="$BUILD_DIR/build-libopenmpt-$BUILD_TAG"
    local output="$NATIVE_DIR/libopenmpt.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libopenmpt source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    log "Configuring libopenmpt (native)..."
    CC="$HOST_CC" CXX="$HOST_CXX" CFLAGS="$NATIVE_CFLAGS" CXXFLAGS="$NATIVE_CXXFLAGS" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        --disable-examples \
        --disable-tests \
        --disable-openmpt123 \
        --without-mpg123 \
        --without-ogg \
        --without-vorbis \
        --without-vorbisfile \
        --without-portaudio \
        --without-sdl2 \
        --without-flac \
        --without-zlib \
        >"$build_dir/configure.log" 2>&1 || {
            warn "libopenmpt configure failed"
            tail -30 "$build_dir/configure.log" >&2
            popd >/dev/null
            return 1
        }

    log "Compiling libopenmpt..."
    make -j"$JOBS" >"$build_dir/build.log" 2>&1 || {
        warn "libopenmpt make failed"
        tail -30 "$build_dir/build.log" >&2
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    # Find the .a file
    local libfile=""
    for try in "$build_dir/.libs/libopenmpt.a" "$build_dir/libopenmpt.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libopenmpt.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libopenmpt.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# Game Music Emu (cmake) — NSF, SPC
# ============================================================================
build_libgme() {
    log "Building Game Music Emu..."
    local src_dir="$SRC_DIR/game-music-emu"
    local build_dir="$BUILD_DIR/build-gme-$BUILD_TAG"
    local output="$NATIVE_DIR/libgme.a"

    if [ ! -d "$src_dir" ]; then
        warn "GME source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1
    local configure_log="$build_dir/configure.log"
    local build_log="$build_dir/build.log"

    # 交叉编译参数用 ${arr[@]+"${arr[@]}"} 展开:macOS 自带 bash 3.2 在 set -u 下
    # 会把空数组的 "${arr[@]}" 当 unbound variable(CI 上 full-macos 因此红过)。
    CC="$HOST_CC" CXX="$HOST_CXX" CFLAGS="$NATIVE_CFLAGS" CXXFLAGS="$NATIVE_CXXFLAGS" \
    cmake "$src_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-}" \
        -DENABLE_UBSAN=OFF \
        -DGME_ENABLE_SPC=ON \
        -DGME_ENABLE_NSF=ON \
        -DGME_ENABLE_GBS=OFF \
        -DGME_ENABLE_GYM=OFF \
        -DGME_ENABLE_HES=OFF \
        ${CMAKE_CROSS_ARGS[@]+"${CMAKE_CROSS_ARGS[@]}"} \
        >"$configure_log" 2>&1 || {
            warn "GME cmake failed"
            cat "$configure_log" >&2
            popd >/dev/null
            return 1
        }

    cmake --build . --parallel "$JOBS" >"$build_log" 2>&1 || {
        warn "GME build failed"
        cat "$build_log" >&2
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/gme/libgme.a" "$build_dir/libgme.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libgme.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libgme.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# libsidplayfp (autotools) — SID
# ============================================================================
build_libsidplayfp() {
    log "Building libsidplayfp..."
    local src_dir="$SRC_DIR/libsidplayfp"
    local build_dir="$BUILD_DIR/build-sidplayfp-$BUILD_TAG"
    local output="$NATIVE_DIR/libsidplayfp.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libsidplayfp source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    log "Configuring libsidplayfp (native)..."
    CC="$HOST_CC" CXX="$HOST_CXX" CFLAGS="$NATIVE_CFLAGS" CXXFLAGS="$NATIVE_CXXFLAGS" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        >"$build_dir/configure.log" 2>&1 || {
            warn "libsidplayfp configure failed"
            tail -30 "$build_dir/configure.log" >&2
            popd >/dev/null
            return 1
        }

    log "Compiling libsidplayfp..."
    make -j"$JOBS" >"$build_dir/build.log" 2>&1 || {
        warn "libsidplayfp make failed"
        tail -30 "$build_dir/build.log" >&2
        popd >/dev/null
        return 1
    }

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/libsidplayfp.a" "$build_dir/libsidplayfp.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libsidplayfp.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libsidplayfp.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# libbinio (autotools) — binary I/O, dependency of AdPlug
# ============================================================================
build_libbinio() {
    log "Building libbinio..."
    local src_dir="$SRC_DIR/libbinio"
    local build_dir="$BUILD_DIR/build-libbinio-$BUILD_TAG"
    local output="$NATIVE_DIR/libbinio.a"

    # Download source if not present
    local BINIO_VERSION="1.5"
    local BINIO_URL="https://github.com/adplug/libbinio/releases/download/libbinio-${BINIO_VERSION}/libbinio-${BINIO_VERSION}.tar.gz"

    if [ ! -f "$src_dir/configure" ]; then
        warn "libbinio source not found at $src_dir, need to download"
        mkdir -p "$SRC_DIR/libbinio"
        curl -sL "$BINIO_URL" | tar xz -C "$SRC_DIR/libbinio" --strip-components=1 2>/dev/null || {
            warn "libbinio download failed"
            return 1
        }
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    CC="$HOST_CC" CXX="$HOST_CXX" CFLAGS="$NATIVE_CFLAGS" CXXFLAGS="$NATIVE_CXXFLAGS" \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        >"$build_dir/configure.log" 2>&1 || {
            warn "libbinio configure failed"
            tail -30 "$build_dir/configure.log" >&2
            popd >/dev/null
            return 1
        }

    # libbinio's generated libtool appends archive members non-atomically.
    if ! make -j1 >/dev/null 2>&1; then
        # libtool 1.x is unreliable with current Apple toolchains. Its static
        # target is only four translation units, so use a deterministic direct
        # archive fallback with the same public headers.
        warn "libbinio libtool failed; using direct static archive fallback"
        local objects=()
        local source object
        for source in binio.cpp binfile.cpp binwrap.cpp binstr.cpp; do
            object="$build_dir/${source%.cpp}.o"
            "$HOST_CXX" $NATIVE_CXXFLAGS -Wno-register -I"$src_dir/src" -c "$src_dir/src/$source" -o "$object" || {
                popd >/dev/null
                return 1
            }
            objects+=("$object")
        done
        "$AR_TOOL" rcs "$output" "${objects[@]}"
        "$RANLIB_TOOL" "$output"
        mkdir -p "$build_dir/src/.libs"
        cp "$output" "$build_dir/src/.libs/libbinio.a"
        popd >/dev/null
        log "libbinio.a → $output ($(du -h "$output" | cut -f1))"
        echo "$NATIVE_DIR"
        return 0
    fi

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/libbinio.a" "$build_dir/libbinio.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libbinio.a not found after build"
        return 1
    fi

    cp "$libfile" "$output"
    log "libbinio.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# AdPlug (autotools) — OPL2/3 formats (RAD, D00, HSC)
# ============================================================================
build_adplug() {
    log "Building AdPlug..."
    local src_dir="$SRC_DIR/adplug"
    local build_dir="$BUILD_DIR/build-adplug-$BUILD_TAG"
    local output="$NATIVE_DIR/libadplug.a"

    if [ ! -f "$src_dir/configure" ]; then
        warn "AdPlug source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    # AdPlug needs libbinio
    local binio_prefix="$BUILD_DIR/build-libbinio-$BUILD_TAG"

    CC="$HOST_CC" CXX="$HOST_CXX" CFLAGS="$NATIVE_CFLAGS" CXXFLAGS="$NATIVE_CXXFLAGS" \
    CPPFLAGS="-I$binio_prefix" \
    LDFLAGS="-L$binio_prefix/src/.libs" \
    libbinio_CFLAGS="-I$SRC_DIR/libbinio/src" \
    libbinio_LIBS="$binio_prefix/src/.libs/libbinio.a" \
    ac_cv_header_sys_io_h=no \
    "$src_dir/configure" \
        --host="$HOST" \
        --disable-shared \
        --enable-static \
        --with-binio="$binio_prefix" \
        >"$build_dir/configure.log" 2>&1 || {
            warn "AdPlug configure failed"
            tail -30 "$build_dir/configure.log" >&2
            popd >/dev/null
            return 1
        }

    # Only build the library target: the adplugdb CLI is not part of the SDK
    # and does not link reliably when libtool 1.x meets modern toolchains.
    make -j1 src/libadplug.la >/dev/null 2>&1 || true
    # Old libtool can leave a symbol-table-only archive. Rebuild the archive
    # deterministically from the successfully compiled library objects.
    local adplug_objects=(src/libadplug_la-*.o)
    if [ ! -f "${adplug_objects[0]}" ]; then
        warn "AdPlug library objects were not produced"
        popd >/dev/null
        return 1
    fi
    "$AR_TOOL" rcs "$output" "${adplug_objects[@]}"
    "$RANLIB_TOOL" "$output"
    mkdir -p "$build_dir/src/.libs"
    cp "$output" "$build_dir/src/.libs/libadplug.a"

    popd >/dev/null

    local libfile=""
    for try in "$build_dir/src/.libs/libadplug.a" "$build_dir/libadplug.a"; do
        if [ -f "$try" ]; then libfile="$try"; break; fi
    done

    if [ -z "$libfile" ]; then
        warn "libadplug.a not found after build"
        return 1
    fi

    [ "$libfile" = "$output" ] || cp "$libfile" "$output"
    log "libadplug.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}


# ============================================================================
# sc68 (Atari ST YM / Amiga format) — manual .c compilation
# ============================================================================
build_libsc68() {
    log "Building sc68..."
    local src_dir="$SRC_DIR/sc68"
    local build_dir="$BUILD_DIR/build-sc68-$BUILD_TAG"
    local output="$NATIVE_DIR/libsc68.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/api68/api68.h" ]; then
        warn "sc68 source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    local C_FILES=()
    # 只编译库核心模块，排除 sc68/（CLI 工具，含 main()）
    for d in api68 emu68 file68 io68 unice68; do
        for f in "$src_dir/$d"/*.c; do
            [ -f "$f" ] && C_FILES+=("$f")
        done
    done
    # 添加 rsc68 存根（替换原版 rsc68，避免依赖原始 SC68 资源管理）
    [ -f "$src_dir/file68/rsc68_stub.c" ] && C_FILES+=("$src_dir/file68/rsc68_stub.c")

    if [ ${#C_FILES[@]} -eq 0 ]; then
        warn "No sc68 source files found"
        popd >/dev/null; return 1
    fi

    local inc_flags="-I$src_dir -I$src_dir/file68 -I$src_dir/api68"
    # EMSCRIPTEN_KEEPALIVE 在原生编译时定义为空
    # ahx2play also exports `paula`; namespace sc68's Paula state so both real
    # emulators can be linked without substituting a silent implementation.
    local cflags="-Wno-pointer-sign -Wno-incompatible-function-pointer-types -O3 -DEMSCRIPTEN_KEEPALIVE= -DEMSCRIPTEN=1 -Dpaula=sc68_paula -Dpaulav=sc68_paulav"
    local compile_ok=0
    for cfile in "${C_FILES[@]}"; do
        local basename="${cfile##*/}"
        local dirpart="${cfile%/*}"
        local subdir="${dirpart##*/}"
        local objname="${subdir}_${basename%.c}.o"
        $HOST_CC $NATIVE_CFLAGS -c "$cfile" -o "$objname" $inc_flags $cflags 2>/dev/null && compile_ok=$((compile_ok + 1))
    done

    local objs=( *.o )
    if [ ${#objs[@]} -eq 0 ]; then
        warn "No sc68 object files produced"
        popd >/dev/null; return 1
    fi

    "$AR_TOOL" cr "$output" "${objs[@]}" 2>/dev/null && "$RANLIB_TOOL" "$output" 2>/dev/null
    log "libsc68.a → $output (${#objs[@]} objects, ${compile_ok}/${#C_FILES[@]} compiled)"
    echo "$NATIVE_DIR"
}

# ============================================================================
# ASAP (Atari POKEY format: sap) — requires xasm 6502 assembler
# ============================================================================
build_libasap() {
    log "Building ASAP..."
    local src_dir="$SRC_DIR/asap"
    local build_dir="$BUILD_DIR/build-asap-$BUILD_TAG"
    local output="$NATIVE_DIR/libasap.a"

    if [ ! -f "$src_dir/asap.h" ]; then
        warn "ASAP source not found at $src_dir"
        return 1
    fi

    # ASAP 的 asap.c 是预生成的（从 .fu 文件），可以直接编译
    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    $HOST_CC $NATIVE_CFLAGS -c "$src_dir/asap.c" -o asap.o -I"$src_dir" -O2 2>/dev/null || {
        warn "ASAP compile failed"; popd >/dev/null; return 1
    }
    "$AR_TOOL" cr "$output" asap.o 2>/dev/null && "$RANLIB_TOOL" "$output" 2>/dev/null
    log "libasap.a → $output ($(du -h "$output" | cut -f1))"
    echo "$NATIVE_DIR"
}

# ============================================================================
# uade / UAE Amiga emulator (AHX, FC14 formats)
# ============================================================================
build_libuade() {
    log "Building uade (UAE Amiga emulator core)..."
    local src_dir="$SRC_DIR/uade"
    local build_dir="$BUILD_DIR/build-uade-$BUILD_TAG"
    local output="$NATIVE_DIR/libuade.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/newcpu.c" ]; then
        warn "UAE core source not available at $src_dir, trying uade-3.05..."
        src_dir="$SRC_DIR/uade-3.05/src"
        [ ! -f "$src_dir/newcpu.c" ] && { warn "UAE core not found"; return 1; }
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    local uade_core_files=(
        newcpu.c memory.c custom.c cia.c audio.c missing.c
        readcpu.c sd-sound-generic.c
    )

    # 首先生成 68000 CPU 指令表
    local cpustbl_src=""
    local gen_dir="$BUILD_DIR/src/uade"
    if [ -d "$gen_dir" ] && [ -f "$gen_dir/cpustbl.c" ]; then
        cpustbl_src="$gen_dir"
    else
        # 用 uade-3.05 完整源码生成
        local uade_src="$SRC_DIR/uade-3.05"
        if [ -f "$uade_src/src/build68k.c" ] && [ -f "$uade_src/src/table68k" ]; then
            log "Generating 68000 CPU tables..."
            $HOST_CC $NATIVE_CFLAGS -o "${build_dir}/build68k" "$uade_src/src/build68k.c" \
                -I"$uade_src/src" -I"$uade_src/src/include" \
                -include "$uade_src/src/sysconfig.h" -lm 2>/dev/null || {
                warn "build68k compile failed"; popd >/dev/null; return 1
            }
            # 生成 CPU 表文件
            (cd "$uade_src/src" && "${build_dir}/build68k" > "${build_dir}/cpustbl.c" 2>/dev/null)
            if [ ! -s "${build_dir}/cpustbl.c" ] || [ "$(grep -c 'n_defs68k' "${build_dir}/cpustbl.c")" -eq 0 ]; then
                warn "build68k generated empty CPU table (uade will use stub)"
                # 创建空存根
                echo 'struct instr_def defs68k[] = {}; int n_defs68k = 0;' > "${build_dir}/cpustbl.c"
            fi
            cpustbl_src="$build_dir"
        else
            warn "UAE source incomplete — build68k or table68k missing"
        fi
    fi

    local inc_dirs="-I$uade_src/src -I$uade_src/src/include"
    [ -n "$cpustbl_src" ] && inc_dirs="$inc_dirs -I$cpustbl_src"
    local cflags="-Dunlikely(x)=__builtin_expect((x),0) -O2"
    local compile_ok=0

    for f in "${uade_core_files[@]}"; do
        local src_file="$SRC_DIR/uade-3.05/src/$f"
        [ ! -f "$src_file" ] && continue
        local objname="${f//\//_}.o"
        $HOST_CC $NATIVE_CFLAGS -c "$src_file" -o "$objname" $inc_dirs -include "$SRC_DIR/uade-3.05/src/sysconfig.h" $cflags 2>/dev/null && compile_ok=$((compile_ok + 1))
    done
    # 编译 CPU 表（如果生成了）
    if [ -n "$cpustbl_src" ] && [ -f "$cpustbl_src/cpustbl.c" ]; then
        $HOST_CC $NATIVE_CFLAGS -c "$cpustbl_src/cpustbl.c" -o cpustbl.o $inc_dirs -include "$SRC_DIR/uade-3.05/src/sysconfig.h" -O2 2>/dev/null && compile_ok=$((compile_ok + 1))
    fi

    [ $compile_ok -eq 0 ] && { warn "No UAE core files compiled"; popd >/dev/null; return 1; }

    local objs=( *.o )
    "$AR_TOOL" cr "$output" "${objs[@]}" 2>/dev/null && "$RANLIB_TOOL" "$output" 2>/dev/null
    log "libuade.a → $output (${#objs[@]} objects)"
    echo "$NATIVE_DIR"
}

# ============================================================================
# v2m-player (Farbrausch V2 format: v2m)
# ============================================================================
build_libv2m() {
    log "Building v2m-player..."
    local src_dir="$SRC_DIR/v2m"
    local build_dir="$BUILD_DIR/build-v2m-$BUILD_TAG"
    local output="$NATIVE_DIR/libv2m.a"

    if [ ! -d "$src_dir" ] || [ ! -f "$src_dir/src/synth_core.cpp" ]; then
        warn "v2m-player source not found at $src_dir"
        return 1
    fi

    prepare_build_directory "$build_dir"
    pushd "$build_dir" >/dev/null || return 1

    # Compile all v2m source files (与 WASM 构建保持一致)
    local objs=""
    for f in v2mplayer.cpp v2mconv.cpp sounddef.cpp ronan.cpp synth_core.cpp; do
        local src="$src_dir/src/$f"
        if [ -f "$src" ]; then
            local obj_name="${f%.cpp}.o"
            $HOST_CXX $NATIVE_CXXFLAGS -std=c++17 -c "$src" -o "$build_dir/$obj_name" \
                -I"$src_dir/src" -O2 2>"$build_dir/$obj_name.log" || {
                warn "v2m $f compile failed"
                cat "$build_dir/$obj_name.log" >&2
                continue
            }
            objs="$objs $build_dir/$obj_name"
        fi
    done
    if [ -z "$objs" ]; then
        warn "v2m no source files compiled"; popd >/dev/null; return 1
    fi
    "$AR_TOOL" cr "$output" $objs 2>/dev/null && "$RANLIB_TOOL" "$output" 2>/dev/null

    if [ -f "$output" ]; then
        log "libv2m.a → $output ($(du -h "$output" | cut -f1))"
        echo "$NATIVE_DIR"
    else
        warn "v2m build produced no .a file"
        return 1
    fi
}

# ============================================================================
# ahx2play — AHX (same patched Paula core as WASM)
# ============================================================================
build_libahx2play() {
    log "Building ahx2play..."
    local src_dir="$SRC_DIR/ahx2play"
    local build_dir="$BUILD_DIR/build-ahx2play-$BUILD_TAG"
    local output="$NATIVE_DIR/libahx2play.a"
    local install_output="$PROJECT_DIR/Libraries/OrzAudioKit/native/libahx2play.a"
    local reset_patch="$PROJECT_DIR/Sources/OrzAudioKitCXX/uade/ahx2play-reset.patch"
    local context_patch="$PROJECT_DIR/Sources/OrzAudioKitCXX/uade/ahx2play-context.patch"

    if [ ! -f "$src_dir/paula.c" ]; then
        warn "ahx2play source not found at $src_dir"
        return 1
    fi

    patch -N -d "$src_dir" -p1 < "$reset_patch" >/dev/null 2>&1 || true
    patch -N -d "$src_dir" -p1 < "$context_patch" >/dev/null 2>&1 || true
    prepare_build_directory "$build_dir"
    mkdir -p "$(dirname "$install_output")"

    local objs=""
    for f in loader.c replayer.c paula.c; do
        local obj="$build_dir/${f%.c}.o"
        $HOST_CC $NATIVE_CFLAGS -c "$src_dir/$f" -o "$obj" -I"$src_dir" -O2 \
            -include "$PROJECT_DIR/Libraries/OrzAudioKit/thirdparty/ahx2play/mixer_stubs.h" || return 1
        objs="$objs $obj"
    done
    "$AR_TOOL" cr "$output" $objs && "$RANLIB_TOOL" "$output"
    [ "$INSTALL_HOST_LIBS" = "1" ] && cp "$output" "$install_output"
    log "libahx2play.a → $output"
}


# ============================================================================
# Main: build requested libraries
# ============================================================================

if [ -n "$ONLY_LIB" ]; then
    log "Building only: $ONLY_LIB"
    case "$ONLY_LIB" in
        openmpt)     build_libopenmpt ;;
        gme)         build_libgme ;;
        sidplayfp)   build_libsidplayfp ;;
        binio)       build_libbinio ;;
        adplug)      build_libbinio && build_adplug ;;
        sc68)        build_libsc68 ;;
        asap)        build_libasap ;;
        uade)        build_libuade ;;
        v2m)         build_libv2m ;;
        ahx2play)    build_libahx2play ;;
        *)           err "Unknown library: $ONLY_LIB" ;;
    esac
else
    log "Building all native libraries..."
    failures=()
    build_libopenmpt || failures+=(libopenmpt)
    build_libgme || failures+=(gme)
    build_libsidplayfp || failures+=(sidplayfp)
    build_libbinio || failures+=(binio)
    build_adplug || failures+=(adplug)
    build_libsc68 || failures+=(sc68)
    build_libasap || failures+=(asap)
    build_libv2m || failures+=(v2m)
    build_libahx2play || failures+=(ahx2play)
    if (( ${#failures[@]} > 0 )); then
        warn "Failed native libraries: ${failures[*]}"
        $STRICT && err "Strict full-profile build requires every decoder library"
    fi
fi

install_native_libraries

log "=== Native libraries built ==="
ls -lh "$NATIVE_DIR"/*.a 2>/dev/null || echo "(no .a files)"
echo ""
if [ "$INSTALL_HOST_LIBS" = "1" ]; then
    log "Next: update Package.swift with -L$NATIVE_DIR and remove decoder excludes"
fi
