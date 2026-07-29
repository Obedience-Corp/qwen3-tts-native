/* extract_embedding.c — maintainer tool: WAV → float32 embedding blob for preset/cache packaging.
 * Users never run this; Samantha ensure ships baked presets.
 *
 * Build (from repo root, after engine build):
 *   cc -O2 -o build/extract_embedding tools/extract_embedding.c \
 *     -I third_party/qwen3-tts.cpp/src \
 *     -L third_party/qwen3-tts.cpp/build -lqwen3tts \
 *     -Wl,-rpath,@loader_path
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "qwen3tts_c_api.h"

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <model_dir> <reference.wav> <out.embedding>\n", argv[0]);
        fprintf(stderr, "Writes little-endian float32 embedding (typically 1024 floats).\n");
        return 2;
    }
    const char *model_dir = argv[1];
    const char *wav = argv[2];
    const char *out_path = argv[3];

    Qwen3Tts *tts = qwen3_tts_create(model_dir, 4);
    if (!tts) {
        fprintf(stderr, "qwen3_tts_create failed\n");
        return 1;
    }
    if (!qwen3_tts_is_loaded(tts)) {
        fprintf(stderr, "models not loaded: %s\n", qwen3_tts_get_error(tts));
        qwen3_tts_destroy(tts);
        return 1;
    }

    float emb[2048];
    int32_t n = qwen3_tts_extract_embedding_file(tts, wav, emb, 2048);
    if (n <= 0) {
        fprintf(stderr, "extract failed: %s\n", qwen3_tts_get_error(tts));
        qwen3_tts_destroy(tts);
        return 1;
    }

    FILE *f = fopen(out_path, "wb");
    if (!f) {
        perror(out_path);
        qwen3_tts_destroy(tts);
        return 1;
    }
    /* header: magic "Q3TE", version=1, n_floats, sample_rate placeholder 0 */
    fwrite("Q3TE", 1, 4, f);
    uint32_t ver = 1, nf = (uint32_t)n, sr = 0;
    fwrite(&ver, 4, 1, f);
    fwrite(&nf, 4, 1, f);
    fwrite(&sr, 4, 1, f);
    fwrite(emb, sizeof(float), (size_t)n, f);
    fclose(f);

    printf("wrote %s (%d floats)\n", out_path, n);
    qwen3_tts_destroy(tts);
    return 0;
}
