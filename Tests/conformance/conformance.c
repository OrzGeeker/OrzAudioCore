/*
 * OrzAudioCore conformance probe.
 *
 * Emits a deterministic JSON report for one fixture: probe result, stream
 * info, first frames (float hash and int16 hash), seek result, subsong results
 * and cancel behaviour. script/run-conformance.mjs collects one report per
 * format/platform and script/compare-conformance.mjs enforces cross-run
 * tolerance.
 */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "orz_audio_core.h"

/* ── Minimal SHA-256 (public-domain style implementation) ── */
typedef struct {
    uint32_t state[8];
    uint64_t bytes;
    uint8_t buffer[64];
} Sha256;

static const uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha256_block(Sha256 *ctx, const uint8_t *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h;
    for (int i = 0; i < 16; ++i)
        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
               ((uint32_t)p[i * 4 + 2] << 8) | p[i * 4 + 3];
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
    for (int i = 0; i < 64; ++i) {
        uint32_t s1 = ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + s1 + ch + K[i] + w[i];
        uint32_t s0 = ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + maj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init(Sha256 *ctx) {
    static const uint32_t initial[8] = {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    memcpy(ctx->state, initial, sizeof(initial));
    ctx->bytes = 0;
}

static void sha256_update(Sha256 *ctx, const void *data, size_t size) {
    const uint8_t *p = (const uint8_t *)data;
    size_t used = (size_t)(ctx->bytes % 64);
    ctx->bytes += size;
    if (used) {
        size_t take = 64 - used;
        if (take > size) take = size;
        memcpy(ctx->buffer + used, p, take);
        p += take; size -= take;
        if (used + take == 64) sha256_block(ctx, ctx->buffer);
    }
    while (size >= 64) { sha256_block(ctx, p); p += 64; size -= 64; }
    if (size) memcpy(ctx->buffer, p, size);
}

static void sha256_hex(Sha256 *ctx, char out[65]) {
    uint64_t bits = ctx->bytes * 8;
    size_t used = (size_t)(ctx->bytes % 64);
    uint8_t pad[72] = {0x80};
    size_t padlen = (used < 56) ? (56 - used) : (120 - used);
    for (int i = 0; i < 8; ++i) pad[padlen + i] = (uint8_t)(bits >> (56 - i * 8));
    sha256_update(ctx, pad, padlen + 8);
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; ++i) {
        uint8_t byte = (uint8_t)(ctx->state[i / 4] >> (24 - (i % 4) * 8));
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 15];
    }
    out[64] = 0;
}

static void json_string(const char *value) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 0x20) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (!file) { fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno)); return NULL; }
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    rewind(file);
    if (length <= 0) { fclose(file); return NULL; }
    uint8_t *data = (uint8_t *)malloc((size_t)length);
    if (!data) { fclose(file); return NULL; }
    if (fread(data, 1, (size_t)length, file) != (size_t)length) { free(data); fclose(file); return NULL; }
    fclose(file);
    *size = (size_t)length;
    return data;
}

typedef struct {
    Sha256 float_hash;
    Sha256 int16_hash;
    uint64_t frames;
    double max_abs;
    float first[16];
    float last[16];
    size_t first_count;
    size_t last_count;
    float checkpoints[8][4];
    size_t checkpoint_count;
} PcmSummary;

static void pcm_init(PcmSummary *summary) {
    memset(summary, 0, sizeof(*summary));
    sha256_init(&summary->float_hash);
    sha256_init(&summary->int16_hash);
}

