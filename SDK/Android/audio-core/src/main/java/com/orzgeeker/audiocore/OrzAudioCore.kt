package com.orzgeeker.audiocore

import android.util.Log
import org.json.JSONObject
import java.io.Closeable
import java.io.File

/** Decoder stream information, aligned with Swift's `DecoderStreamInfo`. */
data class DecoderStreamInfo(
    val sampleRate: Int,
    val channels: Int,
    val durationMs: Long,
    val subsongCount: Int,
    val capabilities: Int
) {
    val durationSeconds: Double get() = durationMs / 1000.0
}

/** Formats compiled into the current profile, generated from decoder-manifest.json. */
data class DecoderFormatInfo(
    val id: String,
    val displayName: String,
    val decoderID: String,
    val decoderVersion: String,
    val category: String,
    val seek: Boolean,
    val subsong: Boolean
) {
    val capabilities: Int
        get() = (if (seek) 1 shl 2 else 0) or (if (subsong) 1 shl 3 else 0)
}

data class ProbeResult(val format: String, val confidence: Int)

data class DecoderDependency(val id: String, val version: String)

/** Parsed `orz_build_info()` JSON. */
data class DecoderBuildInfo(
    val sdk: String,
    val version: String,
    val abi: String,
    val profile: String,
    val fingerprint: String,
    val cacheNamespace: String,
    val formats: List<String>,
    val decoders: List<DecoderDependency>
)

class OrzAudioCoreException(
    val status: Int,
    message: String
) : Exception("$message (status=$status)")

/**
 * Android entry point for the OrzAudioCore SDK.
 *
 * Lifecycle and threading match the Swift binding:
 *   OrzAudioCore.createDecoder(data, format, subsong) -> AudioDecoder
 *   decoder.renderF32(buffer, frames) / seekMs / selectSubsong / cancel / close
 *
 * It deliberately does not implement files, WAV, HTTP, caches or playback
 * policy; those belong to the consuming application.
 */
object OrzAudioCore {

    private const val TAG = "OrzAudioCore"

    private val loadResult: Result<Unit> = runCatching {
        System.loadLibrary("orzaudio")
    }.onFailure {
        Log.w(TAG, "liborzaudio.so is unavailable: ${it.message}")
    }

    val isAvailable: Boolean get() = loadResult.isSuccess

    /** Raw `orz_abi_version()`: `(major shl 16) or minor`. */
    val abiVersion: Int
        get() = if (isAvailable) runCatching { nativeAbiVersion() }.getOrDefault(0) else 0

    val abiVersionMajor: Int get() = abiVersion ushr 16
    val abiVersionMinor: Int get() = abiVersion and 0xffff

    fun buildInfo(): String? =
        if (isAvailable) runCatching { nativeBuildInfo() }.getOrNull() else null

    /**
     * Runtime build information, including profile, formats, decoder versions
     * and the cache namespace. Returns null when the native library is absent.
     */
    val buildInfoObject: DecoderBuildInfo? by lazy {
        val json = buildInfo() ?: return@lazy null
        runCatching {
            val object0 = JSONObject(json)
            val decoders = object0.optJSONArray("decoders")?.let { entries ->
                (0 until entries.length()).mapNotNull { index ->
                    val entry = entries.optJSONObject(index) ?: return@mapNotNull null
                    DecoderDependency(entry.optString("id"), entry.optString("version"))
                }
            }.orEmpty()
            val formats = object0.optJSONArray("formats")?.let { entries ->
                (0 until entries.length()).mapNotNull { index -> entries.optString(index) }
            }.orEmpty()
            val fingerprint = object0.optString("fingerprint", "orzcore-abi-$abiVersion")
            DecoderBuildInfo(
                sdk = object0.optString("sdk", "OrzAudioCore"),
                version = object0.optString("version", "unknown"),
                abi = object0.optString("abi", "unknown"),
                profile = object0.optString("profile", "unknown"),
                fingerprint = fingerprint,
                cacheNamespace = object0.optString("cacheNamespace", fingerprint),
                formats = formats,
                decoders = decoders
            )
        }.getOrNull()
    }

    /** Profile compiled into this binary (`builtin-lite`, `full` or `server`). */
    val profile: String? get() = buildInfoObject?.profile

    /** Cache namespace for PCM/WAV cache keys; changes when the decoder set changes. */
    val cacheNamespace: String
        get() = buildInfoObject?.cacheNamespace ?: "orzcore-abi-$abiVersionMajor.$abiVersionMinor"

    /** Backwards-compatible alias for [cacheNamespace]. */
    val cacheFingerprint: String get() = cacheNamespace

    /**
     * Format ids that this binary really implements.
     *
     * The generated manifest describes what the SDK version offers; this set
     * is the runtime truth. The intersection is the usable capability.
     */
    val nativeFormats: Set<String> by lazy {
        if (!isAvailable) return@lazy emptySet<String>()
        val probed = runCatching {
            nativeFormatIds()?.filterNotNull()?.map { it.lowercase() }?.toSet()
        }.getOrNull()
        if (probed.isNullOrEmpty()) DecoderManifest.supportedIds else probed
    }

