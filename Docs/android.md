# Android SDK

`full` profile（23 个格式）的 Android 产物：一个 ABI 一组 `libOrzAudioCore`，
外加共享头、清单、SBOM 与全部第三方许可证原文。

## 资产布局

```
OrzAudioCore-<ver>-android-full/
  android/arm64-v8a/libOrzAudioCore.so      # 共享库：可直接 System.loadLibrary
  android/arm64-v8a/libOrzAudioCore.a       # 静态库：给 JNI 胶水层嵌入
  android/armeabi-v7a/…
  native/include/orz_audio_core.h
  metadata/decoder-manifest.json
  metadata/android.json                     # ABI / API level / NDK / 每个 .so 的 sha256
  metadata/build-info.json                  # 生成时间、解码器数、格式数
  metadata/sbom.cdx.json                    # CycloneDX SBOM
  licenses/*                                # 每个解码库的实际许可证原文
  README.md
```

`ANDROID_PLATFORM` 固定 **android-29**（消费方 minSdk 29）。

## 两种接入方式

### A. 直接加载共享库

```kotlin
System.loadLibrary("OrzAudioCore")
```

适合语言绑定（Kotlin/JNI 胶水）用 `dlopen`/`System.loadLibrary` 找符号，
不需要自己重编任何解码器。

### B. 静态库 + 自己的 JNI 胶水（OrzMusic 采用）

```cmake
# 单 .so 分发：JNI 胶水 + 静态核心,避免 APK 里出现两个库
add_library(orzaudio SHARED orz_jni.c)
target_link_libraries(orzaudio PRIVATE ${ORZ_ANDROID_ABI_DIR}/libOrzAudioCore.a
                                       log android z m)
target_link_options(orzaudio PRIVATE -Wl,-z,max-page-size=16384)
```

要点：

- 静态归档是 **PIC**（`-fPIC`），可以直接链进 `SHARED`；
- `libOrzAudioCore.a` 已包含全部第三方解码器，**不需要**再单独编 libopenmpt 等；
- 如果链接时报 `undefined reference`，先确认 `libz` / `libm` / `liblog` 都在链接行上；
- 16KB 页对齐：`-Wl,-z,max-page-size=16384`（Android 15+ / Play 要求）。

## 构建（维护者）

```bash
export ANDROID_NDK_HOME=/path/to/ndk/27.0.12077973
./script/fetch-decoder-sources.sh
./script/build-android.sh                 # arm64-v8a + armeabi-v7a
./script/build-android.sh --abi x86_64    # 模拟器
./script/package-android-sdk.sh ~/release
```

`script/build-native-libs.sh` 支持交叉编译覆盖项（`ORZ_BUILD_TAG` / `ORZ_NATIVE_OUT` /
`ORZ_HOST_TRIPLE` / `ORZ_CMAKE_TOOLCHAIN` / `ORZ_INSTALL_HOST_LIBS`），
`script/build-android.sh` 只是按 ABI 设好这些变量并驱动它。

每个 ABI 的构建产物：

- `.wasm-build/native-android-<abi>/lib*.a` —— 9 个第三方静态归档
- `.cmake-build/android-<abi>/libOrzAudioCore.{so,a}` —— 核心库

`script/verify-elf-exports.sh` 会校验只导出 `orz_*`（第三方符号泄漏会导致
JNI 侧符号冲突），CI 的 `android` job 会自动跑。

## 许可证

链接后的 `libOrzAudioCore.so` 整体按 **GPL-3.0-or-later** 分发：

| 组件 | 格式 | 许可证 |
|---|---|---|
| libopenmpt | `xm` `mod` `it` `s3m` `mo3` `mtm` `fc13` `fc14` | BSD-3-Clause |
| game-music-emu | `nsf` `spc` | LGPL-2.1-or-later |
| libsidplayfp | `sid` | GPL-2.0-or-later |
| asap | `sap` | GPL-2.0-or-later |
| sc68（webaudio68） | `sc68` | GPL-3.0-or-later |
| v2m-player | `v2m` | Artistic-2.0 |
| ahx2play | `ahx` `thx` | BSD-3-Clause |
| libadplug + libbinio | `rad` `d00` `hsc` `amd` | LGPL-2.1-or-later |

GPL 生效的只有 `sid` / `sap` / `sc68` 三个；其余是宽松或 LGPL（可升级到 GPLv3）。
bundle 里不含 C64 kernal/basic ROM —— `sid` 只保证 PSID，RSID 需要调用方自备 ROM。

## 实测与已知坑（2026-11，NDK r27b / API 29）

- 单 ABI 全量构建约 8~12 分钟（首次要编 9 个第三方库），之后 `build-android.sh`
  用 `.wasm-build/native-android-<abi>/.complete` 跳过。
- 消费方把静态库链进自己的 JNI `.so` 时，**必须**加 version script 只导出 JNI 入口，
  否则会把 ASAP/adplug/sidplayfp/sc68/gme 的几千个符号一起导出
  （实测 5695 个）。参考 OrzMusic 的 `audio-kit/native/cpp/orzaudio.map`。
- 静态库链接进 C-only target 时要用 C++ 链接器（CMake 里 `LINKER_LANGUAGE CXX`），
  否则会缺 `operator new` / `__cxa_guard_acquire`。
- `sid` 只保证 PSID；C64 kernal/basic ROM 不随包分发。

## 与其它平台的一致性

同一个 `decoder-manifest.json` 驱动服务端、Web/WASM、Apple 与 Android。
`orz_get_format_count()` / `orz_get_format_info()` 在运行期报告**本二进制实际编进来的**
格式（注册表用弱符号存根过滤缺失解码器），所以清单与二进制不同步时表现为
「格式被隐藏」而不是播错。
