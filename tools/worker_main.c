/* qwen3-tts-worker — long-lived JSONL control + binary PCM (stage A).
 * Maintainer-built into release tarball. Users get it via Samantha ensure.
 *
 * Protocol (v1 draft):
 *   stdin  JSON lines: {"type":"synthesize","id":"...","text":"...","preset":"Vivian"|null,"ref_wav":null}
 *                       {"type":"cancel","id":"..."}
 *                       {"type":"shutdown"}
 *   stdout JSON lines: {"type":"ready",...}
 *                      {"type":"generating","id":"...","tokens":n,"max":m}  (optional)
 *                      {"type":"pcm_meta","id":"...","sample_rate":24000,"format":"f32le","n_samples":N}
 *                      then raw f32le mono PCM bytes (exactly N*4 bytes)
 *                      {"type":"final","id":"..."}
 *                      {"type":"error","id":"...","message":"..."}
 *
 * Stage A: one pcm blob after full synth (protocol + warm load).
 * Stage B: multiple pcm chunks mid-synth (engine patch).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "qwen3tts_c_api.h"

/* Minimal JSON field extractors (no external deps). */
static int json_get_string(const char *line, const char *key, char *out, size_t out_sz) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(line, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < out_sz) out[i++] = *p++;
    out[i] = 0;
    return 1;
}

static void emit_ready(void) {
    printf("{\"type\":\"ready\",\"protocol\":\"qwen3-tts-worker/v1\",\"sample_rate\":24000,"
           "\"pcm_format\":\"f32le\",\"streaming\":false,"
           "\"note\":\"stage_A_whole_utterance_pcm_after_synth\"}\n");
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <model_dir>\n", argv[0]);
        return 2;
    }
    const char *model_dir = argv[1];
    Qwen3Tts *tts = qwen3_tts_create(model_dir, 4);
    if (!tts || !qwen3_tts_is_loaded(tts)) {
        fprintf(stderr, "load failed: %s\n", tts ? qwen3_tts_get_error(tts) : "null");
        return 1;
    }
    emit_ready();

    char line[65536];
    while (fgets(line, sizeof(line), stdin)) {
        if (strstr(line, "\"shutdown\"")) break;
        if (strstr(line, "\"cancel\"")) {
            /* Stage A: cancel only between requests */
            continue;
        }
        if (!strstr(line, "\"synthesize\"")) continue;

        char id[128] = {0}, text[8192] = {0}, preset[64] = {0}, ref[1024] = {0};
        json_get_string(line, "id", id, sizeof(id));
        json_get_string(line, "text", text, sizeof(text));
        json_get_string(line, "preset", preset, sizeof(preset));
        json_get_string(line, "ref_wav", ref, sizeof(ref));
        if (!text[0]) {
            printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"missing text\"}\n", id);
            fflush(stdout);
            continue;
        }

        Qwen3TtsParams params;
        qwen3_tts_default_params(&params);
        Qwen3TtsAudio *audio = NULL;

        if (ref[0]) {
            audio = qwen3_tts_synthesize_with_voice_file(tts, text, ref, &params);
        } else if (preset[0]) {
            /* Load baked preset: model_dir/presets/Name.q3te */
            char path[1200];
            snprintf(path, sizeof(path), "%s/presets/%s.q3te", model_dir, preset);
            FILE *f = fopen(path, "rb");
            if (!f) {
                printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"preset not found\"}\n", id);
                fflush(stdout);
                continue;
            }
            char magic[4];
            uint32_t ver, nf, sr;
            if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "Q3TE", 4) != 0 ||
                fread(&ver, 4, 1, f) != 1 || fread(&nf, 4, 1, f) != 1 || fread(&sr, 4, 1, f) != 1 ||
                nf == 0 || nf > 4096) {
                fclose(f);
                printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"bad preset file\"}\n", id);
                fflush(stdout);
                continue;
            }
            float *emb = (float *)malloc(sizeof(float) * nf);
            if (!emb || fread(emb, sizeof(float), nf, f) != nf) {
                free(emb);
                fclose(f);
                printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"preset read failed\"}\n", id);
                fflush(stdout);
                continue;
            }
            fclose(f);
            audio = qwen3_tts_synthesize_with_embedding(tts, text, emb, (int32_t)nf, &params);
            free(emb);
        } else {
            audio = qwen3_tts_synthesize(tts, text, &params);
        }

        if (!audio || !audio->samples || audio->n_samples <= 0) {
            printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"%s\"}\n",
                   id, qwen3_tts_get_error(tts));
            fflush(stdout);
            if (audio) qwen3_tts_free_audio(audio);
            continue;
        }

        printf("{\"type\":\"pcm_meta\",\"id\":\"%s\",\"sample_rate\":%d,\"format\":\"f32le\",\"n_samples\":%d}\n",
               id, audio->sample_rate, audio->n_samples);
        fflush(stdout);
        fwrite(audio->samples, sizeof(float), (size_t)audio->n_samples, stdout);
        fflush(stdout);
        printf("\n{\"type\":\"final\",\"id\":\"%s\"}\n", id);
        fflush(stdout);
        qwen3_tts_free_audio(audio);
    }

    qwen3_tts_destroy(tts);
    return 0;
}
