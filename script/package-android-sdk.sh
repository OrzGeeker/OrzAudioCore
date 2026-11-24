#!/usr/bin/env bash
# ============================================================================
# 打包 Android SDK 资产
# ============================================================================
# 前置:./script/fetch-decoder-sources.sh && ./script/build-android.sh
#
# 产物:
#   <OUT>/OrzAudioCore-<ver>-android-full.tar.gz
#   <OUT>/OrzAudioCore-<ver>-android-full.tar.gz.sha256
#
# 包内布局:
#   OrzAudioCore-<ver>-android-full/
#     android/<abi>/libOrzAudioCore.so      # 通用共享库(可直接 System.loadLibrary)
#     android/<abi>/libOrzAudioCore.a       # 静态库(给 JNI 胶水层嵌入,单 .so 分发)
#     native/include/orz_audio_core.h
#     metadata/decoder-manifest.json
#     metadata/build-info.json              # 有 node 时生成
#     metadata/sbom.cdx.json                # 有 node 时生成
#     metadata/android.json                 # ABI / API level / NDK 版本 / 哈希
#     licenses/*                            # 每个解码库的实际许可证原文
#     README.md
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.cmake-build/release}"
VERSION="$(sed -n 's/.*"sdkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/decoder-manifest.json" | head -1)"
PRESET="android-full"
STAGE="$OUT/OrzAudioCore-$VERSION-$PRESET"
SRC_DIR="$ROOT/.wasm-build/src"

log()  { printf '[ANDROID-PKG] %s\n' "$*"; }
err()  { printf '[ANDROID-PKG] %s\n' "$*" >&2; exit 1; }

[[ -n "$VERSION" ]] || err "无法从 decoder-manifest.json 读取 sdkVersion"

ABIS=()
for dir in "$ROOT"/.cmake-build/android-*/libOrzAudioCore.so; do
    [[ -f "$dir" ]] || continue
    abi="${dir%/libOrzAudioCore.so}"
    ABIS+=("${abi##*/android-}")