static void pcm_append(PcmSummary *summary, const float *pcm, uint32_t frames, uint32_t channels) {
    // Sampled checkpoints let the cross-platform comparator measure float
    // drift without shipping the whole PCM stream in the JSON report.
    if (summary->checkpoint_count < 8 && summary->frames % 4096u == 0u) {
        size_t count = (size_t)frames * channels;
        if (count > 4) count = 4;
        for (size_t index = 0; index < count; ++index)
            summary->checkpoints[summary->checkpoint_count][index] = pcm[index];
        summary->checkpoint_count++;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            float value = pcm[frame * channels + channel];
            if (!isfinite(value)) value = 0.0f;
            double magnitude = fabs((double)value);
            if (magnitude > summary->max_abs) summary->max_abs = magnitude;
            if (summary->first_count < 16) summary->first[summary->first_count++] = value;
            if (summary->last_count < 16) summary->last[summary->last_count++] = value;
            else {
                memmove(summary->last, summary->last + 1, sizeof(summary->last) - sizeof(float));
                summary->last[15] = value;
            }
        }
    }
    sha256_update(&summary->float_hash, pcm, (size_t)frames * channels * sizeof(float));
    for (uint32_t index = 0; index < frames * channels; ++index) {
        float value = pcm[index];
        if (!isfinite(value)) value = 0.0f;
        if (value > 1.0f) value = 1.0f;
        if (value < -1.0f) value = -1.0f;
        int16_t sample = (int16_t)lrintf(value * 32767.0f);
        sha256_update(&summary->int16_hash, &sample, sizeof(sample));
    }
    summary->frames += frames;
}

static void pcm_body(const PcmSummary *summary) {
    char float_hex[65], int16_hex[65];
    Sha256 float_copy = summary->float_hash, int16_copy = summary->int16_hash;
    sha256_hex(&float_copy, float_hex);
    sha256_hex(&int16_copy, int16_hex);
    printf("{\"frames\": %llu, \"floatSha256\": ", (unsigned long long)summary->frames);
    json_string(float_hex);
    printf(", \"int16Sha256\": ");
    json_string(int16_hex);
    printf(", \"maxAbs\": %.9f, \"first\": [", summary->max_abs);
    for (size_t i = 0; i < summary->first_count; ++i) printf("%s%.9g", i ? ", " : "", summary->first[i]);
    printf("], \"last\": [");
    for (size_t i = 0; i < summary->last_count; ++i) printf("%s%.9g", i ? ", " : "", summary->last[i]);
    printf("], \"checkpoints\": [");
    for (size_t c = 0; c < summary->checkpoint_count; ++c) {
        printf("%s[", c ? ", " : "");
        for (size_t i = 0; i < 4; ++i) printf("%s%.9g", i ? ", " : "", summary->checkpoints[c][i]);
        printf("]");
    }
    printf("]}");
}

static orz_status create_decoder(const uint8_t *data, size_t size, const char *format,
                                 uint32_t subsong, OrzDecoderHandle **handle) {
    orz_decoder_config config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.abi_version = ORZ_ABI_VERSION;
    config.subsong = subsong;
    return orz_decoder_create_memory(data, size, format, &config, handle);
}

static int render_summary(OrzDecoderHandle *decoder, uint32_t channels, uint64_t max_frames,
                          PcmSummary *summary) {
    const uint32_t chunk = 2048;
    float *pcm = (float *)malloc((size_t)chunk * channels * sizeof(float));
    if (!pcm) return -1;
    pcm_init(summary);
    uint64_t remaining = max_frames;
    while (remaining > 0) {
        uint32_t request = remaining < chunk ? (uint32_t)remaining : chunk;
        uint32_t rendered = 0;
        orz_status status = orz_decoder_render_f32(decoder, pcm, request, &rendered);
        if (status == ORZ_END_OF_STREAM) break;
        if (status != ORZ_OK) { free(pcm); return (int)status; }
        if (rendered == 0) break;
        pcm_append(summary, pcm, rendered, channels);
        remaining -= rendered;
    }
    free(pcm);
    return 0;
}

