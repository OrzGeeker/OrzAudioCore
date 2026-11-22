/**
 * adplug_wrap.cpp — AdPlug OPL2/3 decoder C++ wrapper for WASM
 *
 * Formats: rad, d00, hsc (+ 20+ more OPL2/3 formats)
 * Uses: CEmuopl (emulated OPL2), CAdPlug factory pattern
 * File access: AdPlug CFileProvider 直接从内存读（不落盘）
 */
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <atomic>

#include <adplug.h>
#include <emuopl.h>
#include <binstr.h>   // binisstream:直接读内存,不落盘

// Forward declarations (defined in adplug_impl.c)
extern "C" void adplug_destroy();
extern "C" int adplug_load(const unsigned char *data, int len);
extern "C" double adplug_get_duration();
extern "C" int adplug_get_sample_rate();
extern "C" int adplug_get_channels();
extern "C" int adplug_render(float *out, int frames);
extern "C" {
#include "audio_engine.h"
}

// 由 orz_dispatch.c 设置的当前格式名（如 "hsc", "amd", "rad"）
extern const char *orz_current_format;

// ── State ──
struct AdPlugContext {
    CEmuopl *opl = NULL;
    CPlayer *player = NULL;
    int sample_rate = 44100;
    double song_duration = 0;
    int samples_remaining_in_tick = 0;
    double fractional_tick_samples = 0.0;
    bool playback_ended = false;
};

/**
 * 直接从内存把字节喂给 AdPlug。
 *
 * 以前这里是「把数据写进 /tmp，再用 CProvider_Filesystem 读回来」。在 WASM 里
 * /tmp 是 Emscripten 的 MEMFS，能用；但 **Android 上根本没有 /tmp**，
 * fopen 直接失败 → `amd`/`d00`/`hsc`/`rad` 四个 adplug 格式在真机上全部
 * 「无法创建解码器(格式不支持或数据损坏)」。改成内存 provider 后三条平台一致。
 */
class COrzMemoryProvider : public CFileProvider {
public:
    COrzMemoryProvider(const unsigned char *data, int len)
        : data_(data), len_(len) {}

    binistream *open(std::string) const override {
        return new binisstream((void *)data_, (unsigned long)len_);
    }
    void close(binistream *f) const override { delete f; }

private:
    const unsigned char *data_;
    int len_;
};

// 假文件名计数（扩展名提示用）
// 扩展名根据 orz_current_format 设置（"hsc"→".hsc" 等），使 AdPlug factory
// 的扩展名匹配机制正确识别格式。程序化编译为 ".adplug" 走全 player 遍历。
static std::atomic<unsigned int> tmp_counter{0};

extern "C" void adplug_context_destroy(void *opaque);
extern "C" void *adplug_context_create(const char *format, const unsigned char *data, int len)
{
    if (!data || len <= 0) return NULL;
    AdPlugContext *ctx = new(std::nothrow) AdPlugContext();
    if (!ctx) return NULL;

    // 根据当前格式名确定「假文件名」的扩展名（AdPlug 用它做 player 匹配）
    const char *ext = ".adplug";
    if (format) {
        if (strcmp(format, "hsc") == 0) ext = ".hsc";
        else if (strcmp(format, "amd") == 0) ext = ".amd";
        else if (strcmp(format, "rad") == 0) ext = ".rad";
        else if (strcmp(format, "d00") == 0) ext = ".d00";
        else if (strcmp(format, "hsp") == 0) ext = ".hsp";
    }

    // Create OPL emulator: 44100Hz, 16-bit, stereo
    ctx->opl = new(std::nothrow) CEmuopl(ctx->sample_rate, true, true);
    if (!ctx->opl) { delete ctx; return NULL; }
    ctx->opl->init();

    // 用扩展名做 player 匹配提示，内容从内存读（不落盘，Android 上也成立）
    char hint_name[64];
    snprintf(hint_name, sizeof(hint_name), "mem_%u%s", tmp_counter.fetch_add(1) + 1, ext);
    COrzMemoryProvider provider(data, len);
    ctx->player = CAdPlug::factory(std::string(hint_name), ctx->opl, CAdPlug::players, provider);
    if (!ctx->player) {
        adplug_context_destroy(ctx); return NULL;
    }

    // Get duration
    ctx->song_duration = ctx->player->songlength() / 1000.0;
    if (ctx->song_duration <= 0) ctx->song_duration = 120.0;

    return ctx;
}

extern "C" double adplug_context_get_duration(void *opaque) { return opaque ? ((AdPlugContext *)opaque)->song_duration : 0; }
extern "C" int adplug_context_get_sample_rate(void *opaque) { return opaque ? ((AdPlugContext *)opaque)->sample_rate : 0; }
extern "C" int adplug_context_get_channels(void *opaque) { return opaque ? 2 : 0; }

extern "C" int adplug_context_render(void *opaque, float *out, int frames)
{
    AdPlugContext *ctx = (AdPlugContext *)opaque;
    if (!ctx || !ctx->player || !ctx->opl || ctx->playback_ended) return 0;

    // AdPlug render loop:
    // player->update() = advance one tick, writes OPL registers
    // emuopl->update(buf, samples) = render OPL output to buffer
    //
    int total = 0;
    while (total < frames) {
        if (ctx->samples_remaining_in_tick <= 0) {
            if (!ctx->player->update()) {
                ctx->playback_ended = true;
                break;
            }

            float refresh = ctx->player->getrefresh();
            if (refresh <= 0.0f) refresh = 50.0f;
            double exact_samples =
                (double)ctx->sample_rate / refresh + ctx->fractional_tick_samples;
            ctx->samples_remaining_in_tick = (int)exact_samples;
            ctx->fractional_tick_samples = exact_samples - ctx->samples_remaining_in_tick;
            if (ctx->samples_remaining_in_tick < 1) ctx->samples_remaining_in_tick = 1;
        }

        int chunk = frames - total;
        if (chunk > ctx->samples_remaining_in_tick) {
            chunk = ctx->samples_remaining_in_tick;
        }

        // Render OPL audio directly to output
        short mixbuf[8192];
        int mix_samples = (chunk > 4096) ? 4096 : chunk;

        ctx->opl->update(mixbuf, mix_samples);

        // short → float
        for (int i = 0; i < mix_samples * 2; i++) {
            out[total * 2 + i] = mixbuf[i] / 32768.0f;
        }
        total += mix_samples;
        ctx->samples_remaining_in_tick -= mix_samples;
    }

    return total;
}

extern "C" void adplug_context_destroy(void *opaque)
{
    AdPlugContext *ctx = (AdPlugContext *)opaque;
    if (!ctx) return;
    delete ctx->player;
    delete ctx->opl;
    delete ctx;
}

static AdPlugContext *legacy;
extern "C" int adplug_load(const unsigned char *data, int len) { adplug_context_destroy(legacy); legacy = (AdPlugContext *)adplug_context_create(orz_current_format, data, len); return legacy != NULL; }
extern "C" double adplug_get_duration() { return adplug_context_get_duration(legacy); }
extern "C" int adplug_get_sample_rate() { return adplug_context_get_sample_rate(legacy); }
extern "C" int adplug_get_channels() { return adplug_context_get_channels(legacy); }
extern "C" int adplug_render(float *out, int frames) { return adplug_context_render(legacy, out, frames); }
extern "C" void adplug_destroy() { adplug_context_destroy(legacy); legacy = NULL; }