done
(( ${#ABIS[@]} > 0 )) || err "没有找到 Android 产物 —— 先跑 ./script/build-android.sh"

# 把核心归档和 9 个第三方归档合成**一个自包含**的静态库:
# 消费方(如 OrzMusic 的 JNI 胶水)只需要链一个 .a,不用关心 9 个依赖的顺序。
merge_archives() {
    local abi="$1" core_a="$2" deps_dir="$3" out="$4"
    local ar_tool=""
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        ar_tool="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$( [[ "$(uname -s)" == Darwin ]] && echo darwin-x86_64 || echo linux-x86_64 )/bin/llvm-ar"
    fi
    [[ -x "$ar_tool" ]] || ar_tool="$(command -v llvm-ar || command -v ar)"
    [[ -n "$ar_tool" ]] || err "找不到 llvm-ar/ar"

    local script_file
    script_file="$(mktemp)"
    {
        echo "CREATE $out"
        echo "ADDLIB $core_a"
        local lib
        for lib in openmpt gme sidplayfp binio adplug sc68 asap v2m ahx2play; do
            [[ -f "$deps_dir/lib$lib.a" ]] || err "$abi 缺少 lib$lib.a"
            echo "ADDLIB $deps_dir/lib$lib.a"
        done
        echo "SAVE"
        echo "END"
    } > "$script_file"
    rm -f "$out"
    "$ar_tool" -M < "$script_file" || err "$abi 合并静态归档失败"
    rm -f "$script_file"
    "$ar_tool" s "$out" 2>/dev/null || true
    [[ -s "$out" ]] || err "$abi 合并后的静态归档为空"
}

rm -rf "$STAGE"
mkdir -p "$STAGE/android" "$STAGE/native/include" "$STAGE/metadata" "$STAGE/licenses"

for abi in "${ABIS[@]}"; do
    build_dir="$ROOT/.cmake-build/android-$abi"
    staging="$STAGE/android/$abi"
    mkdir -p "$staging"
    static_dir="$ROOT/.cmake-build/android-$abi-static"
    cp "$build_dir/libOrzAudioCore.so" "$staging/"
    if [[ -f "$static_dir/libOrzAudioCore.a" ]]; then
        merge_archives "$abi" "$static_dir/libOrzAudioCore.a" \
            "$ROOT/.wasm-build/native-android-$abi" "$staging/libOrzAudioCore.a"
    else
        log "$abi: 没有静态归档(先跑 build-android.sh 生成 android-$abi-static)"
    fi
    log "$abi: $(du -h "$staging/libOrzAudioCore.so" | cut -f1) shared, $(
        [[ -f "$staging/libOrzAudioCore.a" ]] && du -h "$staging/libOrzAudioCore.a" | cut -f1 || echo "无静态库")"
done

cp "$ROOT/Sources/OrzAudioKitCXX/include/orz_audio_core.h" "$STAGE/native/include/"
cp "$ROOT/decoder-manifest.json" "$STAGE/metadata/decoder-manifest.json"
cp "$ROOT/LICENSE" "$STAGE/licenses/OrzAudioCore-LICENSE"
cp "$ROOT/Sources/OrzAudioKitCXX/ym6/lhasa/COPYING.md" "$STAGE/licenses/lhasa-COPYING.md"

# ---------------------------------------------------------------------------
# 许可证:随二进制分发的每一个第三方库都必须带原文
# ---------------------------------------------------------------------------
copy_license() {
    local name="$1" path="$2" target="$3"
    [[ -f "$SRC_DIR/$path" ]] || err "缺少 $name 的许可证原文:$SRC_DIR/$path(先跑 fetch-decoder-sources.sh)"
    cp "$SRC_DIR/$path" "$STAGE/licenses/$target"
}

copy_license libopenmpt        libopenmpt/LICENSE                  libopenmpt-LICENSE
copy_license libgme            game-music-emu/license.txt          game-music-emu-LICENSE
copy_license libgme            game-music-emu/license.gpl2.txt     game-music-emu-GPL2.txt
copy_license libbinio          libbinio/COPYING                    libbinio-COPYING
copy_license libadplug         adplug/COPYING                      libadplug-COPYING
copy_license libsidplayfp      libsidplayfp/COPYING                libsidplayfp-COPYING
copy_license asap              asap/COPYING                        asap-COPYING
copy_license sc68              sc68/README                         sc68-README-GPL3.txt
copy_license v2m               v2m/LICENSE                         v2m-player-LICENSE
copy_license ahx2play          ahx2play/LICENSE                    ahx2play-LICENSE

cat > "$STAGE/licenses/README.md" <<'EOF'
# 许可证清单

`libOrzAudioCore.so` 静态链接了下列组件。每个条目的许可证原文在同目录下。

| 组件 | 格式 | 许可证 | 原文 |
|---|---|---|---|
| OrzAudioCore | C ABI、`ym`(ym6)、`mid`(midi)、`bp`(soundmon) | Apache-2.0 | `OrzAudioCore-LICENSE` |
| lhasa | ym6 的 LHA 解压 | ISC | `lhasa-COPYING.md` |
| libopenmpt | `xm` `mod` `it` `s3m` `mo3` `mtm` `fc13` `fc14` | BSD-3-Clause | `libopenmpt-LICENSE` |
| game-music-emu | `nsf` `spc` | LGPL-2.1-or-later | `game-music-emu-LICENSE` |
| libsidplayfp | `sid` | GPL-2.0-or-later | `libsidplayfp-COPYING` |
| asap | `sap` | GPL-2.0-or-later | `asap-COPYING` |
| sc68 (webaudio68) | `sc68` | GPL-3.0-or-later | `sc68-README-GPL3.txt` |
| v2m-player | `v2m` | Artistic-2.0 | `v2m-player-LICENSE` |
| ahx2play | `ahx` `thx` | BSD-3-Clause | `ahx2play-LICENSE` |
| libadplug / libbinio | `rad` `d00` `hsc` `amd` | LGPL-2.1-or-later | `libadplug-COPYING` / `libbinio-COPYING` |

链接后的 `libOrzAudioCore.so` 整体按 **GPL-3.0-or-later** 分发（GPL-2.0-or-later 与
LGPL-2.1-or-later 组件可按其 "or later" 条款升级到 GPLv3；Artistic-2.0 与
BSD-3-Clause 与 GPLv3 兼容）。

**不包含** C64 kernal/basic ROM：`sid` 只保证 PSID 曲目可播，需要 ROM 的 RSID
曲目由调用方自行处理。
EOF

# ---------------------------------------------------------------------------
# 元数据
# ---------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}" \
        node "$ROOT/script/generate-release-metadata.mjs" "$STAGE" --profile full --platform android
else
    log "没有 node,跳过 sbom/build-info 生成"
fi

{
    printf '{\n'
    printf '  "sdkVersion": "%s",\n' "$VERSION"
    printf '  "profile": "%s",\n' "$PRESET"
    printf '  "apiLevel": %s,\n' "${ORZ_ANDROID_API:-29}"
    printf '  "ndk": "%s",\n' "$(basename "${ANDROID_NDK_HOME:-unknown}")"
    printf '  "abis": [\n'
    first=1
    for abi in "${ABIS[@]}"; do
        (( first )) || printf ',\n'
        first=0
        sha="$(shasum -a 256 "$STAGE/android/$abi/libOrzAudioCore.so" | awk '{print $1}')"
        size="$(wc -c < "$STAGE/android/$abi/libOrzAudioCore.so" | tr -d ' ')"
        printf '    {"abi": "%s", "soSha256": "%s", "soBytes": %s}' "$abi" "$sha" "$size"
    done
    printf '\n  ]\n}\n'
} > "$STAGE/metadata/android.json"

cp "$ROOT/Docs/android.md" "$STAGE/README.md" 2>/dev/null || cp "$ROOT/Docs/orz-audio-core.md" "$STAGE/README.md"

tar -C "$OUT" -czf "$STAGE.tar.gz" "$(basename "$STAGE")"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$STAGE")" && sha256sum "$(basename "$STAGE").tar.gz") > "$STAGE.tar.gz.sha256"
else
    (cd "$(dirname "$STAGE")" && shasum -a 256 "$(basename "$STAGE").tar.gz") > "$STAGE.tar.gz.sha256"
fi

if [[ "${ORZ_SKIP_VERIFY:-0}" != "1" ]]; then
    node "$ROOT/script/verify-artifact.mjs" "$STAGE.tar.gz"
fi
log "ABI: ${ABIS[*]}"
log "产物: $STAGE.tar.gz"
cat "$STAGE.tar.gz.sha256"