int main(int argc, char **argv) {
    const char *format = NULL, *input = NULL;
    uint64_t frames = 8192, seek_ms = 0;
    uint32_t subsong = 0;
    int max_seconds = 30;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--format") && i + 1 < argc) format = argv[++i];
        else if (!strcmp(argv[i], "--input") && i + 1 < argc) input = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--seek-ms") && i + 1 < argc) seek_ms = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--subsong") && i + 1 < argc) subsong = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) max_seconds = atoi(argv[++i]);
        else { fprintf(stderr, "unknown argument: %s\n", argv[i]); return 2; }
    }
    if (!format || !input) { fprintf(stderr, "usage: --format <id> --input <file>\n"); return 2; }

    size_t size = 0;
    uint8_t *data = read_file(input, &size);
    if (!data) return 2;

    printf("{\n  \"format\": ");
    json_string(format);
    printf(",\n  \"input\": {\"name\": ");
    json_string(input);
    printf(", \"bytes\": %zu}", size);

    orz_probe_result probe;
    memset(&probe, 0, sizeof(probe));
    probe.struct_size = (uint32_t)sizeof(probe);
    probe.abi_version = ORZ_ABI_VERSION;
    orz_status probe_status = orz_probe(data, size, format, &probe);
    printf(",\n  \"probe\": {\"status\": %d, \"format\": ", (int)probe_status);
    json_string(probe_status == ORZ_OK ? probe.format_id : NULL);
    printf(", \"confidence\": %u}", probe.confidence);

    OrzDecoderHandle *decoder = NULL;
    orz_status status = create_decoder(data, size, format, subsong, &decoder);
    if (status != ORZ_OK) {
        printf(",\n  \"error\": {\"status\": %d, \"message\": ", (int)status);
        json_string(orz_status_message(status));
        printf("}\n}\n");
        free(data);
        return 1;
    }

    orz_stream_info info;
    memset(&info, 0, sizeof(info));
    info.struct_size = (uint32_t)sizeof(info);
    info.abi_version = ORZ_ABI_VERSION;
    status = orz_decoder_get_stream_info(decoder, &info);
    printf(",\n  \"stream\": {\"status\": %d, \"sampleRate\": %u, \"channels\": %u, "
           "\"duration\": %.6f, \"subsongCount\": %u, \"capabilities\": %u}",
           (int)status, info.sample_rate, info.channels, info.duration_seconds,
           info.subsong_count, info.capabilities);

    uint32_t channels = info.channels ? info.channels : 1;
    uint64_t max_frames = frames;
    if (max_seconds > 0 && info.duration_seconds > 0.0) {
        uint64_t duration_frames = (uint64_t)(info.duration_seconds * info.sample_rate);
        uint64_t cap = (uint64_t)info.sample_rate * (uint64_t)max_seconds;
        if (duration_frames > 0 && duration_frames < max_frames) max_frames = duration_frames;
        if (cap > 0 && cap < max_frames) max_frames = cap;
    }

    PcmSummary summary;
    int render_status = render_summary(decoder, channels, max_frames, &summary);
    printf(",\n  \"pcm\": ");
    if (render_status == 0) pcm_body(&summary);
    else printf("{\"error\": %d}", render_status);

    /* Seek: use the decoder's native seek when advertised, otherwise report
       unsupported so the runner can mark it as an expected platform difference. */
    printf(",\n  \"seek\": ");
    if ((info.capabilities & ORZ_CAP_SEEK) && info.duration_seconds > 0.0) {
        uint64_t position = seek_ms ? seek_ms : (uint64_t)(info.duration_seconds * 500.0);
        orz_status seek_status = orz_decoder_seek(decoder, position);
        if (seek_status == ORZ_OK) {
            PcmSummary after;
            int seek_render = render_summary(decoder, channels, 1024, &after);
            printf("{\"status\": %d, \"positionMs\": %llu, \"pcm\": ", (int)seek_status, (unsigned long long)position);
            if (seek_render == 0) pcm_body(&after);
            else printf("{\"error\": %d}", seek_render);
            printf("}");
        } else {
            printf("{\"status\": %d, \"message\": ", (int)seek_status);
            json_string(orz_status_message(seek_status));
            printf("}");
        }
    } else {
        printf("{\"status\": -3, \"message\": \"format does not advertise seek\"}");
    }
    orz_decoder_destroy_v1(decoder);

    /* Subsongs: enumerate from separate handles so the main stream stays intact. */
    printf(",\n  \"subsongs\": [");
    uint32_t count = info.capabilities & ORZ_CAP_SUBSONG ? info.subsong_count : 0;
    if (count > 4) count = 4;
    for (uint32_t index = 1; index < count; ++index) {
        OrzDecoderHandle *sub = NULL;
        orz_status sub_status = create_decoder(data, size, format, index, &sub);
        if (index > 1) printf(",");
        printf("{\"index\": %u, \"status\": %d", index, (int)sub_status);
        if (sub_status == ORZ_OK) {
            orz_stream_info sub_info;
            memset(&sub_info, 0, sizeof(sub_info));
            sub_info.struct_size = (uint32_t)sizeof(sub_info);
            sub_info.abi_version = ORZ_ABI_VERSION;
            orz_decoder_get_stream_info(sub, &sub_info);
            PcmSummary sub_pcm;
            int sub_render = render_summary(sub, sub_info.channels ? sub_info.channels : 1, 1024, &sub_pcm);
            printf(", \"sampleRate\": %u, \"channels\": %u, \"duration\": %.6f",
                   sub_info.sample_rate, sub_info.channels, sub_info.duration_seconds);
            if (sub_render == 0) { printf(", \"pcm\": "); pcm_body(&sub_pcm); }
            orz_decoder_destroy_v1(sub);
        }
        printf("}");
    }
    printf("]");

    /* Lifecycle: repeated create/render/destroy must not leak or drift. */
    printf(",\n  \"lifecycle\": [");
    for (int cycle = 0; cycle < 4; ++cycle) {
        OrzDecoderHandle *instance = NULL;
        orz_status cycle_status = create_decoder(data, size, format, subsong, &instance);
        if (cycle_status == ORZ_OK) {
            float scratch[8] = {0};
            uint32_t rendered = 0;
            cycle_status = orz_decoder_render_f32(instance, scratch, 1, &rendered);
            orz_decoder_destroy_v1(instance);
        }
        printf("%s%d", cycle ? ", " : "", (int)cycle_status);
    }
    printf("]");

    /* Out-of-range seek is reported separately; platforms may clamp or reject. */
    {
        OrzDecoderHandle *seek_handle = NULL;
        orz_status seek_status = create_decoder(data, size, format, subsong, &seek_handle);
        if (seek_status == ORZ_OK) {
            uint64_t beyond = (uint64_t)(info.duration_seconds * 1000.0) + 60000u;
            seek_status = orz_decoder_seek(seek_handle, beyond);
            orz_decoder_destroy_v1(seek_handle);
        }
        printf(",\n  \"seekOutOfRange\": {\"status\": %d}", (int)seek_status);
    }

    /* Cancel semantics: a fresh handle must refuse to render after cancel. */
    OrzDecoderHandle *cancel = NULL;
    status = create_decoder(data, size, format, subsong, &cancel);
    printf(",\n  \"cancel\": ");
    if (status == ORZ_OK) {
        orz_decoder_cancel(cancel);
        float dummy[8] = {0};
        uint32_t rendered = 0;
        orz_status cancel_status = orz_decoder_render_f32(cancel, dummy, 1, &rendered);
        printf("{\"status\": %d, \"expected\": %d}", (int)cancel_status, (int)ORZ_ERROR_CANCELLED);
        orz_decoder_destroy_v1(cancel);
    } else {
        printf("{\"status\": %d}", (int)status);
    }

    printf(",\n  \"buildInfo\": ");
    json_string(orz_build_info());
    printf("\n}\n");
    free(data);
    return 0;
}
