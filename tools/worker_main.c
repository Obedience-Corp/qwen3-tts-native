/* qwen3-tts-worker — long-lived JSONL control + binary PCM.
 * Shipped in the release tarball; hosts install via qwen3-tts-ensure / pkg/install.
 *
 * Protocol (v1):
 *   stdin  JSON lines: {"type":"synthesize","id":"...","text":"...","preset":"Vivian"|null,"ref_wav":null,"stream":false}
 *                       {"type":"cancel","id":"..."}
 *                       {"type":"shutdown"}
 *   stdout JSON lines: {"type":"ready",...}
 *                      {"type":"generating","id":"...","tokens":n,"max":m}  (optional)
 *                      {"type":"pcm_meta","id":"...","sample_rate":24000,"format":"f32le","n_samples":N}
 *                      then raw f32le mono PCM bytes (exactly N*4 bytes)
 *                      {"type":"final","id":"..."}
 *                      {"type":"error","id":"...","message":"..."}
 *
 * Stage A (default): one pcm blob after full synth.
 * Stage B (opt-in):  "stream":true on the request — or QWEN3_TTS_STREAM=1 as the
 *                    process default — emits several pcm_meta+PCM chunks during
 *                    synthesis, each carrying "chunk":N, before final. Requires an
 *                    engine pin with qwen3_tts_set_pcm_callback (docs/ENGINE_PIN.txt);
 *                    without it the worker still builds and behaves as stage A.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "qwen3tts_c_api.h"

#ifdef QWEN3_TTS_HAS_PCM_STREAMING
#define WORKER_STREAM_CAPABLE 1
#else
#define WORKER_STREAM_CAPABLE 0
#endif

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

/* Read a JSON bool field. Returns 0 when the key is absent or not a bool. */
static int json_get_bool(const char *line, const char *key, int *out) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(line, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (strncmp(p, "true", 4) == 0) {
        *out = 1;
        return 1;
    }
    if (strncmp(p, "false", 5) == 0) {
        *out = 0;
        return 1;
    }
    return 0;
}

static int env_flag(const char *key) {
    const char *v = getenv(key);
    return v && v[0] && v[0] != '0';
}

/* Load a baked preset whose float count matches what the loaded model needs.
 * Presets are baked per tier (speaker-encoder width differs: 0.6b=1024,
 * 1.7b=2048), so candidates are checked by dimension, not trusted by path.
 * Returns malloc'd floats (caller frees) or NULL; *found_any reports whether
 * any candidate file existed so the error can distinguish missing vs
 * wrong-tier. */
static float *load_preset(const char *model_dir, const char *preset,
                          int32_t want, int *found_any) {
    static const char *dirs[] = {"presets", "presets-1.7b"};
    *found_any = 0;
    for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
        char path[1200];
        snprintf(path, sizeof(path), "%s/%s/%s.q3te", model_dir, dirs[d], preset);
        FILE *f = fopen(path, "rb");
        if (!f) continue;
        *found_any = 1;
        char magic[4];
        uint32_t ver, nf, sr;
        if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "Q3TE", 4) != 0 ||
            fread(&ver, 4, 1, f) != 1 || fread(&nf, 4, 1, f) != 1 || fread(&sr, 4, 1, f) != 1 ||
            nf == 0 || nf > 4096 || (int32_t)nf != want) {
            fclose(f);
            continue;
        }
        float *emb = (float *)malloc(sizeof(float) * nf);
        if (!emb || fread(emb, sizeof(float), nf, f) != nf) {
            free(emb);
            fclose(f);
            continue;
        }
        fclose(f);
        return emb;
    }
    return NULL;
}

/* Per-request streaming state for the engine PCM callback. */
typedef struct {
    const char *id;
    int chunks;
    long n_samples;
} stream_ctx;

#if WORKER_STREAM_CAPABLE
/* Called by the engine on the synthesis thread, once per decoded chunk.
 * Frames the chunk exactly like the stage-A blob so existing readers work:
 * pcm_meta line, N*4 raw bytes, newline. */
static int on_pcm_chunk(const float *samples, int32_t n_samples, int32_t sample_rate, void *user_data) {
    stream_ctx *sc = (stream_ctx *)user_data;
    if (n_samples <= 0) return 1;
    printf("{\"type\":\"pcm_meta\",\"id\":\"%s\",\"sample_rate\":%d,\"format\":\"f32le\","
           "\"n_samples\":%d,\"chunk\":%d}\n",
           sc->id, sample_rate, n_samples, sc->chunks);
    fflush(stdout);
    if (fwrite(samples, sizeof(float), (size_t)n_samples, stdout) != (size_t)n_samples) {
        return 0; /* host went away — abort synthesis */
    }
    fputc('\n', stdout);
    if (fflush(stdout) != 0) return 0;
    sc->chunks++;
    sc->n_samples += n_samples;
    return 1;
}
#endif

