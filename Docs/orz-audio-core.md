# OrzAudioCore SDK

OrzAudioCore 是 OrzMusic 下沉的跨平台解码边界。SDK 只负责格式探测、元数据、subsong/seek 和 PCM 解码；播放设备、队列、HTTP、CAS 与 WAV 缓存仍属于应用层。

## 稳定接口

公共 ABI 位于 `orz_audio_core.h`，当前 ABI 为 1.0。所有公共结构都包含 `struct_size` 与 `abi_version`；调用端必须先填写这两个字段。ABI major 不一致时返回 `ORZ_ERROR_ABI_MISMATCH`。

句柄拥有创建后仍需使用的输入字节，因此调用端在 `orz_decoder_create_memory` 返回后即可释放输入。不同句柄可以并行，同一句柄由调用端串行访问。PCM 输出为 decoder 原生采样率、interleaved float32，SDK 不做隐式重采样。

旧的 `orz_load/orz_render` 和早期 handle API 只作为一个迁移周期的兼容入口。新代码必须使用 `orz_decoder_create_memory`、`orz_decoder_get_stream_info` 和 `orz_decoder_render_f32`。

## 能力与版本

`decoder-manifest.json` 是 decoder ID、版本、分类、profile 和导航能力的单一数据源。修改后运行：

```bash
node script/generate-decoder-manifest.mjs
```

CI 使用 `--check` 阻止提交过期的注册表或 build info。`orz_build_info()` 返回向后兼容 JSON：`sdk`、`version`、`abi`、`profile`、
`fingerprint`、`cacheNamespace`、`formats` 和 `decoders`（id/version）。
`cacheNamespace = orzaudio-<version>-<profile>-<decoderSetHash>`，其中 hash 由
profile 的格式 id 与 `decoder@version` 集合做 SHA-256 得到。升级 SDK、切换
profile 或 decoder 版本变化都会让旧 PCM 缓存自然失效；消费方应把
`cacheNamespace` 写进缓存键。

制品内的 `metadata/build-info.json` 与运行时 JSON 逐字段一致，
`script/verify-artifact.mjs --run-probe` 会在发布前做这项比对。

播放策略不属于 SDK。`directFile/wasmDecode/serverDecode` 由 OrzMusic 根据浏览器能力和性能要求决定。

## 构建与消费

```bash
# 无第三方依赖的 BP/MIDI/YM SDK，并运行 C/C++ consumer 测试
./script/build-sdk.sh builtin-lite

# 当前 macOS 架构的完整 SDK（需要先构建锁定版本的第三方库）
./script/fetch-decoder-sources.sh
./script/build-native-libs.sh --strict
./script/build-sdk.sh "macos-$(uname -m)"

# Swift Package 产品
swift build --product OrzAudioCore

# TypeScript 类型检查
cd SDK/Web && npm run build

# 校验 manifest、npm lockfile、CMake 与发布版本一致性
node script/check-release-readiness.mjs

# 组装可发布的 native SDK tarball、checksum 和 CycloneDX SBOM
./script/package-sdk.sh builtin-lite
```

CMake 输出 `OrzAudioCore::OrzAudioCore` target，并可安装公共头文件和 CMake package。Swift 使用 `AudioDecoder`；Web 包使用 `createDecoder()`，负责 WASM 内存和句柄生命周期；Android AAR 使用 `OrzAudioCore.createDecoder()` 与 `PcmStream`。

下游用 schema-v1 lockfile 固定 `version/tag/commit`、每个 profile 的
`cacheNamespace/formats/decoders` 以及各平台资产的 SHA-256；生成与校验见
[lockfile.md](lockfile.md) 和 `script/verify-lockfile.mjs`。

Apple 发布两类制品：`OrzAudioCore-<version>-apple-builtin-lite.xcframework.zip` 是 iOS device/simulator
可直接使用的 dependency-free `builtin-lite` profile；
`OrzAudioCore-<version>-apple-full.xcframework.zip` 是含全部 decoder 的
iOS device/simulator + macOS arm64 静态 XCFramework，带 modulemap、manifest、
build-info、SBOM、licenses 和 checksum，并附生成的 SwiftPM binaryTarget
`Package.swift`。完整构建流程见 [apple.md](apple.md)。

## 发布规则

- ABI 破坏性修改：major。
- 新格式、能力或向后兼容字段：minor。
- decoder 修复：patch。
- 每次发布必须附 decoder manifest、build-info、第三方许可证、checksum、
  ABI consumer 结果和逐格式 PCM conformance 报告；`verify-release.mjs` 是发布门禁。
- `package-sdk.sh` 会生成安装树、manifest、license、CycloneDX SBOM、tarball 和 SHA-256 checksum，作为后续 release job 的唯一输入。
- Apple release job 必须以 `--strict` 构建第三方库并通过 full macOS C consumer；任何 decoder archive 缺失都会阻止发布。
- `check-release-readiness.mjs` 必须在 CI 与 tag release 中通过；带 `-` 的版本发布为 prerelease，稳定语义版本自动发布为 latest release。
- OrzMusic 固定依赖 SDK 版本；升级后旧缓存因 fingerprint 变化自动失效，可通过依赖版本直接回滚。