    /** Generated manifest filtered by the runtime binary. */
    val supportedFormats: List<DecoderFormatInfo>
        get() = DecoderManifest.formats.filter { it.id in nativeFormats }

    fun supports(format: String): Boolean = format.lowercase() in nativeFormats

    fun probe(data: ByteArray, extensionHint: String? = null): ProbeResult? {
        if (!isAvailable || data.size < 32) return null
        val format = runCatching { nativeProbe(data, extensionHint) }.getOrNull() ?: return null
        return ProbeResult(format, 100)
    }

    /**
     * Create a decoder. The caller owns the returned [AudioDecoder] and must
     * call [AudioDecoder.close].
     *
     * @param subsong 0 selects the default tune; >0 calls the C ABI's
     *                select_subsong.
     */
    fun createDecoder(data: ByteArray, format: String, subsong: Int = 0): AudioDecoder {
        if (!isAvailable) throw OrzAudioCoreException(-7, "liborzaudio.so is unavailable")
        if (data.size < 32) throw OrzAudioCoreException(-1, "input is too small")
        val handle = nativeCreateDecoder(data, format.lowercase(), subsong)
        if (handle == 0L) {
            throw OrzAudioCoreException(-4, "cannot create $format decoder (unsupported or corrupt)")
        }
        return AudioDecoder(handle)
    }

    /**
     * Decode-to-WAV convenience for scripts and one-shot exports. Do not use
     * it on a playback path; [PcmStream] is the streaming API.
     */
    fun decodeToWav(input: File, output: File, format: String, subsong: Int = 0): WavInfo {
        if (!input.isFile || input.length() < 32L) {
            throw IllegalArgumentException("input missing or too small: ${input.absolutePath}")
        }
        val data = input.readBytes()
        output.parentFile?.mkdirs()
        return try {
            createDecoder(data, format, subsong).use { decoder -> WavFile.write(decoder, output) }
        } catch (t: Throwable) {
            output.delete()
            throw t
        }
    }

    // JNI implementation: audio-core/src/main/cpp/orz_jni.c
    external fun nativeCreateDecoder(data: ByteArray, format: String, subsong: Int): Long
    external fun nativeStreamInfo(handle: Long): LongArray?
    external fun nativeRenderF32(handle: Long, out: FloatArray, frames: Int): Int
    external fun nativeSeek(handle: Long, positionMs: Long): Int
    external fun nativeSelectSubsong(handle: Long, subsong: Int): Int
    external fun nativeCancel(handle: Long): Int
    external fun nativeDestroy(handle: Long)
    external fun nativeProbe(data: ByteArray, extensionHint: String?): String?
    external fun nativeFormatIds(): Array<String?>?
    external fun nativeAbiVersion(): Int
    external fun nativeBuildInfo(): String
}

/**
 * One decoder handle. Calls on the same instance must be serialized; separate
 * instances can render concurrently. Aligned with Swift's `AudioDecoder`.
 */
class AudioDecoder internal constructor(private var handle: Long) : Closeable {

    val info: DecoderStreamInfo = run {
        val values = OrzAudioCore.nativeStreamInfo(handle)
            ?: run {
                OrzAudioCore.nativeDestroy(handle)
                handle = 0L
                throw OrzAudioCoreException(-7, "cannot read decoder stream info")
            }
        DecoderStreamInfo(
            sampleRate = values[0].toInt(),
            channels = values[1].toInt(),
            durationMs = values[2],
            subsongCount = values[3].toInt(),
            capabilities = values[4].toInt()
        )
    }

    val isOpen: Boolean get() = handle != 0L

    /**
     * Render at most [frames] frames into [out] (interleaved float32).
     * Returns the rendered frame count; 0 means end of stream.
     */
    fun renderF32(out: FloatArray, frames: Int): Int {
        check(handle != 0L) { "decoder is closed" }
        if (frames <= 0) return 0
        val need = frames * info.channels.coerceAtLeast(1)
        require(out.size >= need) { "buffer too small: ${out.size} < $need" }
        val rendered = OrzAudioCore.nativeRenderF32(handle, out, frames)
        if (rendered < 0) throw OrzAudioCoreException(rendered, "render failed")
        return rendered
    }

    fun seekMs(positionMs: Long): Boolean {
        if (handle == 0L || positionMs < 0) return false
        return OrzAudioCore.nativeSeek(handle, positionMs) == 0
    }

    fun selectSubsong(index: Int): Boolean {
        if (handle == 0L || index < 0) return false
        return OrzAudioCore.nativeSelectSubsong(handle, index) == 0
    }

    /** Interrupt an in-flight [renderF32] from another thread. */
    fun cancel() {
        val current = handle
        if (current != 0L) OrzAudioCore.nativeCancel(current)
    }

    override fun close() {
        val current = handle
        if (current != 0L) {
            handle = 0L
            OrzAudioCore.nativeDestroy(current)
        }
    }
}