static void emit_ready(int streaming_default) {
    printf("{\"type\":\"ready\",\"protocol\":\"qwen3-tts-worker/v1\",\"sample_rate\":24000,"
           "\"pcm_format\":\"f32le\",\"streaming\":%s,\"streaming_capable\":%s,"
           "\"note\":\"%s\"}\n",
           streaming_default ? "true" : "false",
           WORKER_STREAM_CAPABLE ? "true" : "false",
           streaming_default ? "stage_B_pcm_chunks_during_synth"
                             : "stage_A_whole_utterance_pcm_after_synth");
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
    /* Streaming stays opt-in: per-request "stream", or QWEN3_TTS_STREAM=1 to make
     * it this process's default. Nothing flips by upgrading the engine pin. */
    const int stream_default = WORKER_STREAM_CAPABLE && env_flag("QWEN3_TTS_STREAM");
    emit_ready(stream_default);

    char line[65536];
    /* Request buffers outlive the loop body so the engine's PCM callback never
     * holds a pointer into a dead stack frame. */
    char id[128] = {0}, text[8192] = {0}, preset[64] = {0}, ref[1024] = {0};
    stream_ctx sc = {id, 0, 0};
    while (fgets(line, sizeof(line), stdin)) {
        if (strstr(line, "\"shutdown\"")) break;
        if (strstr(line, "\"cancel\"")) {
            /* Stage A: cancel only between requests */
            continue;
        }
        if (!strstr(line, "\"synthesize\"")) continue;

        id[0] = text[0] = preset[0] = ref[0] = 0;
        sc.chunks = 0;
        sc.n_samples = 0;
        json_get_string(line, "id", id, sizeof(id));
        json_get_string(line, "text", text, sizeof(text));
        json_get_string(line, "preset", preset, sizeof(preset));
        json_get_string(line, "ref_wav", ref, sizeof(ref));
        if (!text[0]) {
            printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"missing text\"}\n", id);
            fflush(stdout);
            continue;
        }

        int want_stream = stream_default;
        json_get_bool(line, "stream", &want_stream);
#if WORKER_STREAM_CAPABLE
        qwen3_tts_set_pcm_callback(tts, want_stream ? on_pcm_chunk : NULL,
                                   want_stream ? &sc : NULL, 0);
#else
        want_stream = 0;
#endif

        Qwen3TtsParams params;
        qwen3_tts_default_params(&params);
        Qwen3TtsAudio *audio = NULL;

        if (ref[0]) {
            audio = qwen3_tts_synthesize_with_voice_file(tts, text, ref, &params);
        } else if (preset[0]) {
            int32_t want = qwen3_tts_speaker_embedding_size(tts);
            int found_any = 0;
            float *emb = load_preset(model_dir, preset, want, &found_any);
            if (!emb) {
                if (found_any) {
                    printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"preset '%s' is not baked for this model tier (expects %d floats)\"}\n",
                           id, preset, want);
                } else {
                    printf("{\"type\":\"error\",\"id\":\"%s\",\"message\":\"preset not found\"}\n", id);
                }
                fflush(stdout);
                continue;
            }
            audio = qwen3_tts_synthesize_with_embedding(tts, text, emb, want, &params);
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

        if (want_stream && sc.chunks > 0) {
            /* PCM already went out chunk by chunk; the returned blob is the same
             * samples concatenated, so do not send it again. */
            printf("{\"type\":\"final\",\"id\":\"%s\",\"chunks\":%d,\"n_samples\":%ld}\n",
                   id, sc.chunks, sc.n_samples);
            fflush(stdout);
        } else {
            printf("{\"type\":\"pcm_meta\",\"id\":\"%s\",\"sample_rate\":%d,\"format\":\"f32le\",\"n_samples\":%d}\n",
                   id, audio->sample_rate, audio->n_samples);
            fflush(stdout);
            fwrite(audio->samples, sizeof(float), (size_t)audio->n_samples, stdout);
            fflush(stdout);
            printf("\n{\"type\":\"final\",\"id\":\"%s\"}\n", id);
            fflush(stdout);
        }
        qwen3_tts_free_audio(audio);
    }

    qwen3_tts_destroy(tts);
    return 0;
}
