# OrzAudioCore Android SDK

Official Kotlin/JNI binding for the OrzAudioCore `full` profile (23 formats).

## Consume the AAR

```kotlin
implementation("com.orzgeeker:audio-core-android:1.4.0")
```

The AAR contains `arm64-v8a`, `armeabi-v7a` and `x86_64` builds of
`liborzaudio.so` (JNI bridge + statically linked OrzAudioCore and decoders),
consumer ProGuard rules and `assets/orz/{metadata,licenses}`. Consumers do not
need the NDK.

```kotlin
val decoder = OrzAudioCore.createDecoder(bytes, "mod")
decoder.use {
    it.info.sampleRate / channels / durationMs
    val pcm = FloatArray(4096 * it.info.channels)
    val frames = it.renderF32(pcm, 4096)
    it.seekMs(30_000)
    it.selectSubsong(1)
    it.cancel()
}
```

`OrzAudioCore.buildInfoObject` exposes `profile`, `formats`, `decoders` and
`cacheNamespace`; `supportedFormats` intersects the generated manifest with the
runtime binary. `PcmStream` is the streaming API for `AudioTrack`; `decodeToWav`
is a one-shot convenience only.

## Build the AAR (maintainers)

```bash
export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/28.1.13356709
export ANDROID_HOME=$HOME/Library/Android/sdk
./script/build-android-aar.sh          # all ABIs
./script/build-android-aar.sh --abi arm64-v8a
```

The script runs `build-android.sh`, packages the merged static core, builds the
JNI bridge per ABI, checks that only `Java_com_orzgeeker_audiocore_OrzAudioCore_*`
symbols are exported, then runs Gradle `assembleRelease` and
`publishReleasePublicationToLocalRepository`. The AAR is copied to
`.cmake-build/release/OrzAudioCore-<ver>-android-full.aar` with a SHA-256
sidecar. Requires JDK 17 and Gradle wrapper network access.

## Licenses

The full AAR statically links GPL-family decoders and is distributed as
GPL-3.0-or-later. See `assets/orz/licenses/README.md` inside the AAR and
[Docs/licensing.md](../../Docs/licensing.md).
