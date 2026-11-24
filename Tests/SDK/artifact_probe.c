#include <stdio.h>
#include <string.h>
#include "orz_audio_core.h"

/*
 * Prints the runtime truth of an OrzAudioCore binary as JSON. Release
 * verification compares this with metadata/build-info.json and
 * metadata/decoder-manifest.json, so a package cannot claim formats that the
 * binary does not implement.
 *
 * Usage:
 *   orz_artifact_probe            -> pretty JSON report
 *   orz_artifact_probe --self-check -> exit 0 only if build info is complete
 */
static void print_json_string(const char *value) {
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)(value ? value : "");
         *cursor; ++cursor) {
        switch (*cursor) {
            case '"': fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            default:
                if (*cursor < 0x20) printf("\\u%04x", *cursor);
                else putchar(*cursor);
        }
    }
    putchar('"');
}

int main(int argc, char **argv) {
    const char *build_info = orz_build_info();
    int self_check = argc > 1 && strcmp(argv[1], "--self-check") == 0;

    if (self_check) {
        if (!build_info || !strstr(build_info, "\"profile\"")) {
            fprintf(stderr, "build info is missing the profile field\n");
            return 1;
        }
        if (!strstr(build_info, "\"cacheNamespace\"")) {
            fprintf(stderr, "build info is missing the cacheNamespace field\n");
            return 1;
        }
        if (orz_get_format_count() == 0) {
            fprintf(stderr, "binary exposes no formats\n");
            return 1;
        }
        return 0;
    }

    printf("{\n  \"buildInfo\": %s,\n  \"formatCount\": %u,\n  \"formats\": [",
           build_info, orz_get_format_count());
    for (uint32_t index = 0; index < orz_get_format_count(); ++index) {
        orz_format_info info;
        memset(&info, 0, sizeof(info));
        info.struct_size = (uint32_t)sizeof(info);
        info.abi_version = orz_abi_version();
        if (orz_get_format_info(index, &info) != ORZ_OK) continue;
        if (index) fputs(",", stdout);
        fputs("\n    {\"id\": ", stdout);
        print_json_string(info.format_id);
        fputs(", \"decoder\": ", stdout);
        print_json_string(info.decoder_id);
        fputs(", \"version\": ", stdout);
        print_json_string(info.decoder_version);
        fputs(", \"category\": ", stdout);
        print_json_string(info.category);
        printf(", \"capabilities\": %u}", info.capabilities);
    }
    fputs("\n  ]\n}\n", stdout);
    return 0;
}
